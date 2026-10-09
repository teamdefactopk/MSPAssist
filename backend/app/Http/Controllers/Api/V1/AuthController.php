<?php

namespace App\Http\Controllers\Api\V1;

use App\Enums\Role;
use App\Http\Controllers\Controller;
use App\Http\Resources\UserResource;
use App\Models\User;
use App\Services\AuditLogger;
use Illuminate\Auth\Events\PasswordReset;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Facades\Password;
use Illuminate\Support\Facades\RateLimiter;
use Illuminate\Support\Str;
use Illuminate\Validation\Rules\Password as PasswordRule;
use Illuminate\Validation\ValidationException;
use Laravel\Sanctum\PersonalAccessToken;

class AuthController extends Controller
{
    /** Browser login: establishes a session cookie (Sanctum SPA auth with CSRF). */
    public function login(Request $request): JsonResponse
    {
        if (! $request->hasSession()) {
            return response()->json([
                'message' => 'Session login is only available to the web app. Native apps must use /auth/token.',
                'code' => 'session_unavailable',
            ], 400);
        }
        $user = $this->attempt($request);
        Auth::guard('web')->login($user);
        $request->session()->regenerate();

        return response()->json(['user' => $this->profile($user)]);
    }

    /** Native (mobile/desktop) login: returns a bearer token for secure storage. */
    public function token(Request $request): JsonResponse
    {
        $request->validate(['device_name' => ['required', 'string', 'max:100']]);
        $user = $this->attempt($request);
        $days = (int) config('sanctum.token_days', 30);
        $token = $user->createToken($request->string('device_name')->toString(), ['*'], now()->addDays($days));

        return response()->json([
            'token' => $token->plainTextToken,
            'expires_at' => $token->accessToken->expires_at?->toIso8601String(),
            'user' => $this->profile($user),
        ]);
    }

    private function attempt(Request $request): User
    {
        $data = $request->validate([
            'email' => ['required', 'email', 'max:255'],
            'password' => ['required', 'string', 'max:255'],
        ]);
        $key = 'login:'.Str::lower($data['email']).'|'.$request->ip();
        if (RateLimiter::tooManyAttempts($key, 5)) {
            $seconds = RateLimiter::availableIn($key);
            AuditLogger::log('auth.login_throttled', null, ['email' => $data['email']]);
            throw ValidationException::withMessages([
                'email' => "Too many login attempts. Try again in {$seconds} seconds.",
            ])->status(429);
        }

        $user = User::where('email', $data['email'])->first();
        if (! $user || ! Hash::check($data['password'], $user->password) || ! $user->is_active) {
            RateLimiter::hit($key, 60);
            AuditLogger::log('auth.login_failed', $user, ['email' => $data['email']], $user);
            throw ValidationException::withMessages(['email' => 'These credentials do not match an active account.']);
        }

        RateLimiter::clear($key);
        $user->forceFill(['last_login_at' => now()])->save();
        AuditLogger::log('auth.login', $user, [], $user);

        return $user;
    }

    public function logout(Request $request): JsonResponse
    {
        $user = $request->user();
        $token = $user->currentAccessToken();
        if ($token instanceof PersonalAccessToken) {
            $token->delete();
        } else {
            Auth::guard('web')->logout();
            if ($request->hasSession()) {
                $request->session()->invalidate();
                $request->session()->regenerateToken();
            }
        }
        AuditLogger::log('auth.logout', $user, [], $user);

        return response()->json(['message' => 'Logged out.']);
    }

    public function me(Request $request): JsonResponse
    {
        return response()->json(['user' => $this->profile($request->user())]);
    }

    public function updateProfile(Request $request): JsonResponse
    {
        $user = $request->user();
        $data = $request->validate([
            'name' => ['sometimes', 'required', 'string', 'max:160'],
            'phone' => ['sometimes', 'nullable', 'string', 'max:50'],
            'job_title' => ['sometimes', 'nullable', 'string', 'max:120'],
            'timezone' => ['sometimes', 'required', 'timezone:all'],
        ]);
        $user->fill($data)->save();
        AuditLogger::log('user.profile_updated', $user, array_keys($data));

        return response()->json(['user' => $this->profile($user)]);
    }

    public function changePassword(Request $request): JsonResponse
    {
        $user = $request->user();
        $request->validate([
            'current_password' => ['required', 'current_password'],
            'password' => ['required', 'confirmed', PasswordRule::min(10)->letters()->numbers()],
        ]);
        $user->forceFill(['password' => $request->input('password')])->save();
        // Revoke other device tokens; keep the current one.
        $current = $user->currentAccessToken();
        $user->tokens()->when($current instanceof PersonalAccessToken, fn ($q) => $q->where('id', '!=', $current->id))->delete();
        AuditLogger::log('auth.password_changed', $user);

        return response()->json(['message' => 'Password updated.']);
    }

    public function forgotPassword(Request $request): JsonResponse
    {
        $request->validate(['email' => ['required', 'email', 'max:255']]);
        $user = User::where('email', $request->input('email'))->where('is_active', true)->first();
        if ($user) {
            Password::sendResetLink(['email' => $user->email]);
            AuditLogger::log('auth.password_reset_requested', $user, [], $user);
        }

        // Same response either way to avoid account enumeration.
        return response()->json(['message' => 'If the address belongs to an active account, a reset link has been sent.']);
    }

    public function resetPassword(Request $request): JsonResponse
    {
        $request->validate([
            'token' => ['required', 'string'],
            'email' => ['required', 'email'],
            'password' => ['required', 'confirmed', PasswordRule::min(10)->letters()->numbers()],
        ]);
        $status = Password::reset(
            $request->only('email', 'password', 'password_confirmation', 'token'),
            function (User $user, string $password) {
                $user->forceFill(['password' => $password, 'remember_token' => Str::random(60)])->save();
                $user->tokens()->delete();
                event(new PasswordReset($user));
                AuditLogger::log('auth.password_reset', $user, [], $user);
            }
        );
        if ($status !== Password::PASSWORD_RESET) {
            throw ValidationException::withMessages(['email' => __($status)]);
        }

        return response()->json(['message' => 'Password has been reset. You can now sign in.']);
    }

    /** @return array<string, mixed> */
    public static function profile(User $user): array
    {
        $user->loadMissing('organization', 'sites');
        $role = $user->role;

        return (new UserResource($user))->resolve(request()) + [
            'abilities' => [
                'view_all_clients' => $user->isStaff(),
                'manage_clients' => $user->isManager(),
                'manage_directory' => $user->isManager() || $role === Role::ClientAdmin,
                'manage_users' => $user->isManager() || $role === Role::ClientAdmin,
                'invite_roles' => array_map(fn (Role $r) => $r->value, $role->assignableRoles()),
                'assign_tickets' => $user->isManager(),
                'self_assign' => $role === Role::Technician,
                'internal_notes' => $user->isStaff(),
                'log_work' => $user->isStaff(),
                'view_reports' => $user->isStaff() || $role === Role::ClientAdmin,
                'manage_settings' => $user->isManager(),
                'view_audit_log' => $user->isAdmin(),
            ],
        ];
    }
}
