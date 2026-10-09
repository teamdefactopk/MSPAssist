<?php

use App\Services\SlaMonitor;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\Schedule;

Artisan::command('sla:check', function (SlaMonitor $monitor) {
    $counts = $monitor->run();
    $this->info('SLA check complete: '.json_encode($counts));
})->purpose('Flag SLA breaches, send warnings and escalate overdue tickets');

// cPanel cron runs `php artisan schedule:run` every minute.
Schedule::command('sla:check')->everyFiveMinutes()->withoutOverlapping(10);
Schedule::command('sanctum:prune-expired --hours=24')->daily();
Schedule::command('auth:clear-resets')->everyFifteenMinutes();
// Processes queued mail if QUEUE_CONNECTION=database (no long-running worker on shared hosting).
Schedule::command('queue:work --stop-when-empty --max-time=50 --tries=3')->everyMinute()->withoutOverlapping(5);
