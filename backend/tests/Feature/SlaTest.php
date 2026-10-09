<?php

namespace Tests\Feature;

use App\Models\SlaPolicy;
use App\Models\Ticket;
use App\Notifications\SlaAlert;
use Illuminate\Support\Facades\Notification;
use Illuminate\Support\Str;
use Tests\TestCase;

class SlaTest extends TestCase
{
    protected function setUp(): void
    {
        parent::setUp();
        // Deterministic 24x7 policy for these tests.
        $policy = SlaPolicy::where('name', 'Premium 24x7')->firstOrFail();
        $policy->update(['is_default' => true, 'pause_statuses' => ['waiting_client']]);
        SlaPolicy::whereKeyNot($policy->id)->update(['is_default' => false]);
        $this->travelTo(now()->startOfMinute());
    }

    public function test_due_dates_follow_priority_targets(): void
    {
        $t = $this->createTicket($this->clientAdminA, null, ['priority' => 'critical']);
        $created = strtotime($t['created_at']);
        $this->assertSame($created + 15 * 60, strtotime($t['sla']['first_response_due_at']));
        $this->assertSame($created + 120 * 60, strtotime($t['sla']['resolution_due_at']));
    }

    public function test_waiting_status_pauses_and_shifts_due_date(): void
    {
        $t = $this->createTicket($this->clientAdminA, null, ['priority' => 'critical']);
        $due = strtotime($t['sla']['resolution_due_at']);
        $this->actingAsUser($this->manager);
        $t = $this->postJson("/api/v1/tickets/{$t['id']}/status", ['status' => 'waiting_client', 'version' => $t['version']])->json('data');
        $this->assertTrue($t['sla']['paused']);

        $this->travel(90)->minutes();
        // Paused tickets are never overdue nor breached by the monitor.
        $this->artisan('sla:check')->assertSuccessful();
        $this->assertNull(Ticket::find($t['id'])->resolution_breached_at);

        $t = $this->postJson("/api/v1/tickets/{$t['id']}/status", ['status' => 'in_progress', 'version' => $t['version']])->json('data');
        $this->assertFalse($t['sla']['paused']);
        $this->assertSame(90, $t['sla']['paused_minutes']);
        $this->assertSame($due + 90 * 60, strtotime($t['sla']['resolution_due_at']));
    }

    public function test_waiting_for_vendor_does_not_pause_when_not_configured(): void
    {
        $t = $this->createTicket($this->clientAdminA);
        $this->actingAsUser($this->manager);
        $t = $this->postJson("/api/v1/tickets/{$t['id']}/status", ['status' => 'waiting_vendor', 'version' => $t['version']])->json('data');
        $this->assertFalse($t['sla']['paused']);
    }

    public function test_monitor_flags_breaches_and_escalates_once(): void
    {
        Notification::fake();
        $t = $this->createTicket($this->clientAdminA, null, ['priority' => 'critical']);
        $this->actingAsUser($this->manager);
        $this->postJson("/api/v1/tickets/{$t['id']}/assign", ['assigned_to' => $this->tech->id, 'version' => $t['version']]);

        $this->travel(100)->minutes(); // past 15m response, ~83% of 120m resolution
        $this->artisan('sla:check')->assertSuccessful();
        $ticket = Ticket::find($t['id']);
        $this->assertNotNull($ticket->response_breached_at);
        $this->assertNotNull($ticket->resolution_warned_at);
        $this->assertNull($ticket->resolution_breached_at);
        Notification::assertSentTo($this->manager, SlaAlert::class, fn ($n) => $n->kind === 'response_breached');
        Notification::assertSentTo($this->tech, SlaAlert::class, fn ($n) => $n->kind === 'resolution_warning');

        $this->travel(30)->minutes();
        $this->artisan('sla:check');
        $this->assertNotNull(Ticket::find($t['id'])->resolution_breached_at);
        $this->assertSame(2, Ticket::find($t['id'])->escalation_level);

        // Running again does not duplicate alerts.
        $this->artisan('sla:check');
        Notification::assertSentToTimes($this->manager, SlaAlert::class, 2);

        $this->travel(5)->hours();
        $this->artisan('sla:check');
        $this->assertSame(3, Ticket::find($t['id'])->escalation_level);
        Notification::assertSentTo($this->admin, SlaAlert::class, fn ($n) => $n->kind === 'escalated');

        // Overdue filter and SLA events are internal.
        $this->assertCount(1, $this->getJson('/api/v1/tickets?overdue=1')->json('data'));
        $this->actingAsUser($this->clientAdminA);
        $types = collect($this->getJson("/api/v1/tickets/{$t['id']}/history")->json('data'))->pluck('type');
        $this->assertFalse($types->contains(fn ($x) => str_starts_with($x, 'sla_')));
    }

    public function test_staff_public_reply_counts_as_first_response(): void
    {
        $t = $this->createTicket($this->clientAdminA);
        $this->actingAsUser($this->tech);
        $this->postJson("/api/v1/tickets/{$t['id']}/messages", ['uuid' => (string) Str::uuid(), 'body' => 'internal', 'is_internal' => true]);
        $this->assertNull(Ticket::find($t['id'])->first_responded_at);
        $this->postJson("/api/v1/tickets/{$t['id']}/messages", ['uuid' => (string) Str::uuid(), 'body' => 'Hello']);
        $this->assertNotNull(Ticket::find($t['id'])->first_responded_at);
        // Bookkeeping does not bump the version (no spurious conflicts).
        $this->assertSame($t['version'], Ticket::find($t['id'])->version);
    }
}
