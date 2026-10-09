<?php

namespace Tests\Feature;

use App\Models\Ticket;
use Illuminate\Support\Str;
use Tests\TestCase;

class TicketWorkflowTest extends TestCase
{
    private function setStatus(array $t, string $status, array $extra = [])
    {
        return $this->postJson("/api/v1/tickets/{$t['id']}/status", $extra + ['status' => $status, 'version' => $t['version']]);
    }

    public function test_invalid_transitions_are_rejected(): void
    {
        $t = $this->createTicket($this->clientAdminA);
        $this->actingAsUser($this->manager);
        $this->setStatus($t, 'assigned')->assertStatus(409)->assertJsonPath('code', 'invalid_transition');
        $t = $this->setStatus($t, 'in_progress')->assertOk()->json('data');
        $this->setStatus($t, 'closed')->assertStatus(409);
        $this->setStatus($t, 'resolved')->assertStatus(422)->assertJsonPath('code', 'resolution_notes_required');
        $t = $this->setStatus($t, 'waiting_vendor')->assertOk()->json('data');
        $t = $this->setStatus($t, 'resolved', ['resolution_notes' => 'Vendor replaced part'])->assertOk()->json('data');
        $this->assertSame('Vendor replaced part', $t['resolution_notes']);
        $t = $this->setStatus($t, 'closed')->assertOk()->json('data');
        $this->setStatus($t, 'in_progress')->assertStatus(409);
    }

    public function test_stale_version_returns_conflict_with_current_state(): void
    {
        $t = $this->createTicket($this->clientAdminA);
        $this->actingAsUser($this->manager);
        $this->postJson("/api/v1/tickets/{$t['id']}/assign", ['assigned_to' => $this->tech->id, 'version' => $t['version']])->assertOk();
        // Same (now stale) version again.
        $res = $this->postJson("/api/v1/tickets/{$t['id']}/status", ['status' => 'in_progress', 'version' => $t['version']])
            ->assertStatus(409)->assertJsonPath('code', 'version_conflict');
        $this->assertSame('assigned', $res->json('current.status'));
        $this->assertSame($t['version'] + 1, $res->json('current.version'));
        $this->patchJson("/api/v1/tickets/{$t['id']}", ['priority' => 'low', 'version' => $t['version']])->assertStatus(409);
    }

    public function test_reopen_records_history_and_counts(): void
    {
        $t = $this->createTicket($this->clientAdminA);
        $this->actingAsUser($this->manager);
        $t = $this->postJson("/api/v1/tickets/{$t['id']}/assign", ['assigned_to' => $this->tech->id, 'version' => $t['version']])->json('data');
        $t = $this->setStatus($t, 'resolved', ['resolution_notes' => 'Rebooted'])->json('data');

        $this->actingAsUser($this->clientAdminA);
        $this->postJson("/api/v1/tickets/{$t['id']}/reopen", ['version' => $t['version']])->assertUnprocessable();
        $t = $this->postJson("/api/v1/tickets/{$t['id']}/reopen", ['reason' => 'Still broken', 'version' => $t['version']])->assertOk()->json('data');
        $this->assertSame('assigned', $t['status']);
        $this->assertSame(1, $t['reopen_count']);
        $this->assertNull($t['resolved_at']);
        $history = collect($this->getJson("/api/v1/tickets/{$t['id']}/history")->json('data'));
        $this->assertSame('Still broken', $history->firstWhere('type', 'reopened')['note']);
    }

    public function test_client_reopen_window_for_closed_tickets(): void
    {
        $t = $this->createTicket($this->clientAdminA);
        $this->actingAsUser($this->manager);
        $t = $this->setStatus($t, 'resolved', ['resolution_notes' => 'Fixed'])->json('data');
        $t = $this->setStatus($t, 'closed')->json('data');
        Ticket::whereKey($t['id'])->update(['closed_at' => now()->subDays(30)]);

        $this->actingAsUser($this->clientAdminA);
        $this->postJson("/api/v1/tickets/{$t['id']}/reopen", ['reason' => 'Again', 'version' => $t['version']])
            ->assertUnprocessable()->assertJsonPath('code', 'reopen_window_expired');
        // Staff can still reopen.
        $this->actingAsUser($this->manager);
        $this->postJson("/api/v1/tickets/{$t['id']}/reopen", ['reason' => 'Again', 'version' => $t['version']])->assertOk();
    }

