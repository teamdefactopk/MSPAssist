<?php

namespace Database\Seeders;

use Illuminate\Database\Seeder;

class DatabaseSeeder extends Seeder
{
    /** Reference data only; safe for production. Demo data lives in DemoSeeder. */
    public function run(): void
    {
        $this->call(ReferenceDataSeeder::class);
    }
}
