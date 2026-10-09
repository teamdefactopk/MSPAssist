<?php

namespace Tests\Feature;

use App\Models\TicketMessage;
use Illuminate\Support\Str;
use Tests\TestCase;

class MessageTest extends TestCase
{
    public function test_internal_notes_are_hidden_from_clients(): void
    {
        $t = $this->createTicket($this->clientAdminA);
        $this->actingAsUser($this->manager);
        $this->postJson("/api/v1/tickets/{$t['id']}/messages", ['uuid' => (string) Str::uuid(), 'body' => 'Public reply'])->assertCreated();
        $this->postJson("/api/v1/tickets/{$t['id']}/messages", ['uuid' => (string) Str::uuid(), 'body' => 'SECRET internal', 'is_internal' => true])->assertCreated();

        $staffView = $this->getJson("/api/v1/tickets/{$t['id']}/messages")->assertOk()->json('data');
        $this->assertCount(2, $staffView);

        $this->actingAsUser($this->clientAdminA);
        $clientView = $this->getJson("/api/v1/tickets/{$t['id']}/messages")->assertOk();
        $this->assertCount(1, $clientView->json('data'));
        $this->assertStringNotContainsString('SECRET', $clientView->getContent());
        // Polling path also excludes internal notes.
        $this->assertStringNotContainsString('SECRET', $this->getJson("/api/v1/tickets/{$t['id']}/messages?after_id=0")->getContent());
        // Unread count excludes internal notes for clients.
        $list = collect($this->getJson('/api/v1/tickets')->json('data'))->firstWhere('id', $t['id']);
        $this->assertSame(1, $list['unread_count']);
        // Clients cannot post internal notes.
        $this->postJson("/api/v1/tickets/{$t['id']}/messages", ['uuid' => (string) Str::uuid(), 'body' => 'x', 'is_internal' => true])->assertForbidden();
    }

    public function test_message_retry_is_idempotent(): void
    {
        $t = $this->createTicket($this->clientAdminA);
        $this->actingAsUser($this->clientAdminA);
        $payload = ['uuid' => (string) Str::uuid(), 'body' => 'Any update?'];
        $first = $this->postJson("/api/v1/tickets/{$t['id']}/messages", $payload)->assertCreated()->json('data');
        $second = $this->postJson("/api/v1/tickets/{$t['id']}/messages", $payload)->assertOk()->json('data');
        $this->assertSame($first['id'], $second['id']);
        $this->assertSame(1, TicketMessage::where('uuid', $payload['uuid'])->count());

        // Another user cannot hijack the same uuid.
        $this->actingAsUser($this->manager);
        $this->postJson("/api/v1/tickets/{$t['id']}/messages", $payload)->assertStatus(409)->assertJsonPath('code', 'duplicate_uuid');
    }

    public function test_pagination_and_polling(): void
    {
        $t = $this->createTicket($this->clientAdminA);
        $this->actingAsUser($this->manager);
        $ids = [];
        for ($i = 1; $i <= 7; $i++) {
            $ids[] = $this->postJson("/api/v1/tickets/{$t['id']}/messages", ['uuid' => (string) Str::uuid(), 'body' => "m{$i}"])->json('data.id');
        }
        $latest = $this->getJson("/api/v1/tickets/{$t['id']}/messages?limit=3")->json();
        $this->assertSame(['m5', 'm6', 'm7'], array_column($latest['data'], 'body'));
        $this->assertTrue($latest['meta']['has_more']);
        $older = $this->getJson("/api/v1/tickets/{$t['id']}/messages?limit=3&before_id={$latest['data'][0]['id']}")->json();
        $this->assertSame(['m2', 'm3', 'm4'], array_column($older['data'], 'body'));
        $poll = $this->getJson("/api/v1/tickets/{$t['id']}/messages?after_id={$ids[5]}")->json();
        $this->assertSame(['m7'], array_column($poll['data'], 'body'));
        $this->assertFalse($poll['meta']['has_more']);
        $this->assertArrayHasKey('ticket_version', $poll['meta']);
    }

    public function test_unread_counts_and_mark_read(): void
    {
        $t = $this->createTicket($this->clientAdminA);
        $this->actingAsUser($this->manager);
        $last = 0;
        foreach (['a', 'b'] as $body) {
            $last = $this->postJson("/api/v1/tickets/{$t['id']}/messages", ['uuid' => (string) Str::uuid(), 'body' => $body])->json('data.id');
        }
        $this->actingAsUser($this->clientAdminA);
        $this->assertSame(2, $this->getJson("/api/v1/tickets/{$t['id']}")->json('data.unread_count'));
        $this->postJson("/api/v1/tickets/{$t['id']}/read", ['last_message_id' => $last])->assertOk();
        $this->assertSame(0, $this->getJson("/api/v1/tickets/{$t['id']}")->json('data.unread_count'));
        // Marker never moves backwards.
        $this->postJson("/api/v1/tickets/{$t['id']}/read", ['last_message_id' => 1])->assertJsonPath('last_read_message_id', $last);
    }

    public function test_closed_ticket_rejects_messages_and_client_reply_resumes_waiting(): void
    {
        $t = $this->createTicket($this->clientAdminA);
        $this->actingAsUser($this->manager);
        $t = $this->postJson("/api/v1/tickets/{$t['id']}/status", ['status' => 'waiting_client', 'version' => $t['version']])->json('data');
        $this->assertTrue($t['sla']['paused']);

        $this->actingAsUser($this->clientAdminA);
        $this->postJson("/api/v1/tickets/{$t['id']}/messages", ['uuid' => (string) Str::uuid(), 'body' => 'Here is the info'])->assertCreated();
        $t = $this->getJson("/api/v1/tickets/{$t['id']}")->json('data');
        $this->assertSame('in_progress', $t['status']);
        $this->assertFalse($t['sla']['paused']);

        $this->actingAsUser($this->manager);
        $t = $this->postJson("/api/v1/tickets/{$t['id']}/status", ['status' => 'resolved', 'version' => $t['version'], 'resolution_notes' => 'Done'])->json('data');
        $this->actingAsUser($this->clientAdminA);
        $this->postJson("/api/v1/tickets/{$t['id']}/status", ['status' => 'closed', 'version' => $t['version']])->assertOk();
        $this->postJson("/api/v1/tickets/{$t['id']}/messages", ['uuid' => (string) Str::uuid(), 'body' => 'late'])
            ->assertStatus(409)->assertJsonPath('code', 'ticket_closed');
    }
}
