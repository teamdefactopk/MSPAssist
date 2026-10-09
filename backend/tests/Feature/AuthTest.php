<?php

namespace Tests\Feature;

use App\Mail\InvitationMail;
use App\Models\Invitation;
use App\Models\User;
use Illuminate\Auth\Notifications\ResetPassword;
use Illuminate\Support\Facades\Mail;
use Illuminate\Support\Facades\Notification;
use Tests\TestCase;

class AuthTest extends TestCase
{
    public function test_token_login_and_logout(): void
    {
        $token = $this->postJson('/api/v1/auth/token', ['email' => $this->tech->email, 'password' => 'password', 'device_name' => 'phone'])
            ->assertOk()->json('token');
        $this->withToken($token)->getJson('/api/v1/me')->assertOk()->assertJsonPath('user.id', $this->tech->id)
            ->assertJsonPath('user.abilities.internal_notes', true);
        $this->withToken($token)->postJson('/api/v1/auth/logout')->assertOk();
        $this->assertSame(0, $this->tech->tokens()->count());
        $this->app['auth']->forgetGuards();
        $this->withToken($token)->getJson('/api/v1/me')->assertUnauthorized();
    }

    public function test_wrong_password_and_inactive_users_are_rejected(): void
    {
        $this->postJson('/api/v1/auth/token', ['email' => $this->tech->email, 'password' => 'nope', 'device_name' => 'x'])->assertUnprocessable();
        $this->tech->update(['is_active' => false]);
        $this->postJson('/api/v1/auth/token', ['email' => $this->tech->email, 'password' => 'password', 'device_name' => 'x'])->assertUnprocessable();
        $this->assertDatabaseHas('audit_logs', ['action' => 'auth.login_failed']);
    }

    public function test_login_is_rate_limited(): void
    {
        for ($i = 0; $i < 5; $i++) {
            $this->postJson('/api/v1/auth/token', ['email' => $this->tech->email, 'password' => 'bad', 'device_name' => 'x'])->assertUnprocessable();
        }
        $this->postJson('/api/v1/auth/token', ['email' => $this->tech->email, 'password' => 'password', 'device_name' => 'x'])->assertStatus(429);
    }

    public function test_session_login_for_browser(): void
    {
        $this->get('/sanctum/csrf-cookie', ['Origin' => 'http://localhost'])->assertNoContent()->assertCookie('XSRF-TOKEN');
        $this->postJson('/api/v1/auth/login', ['email' => $this->manager->email, 'password' => 'password'], ['Origin' => 'http://localhost', 'Referer' => 'http://localhost/app/'])
            ->assertOk()->assertJsonPath('user.role', 'support_manager');
        $this->getJson('/api/v1/me', ['Origin' => 'http://localhost', 'Referer' => 'http://localhost/app/'])->assertOk();
        // Non-browser clients cannot use the session endpoint.
        $this->app['auth']->forgetGuards();
        $this->flushSession();
        $this->postJson('/api/v1/auth/login', ['email' => $this->manager->email, 'password' => 'password'])->assertStatus(400);
    }

    public function test_password_reset_flow(): void
    {
        Notification::fake();
        $this->postJson('/api/v1/auth/forgot-password', ['email' => 'nobody@example.com'])->assertOk();
        $this->postJson('/api/v1/auth/forgot-password', ['email' => $this->tech->email])->assertOk();
        $token = null;
        Notification::assertSentTo($this->tech, ResetPassword::class, function ($n) use (&$token) {
            $token = $n->token;

            return true;
        });
        $this->tech->createToken('old');
        $this->postJson('/api/v1/auth/reset-password', [
            'token' => $token, 'email' => $this->tech->email, 'password' => 'NewPassword123', 'password_confirmation' => 'NewPassword123',
        ])->assertOk();
        $this->assertSame(0, $this->tech->tokens()->count());
        $this->postJson('/api/v1/auth/token', ['email' => $this->tech->email, 'password' => 'NewPassword123', 'device_name' => 'x'])->assertOk();
    }