    public function test_other_client_user_cannot_close_or_reopen_colleagues_ticket(): void
    {
        $t = $this->createTicket($this->clientAdminA);  // site A1, visible to clientUserA
        $this->actingAsUser($this->manager);
        $t = $this->setStatus($t, 'resolved', ['resolution_notes' => 'Fixed'])->json('data');
        $this->actingAsUser($this->clientUserA);
        $this->getJson("/api/v1/tickets/{$t['id']}")->assertOk();
        $this->setStatus($t, 'closed')->assertForbidden();
        $this->postJson("/api/v1/tickets/{$t['id']}/reopen", ['reason' => 'x', 'version' => $t['version']])->assertForbidden();
    }

    public function test_ticket_creation_is_idempotent(): void
    {
        $this->actingAsUser($this->clientAdminA);
        $payload = ['uuid' => (string) Str::uuid(), 'organization_id' => $this->orgA->id, 'site_id' => $this->siteA1->id, 'subject' => 'S', 'description' => 'D'];
        $a = $this->postJson('/api/v1/tickets', $payload)->assertCreated()->json('data');
        $b = $this->postJson('/api/v1/tickets', $payload)->assertOk()->json('data');
        $this->assertSame($a['id'], $b['id']);
        $this->assertSame(1, Ticket::where('uuid', $payload['uuid'])->count());
        $this->actingAsUser($this->clientAdminB);
        $this->postJson('/api/v1/tickets', ['organization_id' => $this->orgB->id, 'site_id' => $this->siteB1->id] + $payload)->assertStatus(409);
    }

    public function test_priority_change_recalculates_sla(): void
    {
        $t = $this->createTicket($this->clientAdminA, null, ['priority' => 'low']);
        $this->actingAsUser($this->manager);
        $u = $this->patchJson("/api/v1/tickets/{$t['id']}", ['priority' => 'critical', 'version' => $t['version']])->assertOk()->json('data');
        $this->assertLessThan(strtotime($t['sla']['resolution_due_at']), strtotime($u['sla']['resolution_due_at']));
        $this->assertSame('priority_changed', collect($this->getJson("/api/v1/tickets/{$t['id']}/history")->json('data'))->last()['type']);
    }

    public function test_ticket_number_is_unique_and_sequential(): void
    {
        $a = $this->createTicket($this->clientAdminA);
        $b = $this->createTicket($this->clientAdminA);
        $this->assertNotSame($a['number'], $b['number']);
        $this->assertSame((int) substr($a['number'], -6) + 1, (int) substr($b['number'], -6));
    }

    public function test_work_log_confirmation_by_client(): void
    {
        $t = $this->createTicket($this->clientAdminA);
        $this->actingAsUser($this->manager);
        $log = $this->postJson("/api/v1/tickets/{$t['id']}/work-logs", [
            'uuid' => (string) Str::uuid(), 'type' => 'remote', 'started_at' => now()->subMinutes(30)->toIso8601String(), 'minutes' => 30, 'description' => 'Remote fix',
        ])->assertCreated()->json('data');
        $this->actingAsUser($this->clientAdminB);
        $this->postJson("/api/v1/work-logs/{$log['id']}/confirm")->assertNotFound();
        $this->actingAsUser($this->clientAdminA);
        $this->postJson("/api/v1/work-logs/{$log['id']}/confirm", ['note' => 'Works now'])->assertOk()->assertJsonPath('data.client_confirmed_by.id', $this->clientAdminA->id);
        $this->postJson("/api/v1/work-logs/{$log['id']}/confirm")->assertStatus(409);
        $this->actingAsUser($this->manager);
        $this->patchJson("/api/v1/work-logs/{$log['id']}", ['minutes' => 90])->assertStatus(409);
    }

    public function test_work_log_retry_is_idempotent_and_validated(): void
    {
        $t = $this->createTicket($this->clientAdminA);
        $this->actingAsUser($this->manager);
        $payload = ['uuid' => (string) Str::uuid(), 'type' => 'phone', 'started_at' => now()->subMinutes(10)->toIso8601String(), 'minutes' => 10, 'description' => 'Call'];
        $a = $this->postJson("/api/v1/tickets/{$t['id']}/work-logs", $payload)->assertCreated()->json('data.id');
        $b = $this->postJson("/api/v1/tickets/{$t['id']}/work-logs", $payload)->assertOk()->json('data.id');
        $this->assertSame($a, $b);
        $this->postJson("/api/v1/tickets/{$t['id']}/work-logs", ['uuid' => (string) Str::uuid(), 'type' => 'phone', 'started_at' => now()->toIso8601String(), 'ended_at' => now()->subHour()->toIso8601String(), 'description' => 'x'])
            ->assertUnprocessable()->assertJsonValidationErrors('ended_at');
    }
}
