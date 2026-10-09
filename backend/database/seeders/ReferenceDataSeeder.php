<?php

namespace Database\Seeders;

use App\Models\Category;
use App\Models\SlaPolicy;
use Illuminate\Database\Seeder;

class ReferenceDataSeeder extends Seeder
{
    public function run(): void
    {
        foreach (['Hardware', 'Software', 'Network', 'Email', 'Printer', 'Security', 'Accounts & Access', 'Other'] as $name) {
            Category::firstOrCreate(['name' => $name]);
        }

        if (SlaPolicy::exists()) {
            return;
        }
        $weekday = [['09:00', '18:00']];
        $policy = SlaPolicy::create([
            'name' => 'Standard (business hours)',
            'is_default' => true,
            'timezone' => env('MSPASSIST_DEFAULT_TIMEZONE', 'UTC'),
            'business_hours' => ['mon' => $weekday, 'tue' => $weekday, 'wed' => $weekday, 'thu' => $weekday, 'fri' => $weekday, 'sat' => [], 'sun' => []],
            'holidays' => [],
            'pause_statuses' => ['waiting_client', 'waiting_vendor'],
            'warning_percent' => 80,
        ]);
        foreach ([
            'critical' => [30, 240],
            'high' => [60, 480],
            'medium' => [240, 1440],
            'low' => [480, 2880],
        ] as $priority => [$response, $resolution]) {
            $policy->targets()->create(['priority' => $priority, 'response_minutes' => $response, 'resolution_minutes' => $resolution]);
        }

        $premium = SlaPolicy::create([
            'name' => 'Premium 24x7',
            'is_default' => false,
            'timezone' => 'UTC',
            'business_hours' => null,
            'pause_statuses' => ['waiting_client'],
            'warning_percent' => 75,
        ]);
        foreach (['critical' => [15, 120], 'high' => [30, 240], 'medium' => [120, 720], 'low' => [240, 1440]] as $priority => [$response, $resolution]) {
            $premium->targets()->create(['priority' => $priority, 'response_minutes' => $response, 'resolution_minutes' => $resolution]);
        }
    }
}
