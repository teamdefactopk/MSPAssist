<?php

namespace Tests\Feature;

use Illuminate\Support\Str;
use Tests\TestCase;

class AccessControlTest extends TestCase
{
    public function test_client_cannot_see_other_clients_tickets(): void
    {
        $ticketB = $this->createTicket($this->clientAdminB, $this->siteB1);
        $ticketA = $this->createTicket($this->clientAdminA, $this->siteA1);

        $this->actingAsUser($this->clientAdminA);
        $this->getJson("/api/v1/tickets/{$ticketB['id']}")->assertNotFound();
        $this->getJson("/api/v1/tickets/{$ticketB['id']}/messages")->assertNotFound();
        $this->getJson("/api/v1/tickets/{$ticketB['id']}/history")->assertNotFound();
        $this->postJson("/api/v1/tickets/{$ticketB['id']}/messages", ['uuid' => (string) Str::uuid(), 'body' => 'hi'])->assertNotFound();

        $ids = collect($this->getJson('/api/v1/tickets')->assertOk()->json('data'))->pluck('id');
        $this->assertTrue($ids->contains($ticketA['id']));
        $this->assertFalse($ids->contains($ticketB['id']));

        // Filtering by another organization never widens scope.
        $this->assertCount(0, $this->getJson("/api/v1/tickets?organization_id={$this->orgB->id}")->json('data'));
        $dash = $this->getJson("/api/v1/dashboard?organization_id={$this->orgB->id}")->assertOk()->json('data');
        $this->assertSame(0, $dash['counts']['active']);
    }

    public function test_client_cannot_create_ticket_for_other_org_or_unauthorized_site(): void
    {
        $this->actingAsUser($this->clientAdminA);
        $this->postJson('/api/v1/tickets', [
            'uuid' => (string) Str::uuid(), 'organization_id' => $this->orgB->id, 'site_id' => $this->siteB1->id,
            'subject' => 'x', 'description' => 'y',
        ])->assertForbidden();
        // Site from another org under own org id.
        $this->postJson('/api/v1/tickets', [
            'uuid' => (string) Str::uuid(), 'organization_id' => $this->orgA->id, 'site_id' => $this->siteB1->id,
            'subject' => 'x', 'description' => 'y',
        ])->assertUnprocessable()->assertJsonValidationErrors('site_id');

        // Client user is restricted to assigned site A1.
        $this->actingAsUser($this->clientUserA);
        $this->postJson('/api/v1/tickets', [
            'uuid' => (string) Str::uuid(), 'organization_id' => $this->orgA->id, 'site_id' => $this->siteA2->id,
            'subject' => 'x', 'description' => 'y',
        ])->assertUnprocessable();
    }

    public function test_client_user_only_sees_authorized_sites(): void
    {
        $a2 = $this->createTicket($this->clientAdminA, $this->siteA2);
        $a1 = $this->createTicket($this->clientAdminA, $this->siteA1);

        $this->actingAsUser($this->clientUserA);
        $this->getJson("/api/v1/tickets/{$a2['id']}")->assertNotFound();
        $this->getJson("/api/v1/tickets/{$a1['id']}")->assertOk();
        $sites = collect($this->getJson("/api/v1/organizations/{$this->orgA->id}/sites")->json('data'))->pluck('id');
        $this->assertEquals([$this->siteA1->id], $sites->all());
    }

    public function test_client_cannot_read_other_organizations_records(): void
    {
        $this->actingAsUser($this->clientAdminA);
        $this->getJson("/api/v1/organizations/{$this->orgB->id}")->assertNotFound();
        $this->getJson("/api/v1/organizations/{$this->orgB->id}/sites")->assertNotFound();
        $this->getJson("/api/v1/organizations/{$this->orgB->id}/equipment")->assertNotFound();
        $this->getJson("/api/v1/organizations/{$this->orgB->id}/contacts")->assertNotFound();
        $this->postJson("/api/v1/organizations/{$this->orgB->id}/contacts", ['name' => 'Spy'])->assertForbidden();
        $this->assertCount(1, $this->getJson('/api/v1/organizations')->json('data'));

        $users = collect($this->getJson('/api/v1/users')->assertOk()->json('data'));
        $this->assertTrue($users->every(fn ($u) => $u['organization_id'] === $this->orgA->id));
        $this->patchJson("/api/v1/users/{$this->clientAdminB->id}", ['is_active' => false])->assertForbidden();
    }

