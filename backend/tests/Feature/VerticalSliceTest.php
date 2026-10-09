<?php

namespace Tests\Feature;

use Illuminate\Support\Str;
use Tests\TestCase;

/** login → client/site → create ticket → assign → messages → work → resolve → dashboard. */
class VerticalSliceTest extends TestCase
{
    public function test_full_ticket_lifecycle(): void
    {
        // Manager logs in with a token (native client flow).
        $login = $this->postJson('/api/v1/auth/token', [
            'email' => $this->manager->email, 'password' => 'password', 'device_name' => 'test',
        ])->assertOk()->json();
        $this->assertNotEmpty($login['token']);
        $this->assertSame('support_manager', $login['user']['role']);
        $auth = ['Authorization' => 'Bearer '.$login['token']];

        // Manager creates a client and a site.
        $org = $this->withHeaders($auth)->postJson('/api/v1/organizations', ['name' => 'Initech', 'code' => 'INIT'])->assertCreated()->json('data');
        $site = $this->withHeaders($auth)->postJson("/api/v1/organizations/{$org['id']}/sites", ['name' => 'Main'])->assertCreated()->json('data');

        // Ticket created on behalf of the client.
        $ticket = $this->withHeaders($auth)->postJson('/api/v1/tickets', [
            'uuid' => (string) Str::uuid(), 'organization_id' => $org['id'], 'site_id' => $site['id'],
            'subject' => 'Server down', 'description' => 'File server unreachable', 'priority' => 'critical',
        ])->assertCreated()->json('data');
        $this->assertSame('open', $ticket['status']);
        $this->assertMatchesRegularExpression('/^CC-\d{4}-\d{6}$/', $ticket['number']);
        $this->assertNotNull($ticket['sla']['resolution_due_at']);

        // Assign technician.
        $ticket = $this->withHeaders($auth)->postJson("/api/v1/tickets/{$ticket['id']}/assign", [
            'assigned_to' => $this->tech->id, 'version' => $ticket['version'],
        ])->assertOk()->json('data');
        $this->assertSame('assigned', $ticket['status']);
        $this->assertSame($this->tech->id, $ticket['assignee']['id']);
        $this->assertDatabaseHas('notifications', ['notifiable_id' => $this->tech->id]);

        // Technician messages the client and records work.
        $this->app['auth']->forgetGuards();
        $this->actingAsUser($this->tech);
        $this->postJson("/api/v1/tickets/{$ticket['id']}/messages", ['uuid' => (string) Str::uuid(), 'body' => 'Looking into it now.'])->assertCreated();
        $this->postJson("/api/v1/tickets/{$ticket['id']}/work-logs", [
            'uuid' => (string) Str::uuid(), 'type' => 'onsite', 'started_at' => now()->subHour()->toIso8601String(),
            'ended_at' => now()->toIso8601String(), 'description' => 'Replaced failed PSU', 'client_confirmation_name' => 'Pat',
        ])->assertCreated()->assertJsonPath('data.minutes', 60);

        $ticket = $this->getJson("/api/v1/tickets/{$ticket['id']}")->assertOk()->json('data');
        $this->assertSame('in_progress', $ticket['status']);
        $this->assertNotNull($ticket['sla']['first_responded_at']);

        // Resolve.
        $ticket = $this->postJson("/api/v1/tickets/{$ticket['id']}/status", [
            'status' => 'resolved', 'version' => $ticket['version'], 'resolution_notes' => 'PSU replaced; server back online.',
        ])->assertOk()->json('data');
        $this->assertSame('resolved', $ticket['status']);

        // Dashboard reflects it.
        $this->app['auth']->forgetGuards();
        $this->actingAsUser($this->manager);
        $dash = $this->getJson("/api/v1/dashboard?organization_id={$org['id']}")->assertOk()->json('data');
        $this->assertSame(0, $dash['counts']['active']);
        $this->assertSame(1, $dash['counts']['resolved_last_7_days']);
        $this->assertNotEmpty($dash['recent_activity']);

        $types = collect($this->getJson("/api/v1/tickets/{$ticket['id']}/history")->json('data'))->pluck('type');
        $this->assertEqualsCanonicalizing(['created', 'assigned', 'status_changed', 'status_changed', 'work_logged', 'status_changed'], $types->all());
    }
}
