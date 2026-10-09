<?php

namespace Tests\Feature;

use App\Enums\Role;
use App\Models\User;
use Tests\TestCase;

class CreateAdminCommandTest extends TestCase
{
    public function test_creates_an_administrator(): void
    {
        $this->artisan('mspassist:create-admin', ['email' => 'owner@example.com', 'name' => 'Owner'])
            ->expectsQuestion('Password (min 10 characters, letters and numbers)', 'StrongPass123')
            ->assertSuccessful();
        $this->assertSame(Role::Admin, User::where('email', 'owner@example.com')->first()->role);
    }

    public function test_rejects_weak_passwords(): void
    {
        $this->artisan('mspassist:create-admin', ['email' => 'owner@example.com', 'name' => 'Owner'])
            ->expectsQuestion('Password (min 10 characters, letters and numbers)', 'weak')
            ->assertFailed();
    }
}