    public function test_client_cannot_manage_sites_or_create_organizations(): void
    {
        $this->actingAsUser($this->clientAdminA);
        $this->postJson('/api/v1/organizations', ['name' => 'New', 'code' => 'NEW'])->assertForbidden();
        $this->postJson("/api/v1/organizations/{$this->orgA->id}/sites", ['name' => 'Rogue'])->assertForbidden();
        // But client admins manage their own directory.
        $this->postJson("/api/v1/organizations/{$this->orgA->id}/contacts", ['name' => 'Ok'])->assertCreated();
    }

    public function test_technician_permissions(): void
    {
        $t = $this->createTicket($this->clientAdminA);
        $this->actingAsUser($this->tech);
        // Not assigned: cannot change status or log work.
        $this->postJson("/api/v1/tickets/{$t['id']}/status", ['status' => 'in_progress', 'version' => $t['version']])->assertForbidden();
        $this->postJson("/api/v1/tickets/{$t['id']}/work-logs", ['uuid' => (string) Str::uuid(), 'type' => 'remote', 'started_at' => now()->subMinutes(5)->toIso8601String(), 'minutes' => 5, 'description' => 'x'])->assertForbidden();
        // Cannot assign to someone else, but can self-assign.
        $this->postJson("/api/v1/tickets/{$t['id']}/assign", ['assigned_to' => $this->tech2->id, 'version' => $t['version']])->assertForbidden();
        $t = $this->postJson("/api/v1/tickets/{$t['id']}/assign", ['assigned_to' => $this->tech->id, 'version' => $t['version']])->assertOk()->json('data');
        $this->postJson("/api/v1/tickets/{$t['id']}/status", ['status' => 'in_progress', 'version' => $t['version']])->assertOk();
        // Cannot steal a colleague's ticket.
        $t2 = $this->createTicket($this->clientAdminA);
        $this->actingAsUser($this->manager);
        $t2 = $this->postJson("/api/v1/tickets/{$t2['id']}/assign", ['assigned_to' => $this->tech2->id, 'version' => $t2['version']])->json('data');
        $this->actingAsUser($this->tech);
        $this->postJson("/api/v1/tickets/{$t2['id']}/assign", ['assigned_to' => $this->tech->id, 'version' => $t2['version']])->assertForbidden();
    }

    public function test_clients_cannot_assign_or_change_status(): void
    {
        $t = $this->createTicket($this->clientAdminA);
        $this->actingAsUser($this->clientAdminA);
        $this->postJson("/api/v1/tickets/{$t['id']}/assign", ['assigned_to' => $this->tech->id, 'version' => $t['version']])->assertForbidden();
        $this->postJson("/api/v1/tickets/{$t['id']}/status", ['status' => 'resolved', 'version' => $t['version'], 'resolution_notes' => 'x'])->assertForbidden();
        $this->patchJson("/api/v1/tickets/{$t['id']}", ['priority' => 'critical', 'version' => $t['version']])->assertForbidden();
    }

    public function test_tickets_cannot_be_assigned_to_client_users(): void
    {
        $t = $this->createTicket($this->clientAdminA);
        $this->actingAsUser($this->manager);
        $this->postJson("/api/v1/tickets/{$t['id']}/assign", ['assigned_to' => $this->clientAdminA->id, 'version' => $t['version']])
            ->assertStatus(422)->assertJsonPath('code', 'invalid_assignee');
    }

    public function test_reports_are_scoped(): void
    {
        $this->createTicket($this->clientAdminA);
        $this->createTicket($this->clientAdminB, $this->siteB1);
        $this->actingAsUser($this->clientAdminA);
        $this->getJson('/api/v1/reports/technician-activity')->assertForbidden();
        $rows = $this->getJson("/api/v1/reports/ticket-history?organization_id={$this->orgB->id}")->assertOk()->json('data.tables.0.rows');
        $this->assertCount(1, $rows);
        $this->assertSame('Org A', $rows[0]['client']);
        $this->actingAsUser($this->clientUserA);
        $this->getJson('/api/v1/reports/ticket-history')->assertForbidden();
    }

    public function test_deactivated_user_is_rejected(): void
    {
        $this->clientUserA->update(['is_active' => false]);
        $this->actingAsUser($this->clientUserA);
        $this->getJson('/api/v1/me')->assertForbidden()->assertJsonPath('code', 'account_inactive');
    }

    public function test_internal_audit_log_requires_admin(): void
    {
        $this->actingAsUser($this->manager);
        $this->getJson('/api/v1/audit-logs')->assertForbidden();
        $this->actingAsUser($this->admin);
        $this->getJson('/api/v1/audit-logs')->assertOk();
    }
}