    public function test_profile_update_and_password_change(): void
    {
        $this->actingAsUser($this->clientUserA);
        $this->patchJson('/api/v1/me', ['name' => 'Renamed', 'timezone' => 'Asia/Karachi'])->assertOk()->assertJsonPath('user.name', 'Renamed');
        $this->patchJson('/api/v1/me', ['role' => 'admin'])->assertOk();
        $this->assertSame('client_user', $this->clientUserA->fresh()->role->value);
        $this->putJson('/api/v1/me/password', ['current_password' => 'wrong', 'password' => 'Another12345', 'password_confirmation' => 'Another12345'])->assertUnprocessable();
        $this->putJson('/api/v1/me/password', ['current_password' => 'password', 'password' => 'Another12345', 'password_confirmation' => 'Another12345'])->assertOk();
    }

    public function test_invitation_flow(): void
    {
        Mail::fake();
        $this->actingAsUser($this->clientAdminA);
        // Client admins cannot invite staff or into other organizations.
        $this->postJson('/api/v1/invitations', ['email' => 'x@example.com', 'name' => 'X', 'role' => 'technician'])->assertUnprocessable();
        $inv = $this->postJson('/api/v1/invitations', [
            'email' => 'new.user@example.com', 'name' => 'New User', 'role' => 'client_user',
            'organization_id' => $this->orgB->id, 'site_ids' => [$this->siteA2->id],
        ])->assertCreated()->json('data');
        $this->assertSame($this->orgA->id, $inv['organization']['id']);

        $token = null;
        Mail::assertSent(InvitationMail::class, function ($m) use (&$token) {
            $token = $m->token;

            return true;
        });
        $this->assertDatabaseMissing('invitations', ['token_hash' => $token]);

        $this->app['auth']->forgetGuards();
        $this->getJson("/api/v1/invitations/{$token}")->assertOk()->assertJsonPath('data.email', 'new.user@example.com');
        $this->postJson('/api/v1/invitations/accept', ['token' => $token, 'name' => 'New User', 'password' => 'short', 'password_confirmation' => 'short'])->assertUnprocessable();
        $this->postJson('/api/v1/invitations/accept', ['token' => $token, 'name' => 'New User', 'password' => 'GoodPassword1', 'password_confirmation' => 'GoodPassword1'])->assertCreated();
        $user = User::where('email', 'new.user@example.com')->firstOrFail();
        $this->assertSame($this->orgA->id, $user->organization_id);
        $this->assertEquals([$this->siteA2->id], $user->sites()->pluck('sites.id')->all());
        // Single use.
        $this->postJson('/api/v1/invitations/accept', ['token' => $token, 'name' => 'Again', 'password' => 'GoodPassword1', 'password_confirmation' => 'GoodPassword1'])->assertUnprocessable();
    }

    public function test_expired_invitation_cannot_be_used_and_no_public_registration(): void
    {
        Mail::fake();
        $this->actingAsUser($this->admin);
        $this->postJson('/api/v1/invitations', ['email' => 'staff@example.com', 'name' => 'Staff', 'role' => 'technician'])->assertCreated();
        $token = null;
        Mail::assertSent(InvitationMail::class, function ($m) use (&$token) {
            $token = $m->token;

            return true;
        });
        Invitation::query()->update(['expires_at' => now()->subMinute()]);
        $this->app['auth']->forgetGuards();
        $this->getJson("/api/v1/invitations/{$token}")->assertNotFound();
        $this->postJson('/api/v1/invitations/accept', ['token' => $token, 'name' => 'S', 'password' => 'GoodPassword1', 'password_confirmation' => 'GoodPassword1'])->assertUnprocessable();
        $this->postJson('/api/v1/auth/register', ['email' => 'a@b.c'])->assertNotFound();
    }

    public function test_support_manager_cannot_invite_admins(): void
    {
        $this->actingAsUser($this->manager);
        $this->postJson('/api/v1/invitations', ['email' => 'boss@example.com', 'name' => 'Boss', 'role' => 'admin'])->assertUnprocessable();
        $this->patchJson("/api/v1/users/{$this->admin->id}", ['is_active' => false])->assertForbidden();
    }
}
