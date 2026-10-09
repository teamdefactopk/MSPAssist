<?php

use App\Enums\Role;
use App\Models\User;
use App\Services\AuditLogger;
use App\Services\SlaMonitor;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\Schedule;
use Illuminate\Support\Facades\Validator;
use Illuminate\Validation\Rules\Password as PasswordRule;

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

Artisan::command('mspassist:create-admin {email} {name}', function (string $email, string $name) {
    if (User::where('email', $email)->exists()) {
        $this->error('A user with this email already exists.');

        return 1;
    }
    $password = $this->secret('Password (min 10 characters, letters and numbers)');
    $validator = Validator::make(['password' => $password], ['password' => ['required', PasswordRule::min(10)->letters()->numbers()]]);
    if ($validator->fails()) {
        $this->error($validator->errors()->first('password'));

        return 1;
    }
    $user = User::create(['name' => $name, 'email' => $email, 'password' => $password, 'role' => Role::Admin, 'is_active' => true]);
    AuditLogger::log('user.admin_created_cli', $user, [], $user);
    $this->info("Administrator {$email} created.");

    return 0;
})->purpose('Create a CyberCraft administrator account (initial setup)');
