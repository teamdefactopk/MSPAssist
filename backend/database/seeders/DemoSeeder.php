<?php

namespace Database\Seeders;

use App\Enums\Role;
use App\Enums\TicketStatus;
use App\Models\Category;
use App\Models\Organization;
use App\Models\SlaPolicy;
use App\Models\User;
use App\Services\TicketWorkflow;
use Illuminate\Database\Seeder;
use Illuminate\Support\Str;
use RuntimeException;

/**
 * Fictional demo data for local development and evaluation only.
 * Run with: php artisan db:seed --class=DemoSeeder
 * All accounts use the password from DEMO_PASSWORD (default "Demo-Password-2026").
 */
class DemoSeeder extends Seeder
{
    public function run(): void
    {
        if (app()->isProduction()) {
            throw new RuntimeException('DemoSeeder must not run in production.');
        }
        $this->call(ReferenceDataSeeder::class);
        $password = env('DEMO_PASSWORD', 'Demo-Password-2026');

        $staff = fn (string $name, string $email, Role $role) => User::firstOrCreate(['email' => $email], [
            'name' => $name, 'password' => $password, 'role' => $role, 'timezone' => 'UTC', 'is_active' => true,
        ]);
        $admin = $staff('Alex Admin', 'admin@cybercraft.example', Role::Admin);
        $manager = $staff('Morgan Manager', 'manager@cybercraft.example', Role::SupportManager);
        $tech1 = $staff('Taylor Tech', 'tech1@cybercraft.example', Role::Technician);
        $tech2 = $staff('Jordan Tech', 'tech2@cybercraft.example', Role::Technician);

        $acme = Organization::firstOrCreate(['code' => 'ACME'], [
            'name' => 'Acme Logistics (Demo)', 'email' => 'it@acme.example', 'phone' => '+1 555 0100',
            'timezone' => 'UTC', 'sla_policy_id' => SlaPolicy::where('is_default', true)->value('id'),
        ]);
        $globex = Organization::firstOrCreate(['code' => 'GLOBEX'], [
            'name' => 'Globex Clinics (Demo)', 'email' => 'support@globex.example', 'phone' => '+1 555 0200',
            'timezone' => 'UTC', 'sla_policy_id' => SlaPolicy::where('is_default', false)->value('id'),
        ]);

        $acmeHq = $acme->sites()->firstOrCreate(['name' => 'Head Office'], ['code' => 'HQ', 'city' => 'Springfield', 'address' => '1 Demo Street']);
        $acmeWh = $acme->sites()->firstOrCreate(['name' => 'Warehouse'], ['code' => 'WH1', 'city' => 'Shelbyville', 'address' => '99 Example Road']);
        $globexMain = $globex->sites()->firstOrCreate(['name' => 'Main Clinic'], ['code' => 'MC', 'city' => 'Capital City']);

        $acmeFin = $acme->departments()->firstOrCreate(['name' => 'Finance'], ['site_id' => $acmeHq->id]);
        $acme->departments()->firstOrCreate(['name' => 'Dispatch'], ['site_id' => $acmeWh->id]);
        $globex->departments()->firstOrCreate(['name' => 'Reception'], ['site_id' => $globexMain->id]);

        $acme->contacts()->firstOrCreate(['email' => 'pat.contact@acme.example'], ['name' => 'Pat Contact', 'phone' => '+1 555 0101', 'job_title' => 'Office Manager', 'is_primary' => true, 'site_id' => $acmeHq->id]);
        $globex->contacts()->firstOrCreate(['email' => 'sam.contact@globex.example'], ['name' => 'Sam Contact', 'job_title' => 'Practice Manager', 'is_primary' => true, 'site_id' => $globexMain->id]);

        $printer = $acme->equipment()->firstOrCreate(['asset_tag' => 'ACME-0001'], ['name' => 'Finance laser printer', 'type' => 'Printer', 'manufacturer' => 'DemoPrint', 'model' => 'LP-200', 'serial_number' => 'SN-DEMO-001', 'site_id' => $acmeHq->id, 'department_id' => $acmeFin->id]);
        $acme->equipment()->firstOrCreate(['asset_tag' => 'ACME-0002'], ['name' => 'Warehouse Wi-Fi AP', 'type' => 'Network', 'manufacturer' => 'DemoNet', 'model' => 'AP-5', 'site_id' => $acmeWh->id]);
        $globex->equipment()->firstOrCreate(['asset_tag' => 'GLX-0001'], ['name' => 'Reception PC', 'type' => 'Desktop', 'manufacturer' => 'DemoPC', 'site_id' => $globexMain->id]);

        $client = fn (string $name, string $email, Role $role, Organization $org) => User::firstOrCreate(['email' => $email], [
            'name' => $name, 'password' => $password, 'role' => $role, 'organization_id' => $org->id, 'timezone' => 'UTC', 'is_active' => true,
        ]);
        $acmeAdmin = $client('Casey Client-Admin', 'admin@acme.example', Role::ClientAdmin, $acme);
        $acmeUser = $client('Riley Warehouse', 'user@acme.example', Role::ClientUser, $acme);
        $acmeUser->sites()->syncWithoutDetaching([$acmeWh->id]);
        $globexAdmin = $client('Drew Globex', 'admin@globex.example', Role::ClientAdmin, $globex);

        if ($acme->tickets()->exists()) {
            return;
        }
        $workflow = app(TicketWorkflow::class);
        $cat = fn (string $n) => Category::where('name', $n)->value('id');

        [$t1] = $workflow->create($acmeAdmin, [
            'uuid' => (string) Str::uuid(), 'organization_id' => $acme->id, 'site_id' => $acmeHq->id,
            'department_id' => $acmeFin->id, 'equipment_id' => $printer->id, 'category_id' => $cat('Printer'),
            'subject' => 'Finance printer jams on every job', 'description' => 'The finance printer jams after the first page since this morning.',
            'priority' => 'high', 'source' => 'web',
        ]);
        $t1 = $workflow->assign($manager, $t1, $tech1, null);
        $workflow->changeStatus($tech1, $t1, TicketStatus::InProgress, null, 'Investigating');

        [$t2] = $workflow->create($acmeUser, [
            'uuid' => (string) Str::uuid(), 'organization_id' => $acme->id, 'site_id' => $acmeWh->id,
            'category_id' => $cat('Network'), 'subject' => 'Wi-Fi drops in loading bay',
            'description' => 'Scanners lose Wi-Fi connection near dock 3.', 'priority' => 'medium', 'source' => 'mobile',
        ]);

        [$t3] = $workflow->create($globexAdmin, [
            'uuid' => (string) Str::uuid(), 'organization_id' => $globex->id, 'site_id' => $globexMain->id,
            'category_id' => $cat('Email'), 'subject' => 'Shared mailbox not syncing',
            'description' => 'Reception shared mailbox has not received mail since yesterday.', 'priority' => 'critical', 'source' => 'web',
        ]);
        $workflow->assign($manager, $t3, $tech2, null);
        unset($admin, $t2);
    }
}
