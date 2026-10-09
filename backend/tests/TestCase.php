<?php

namespace Tests;

use App\Enums\Role;
use App\Models\Organization;
use App\Models\Site;
use App\Models\Ticket;
use App\Models\User;
use Database\Seeders\ReferenceDataSeeder;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Foundation\Testing\TestCase as BaseTestCase;
use Illuminate\Support\Str;
use Laravel\Sanctum\Sanctum;

abstract class TestCase extends BaseTestCase
{
    use RefreshDatabase;

    protected User $admin;

    protected User $manager;

    protected User $tech;

    protected User $tech2;

    protected Organization $orgA;

    protected Organization $orgB;

    protected Site $siteA1;

    protected Site $siteA2;

    protected Site $siteB1;

    protected User $clientAdminA;

    protected User $clientUserA;

    protected User $clientAdminB;

    protected function setUp(): void
    {
        parent::setUp();
        $this->seed(ReferenceDataSeeder::class);

        $this->admin = User::factory()->role(Role::Admin)->create(['name' => 'Admin']);
        $this->manager = User::factory()->role(Role::SupportManager)->create(['name' => 'Manager']);
        $this->tech = User::factory()->role(Role::Technician)->create(['name' => 'Tech One']);
        $this->tech2 = User::factory()->role(Role::Technician)->create(['name' => 'Tech Two']);

        $this->orgA = Organization::factory()->create(['name' => 'Org A', 'code' => 'ORGA']);
        $this->orgB = Organization::factory()->create(['name' => 'Org B', 'code' => 'ORGB']);
        $this->siteA1 = Site::factory()->for($this->orgA)->create(['name' => 'A1']);
        $this->siteA2 = Site::factory()->for($this->orgA)->create(['name' => 'A2']);
        $this->siteB1 = Site::factory()->for($this->orgB)->create(['name' => 'B1']);

        $this->clientAdminA = User::factory()->role(Role::ClientAdmin, $this->orgA)->create();
        $this->clientUserA = User::factory()->role(Role::ClientUser, $this->orgA)->create();
        $this->clientUserA->sites()->attach($this->siteA1);
        $this->clientAdminB = User::factory()->role(Role::ClientAdmin, $this->orgB)->create();
    }

    protected function actingAsUser(User $user): static
    {
        Sanctum::actingAs($user, ['*']);

        return $this;
    }

    /** Create a ticket through the API as the given user and return its JSON. */
    protected function createTicket(User $as, ?Site $site = null, array $overrides = []): array
    {
        $site ??= $this->siteA1;
        $this->actingAsUser($as);

        return $this->postJson('/api/v1/tickets', $overrides + [
            'uuid' => (string) Str::uuid(),
            'organization_id' => $site->organization_id,
            'site_id' => $site->id,
            'subject' => 'Laptop will not boot',
            'description' => 'Black screen after logo.',
            'priority' => 'high',
        ])->assertCreated()->json('data');
    }

    protected function ticket(array $json): Ticket
    {
        return Ticket::findOrFail($json['id']);
    }
}
