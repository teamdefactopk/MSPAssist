<?php

namespace App\Http\Controllers\Api\V1;

use App\Enums\Role;
use App\Http\Controllers\Controller;
use App\Mail\InvitationMail;
use App\Models\Invitation;
use App\Models\Site;
use App\Models\User;
use App\Services\AuditLogger;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Mail;
use Illuminate\Support\Str;
use Illuminate\Validation\Rule;
use Illuminate\Validation\Rules\Password as PasswordRule;
use Illuminate\Validation\ValidationException;

class InvitationController extends Controller
{
    public function index(Request $request): JsonResponse
    {
        $user = $request->user();
        abort_unless($user->isManager() || $user->role === Role::ClientAdmin, 403);

        $invitations = Invitation::with('organization', 'inviter')
            ->when($user->isClient(), fn ($q) => $q->where('organization_id', $user->organization_id))
            ->when($request->filled('organization_id'), fn ($q) => $q->where('organization_id', $request->integer('organization_id')))
            ->latest()->paginate(min($request->integer('per_page', 25), 100));

        return response()->json([
            'data' => $invitations->getCollection()->map(fn (Invitation $i) => $this->present($i)),
            'meta' => ['current_page' => $invitations->currentPage(), 'last_page' => $invitations->lastPage(), 'total' => $invitations->total()],
        ]);
    }

    public function store(Request $request): JsonResponse
    {
        $actor = $request->user();
        $allowed = array_map(fn (Role $r) => $r->value, $actor->role->assignableRoles());
        abort_if($allowed === [], 403);

        $data = $request->validate([
            'email' => ['required', 'email', 'max:255', Rule::unique('users', 'email')],
            'name' => ['required', 'string', 'max:160'],
            'role' => ['required', Rule::in($allowed)],
            'organization_id' => ['nullable', 'integer', 'exists:organizations,id'],
            'site_ids' => ['array'],
            'site_ids.*' => ['integer', 'exists:sites,id'],
        ]);
        $role = Role::from($data['role']);
        if ($actor->isClient()) {
            $data['organization_id'] = $actor->organization_id;
        }
        if ($role->isClient()) {
            if (empty($data['organization_id'])) {
                throw ValidationException::withMessages(['organization_id' => 'Client users must belong to an organization.']);
            }
            $siteIds = $data['site_ids'] ?? [];
            $foreign = Site::whereIn('id', $siteIds)->where('organization_id', '!=', $data['organization_id'])->exists();
            if ($foreign) {
                throw ValidationException::withMessages(['site_ids' => 'Sites must belong to the selected organization.']);
            }
        } else {
            $data['organization_id'] = null;
            $data['site_ids'] = [];
        }

        // Revoke any earlier pending invitation for the same address.
        Invitation::where('email', $data['email'])->whereNull('accepted_at')->whereNull('revoked_at')->update(['revoked_at' => now()]);

        $token = Str::random(64);
        $invitation = Invitation::create([
            'email' => $data['email'],
            'name' => $data['name'],
            'role' => $role,
            'organization_id' => $data['organization_id'],
            'site_ids' => array_values($data['site_ids'] ?? []),
            'token_hash' => Invitation::hashToken($token),
            'invited_by' => $actor->id,
            'expires_at' => now()->addHours((int) config('mspassist.invitation_ttl_hours')),
        ]);
        Mail::to($invitation->email)->send(new InvitationMail($invitation, $token));
        AuditLogger::log('invitation.created', $invitation, ['email' => $invitation->email, 'role' => $role->value]);

        return response()->json(['data' => $this->present($invitation->load('organization', 'inviter'))], 201);
    }

    public function destroy(Request $request, Invitation $invitation): JsonResponse
    {
        $actor = $request->user();
        abort_unless($actor->isManager() || ($actor->role === Role::ClientAdmin && $invitation->organization_id === $actor->organization_id), 403);
        if ($invitation->accepted_at) {
            return response()->json(['message' => 'Accepted invitations cannot be revoked; deactivate the user instead.'], 409);
        }
        $invitation->update(['revoked_at' => now()]);
        AuditLogger::log('invitation.revoked', $invitation);

        return response()->json(['data' => $this->present($invitation)]);
    }

    /** Public: inspect an invitation before accepting it. */
    public function show(string $token): JsonResponse
    {
        $invitation = Invitation::with('organization')->where('token_hash', Invitation::hashToken($token))->first();
        if (! $invitation || ! $invitation->isUsable()) {
            return response()->json(['message' => 'This invitation is invalid or has expired.'], 404);
        }

        return response()->json(['data' => [
            'email' => $invitation->email,
            'name' => $invitation->name,
            'role' => $invitation->role->value,
            'role_label' => $invitation->role->label(),
            'organization' => $invitation->organization?->name,
            'expires_at' => $invitation->expires_at->toIso8601String(),
        ]]);
    }

    /** Public: accept an invitation, creating the account. */
    public function accept(Request $request): JsonResponse
    {
        $data = $request->validate([
            'token' => ['required', 'string'],
            'name' => ['required', 'string', 'max:160'],
            'password' => ['required', 'confirmed', PasswordRule::min(10)->letters()->numbers()],
        ]);
        $user = DB::transaction(function () use ($data) {
            $invitation = Invitation::where('token_hash', Invitation::hashToken($data['token']))->lockForUpdate()->first();
            if (! $invitation || ! $invitation->isUsable()) {
                throw ValidationException::withMessages(['token' => 'This invitation is invalid or has expired.']);
            }
            if (User::where('email', $invitation->email)->exists()) {
                throw ValidationException::withMessages(['token' => 'An account already exists for this email address.']);
            }
            $user = User::create([
                'name' => $data['name'],
                'email' => $invitation->email,
                'password' => $data['password'],
                'role' => $invitation->role,
                'organization_id' => $invitation->organization_id,
                'invited_by' => $invitation->invited_by,
                'is_active' => true,
            ]);
            $user->forceFill(['email_verified_at' => now()])->save();
            if ($invitation->site_ids) {
                $user->sites()->sync($invitation->site_ids);
            }
            $invitation->update(['accepted_at' => now()]);
            AuditLogger::log('invitation.accepted', $invitation, ['user_id' => $user->id], $user);

            return $user;
        });

        return response()->json(['message' => 'Account created. You can now sign in.', 'email' => $user->email], 201);
    }

    /** @return array<string, mixed> */
    private function present(Invitation $i): array
    {
        return [
            'id' => $i->id,
            'email' => $i->email,
            'name' => $i->name,
            'role' => $i->role->value,
            'role_label' => $i->role->label(),
            'organization' => $i->organization ? ['id' => $i->organization->id, 'name' => $i->organization->name] : null,
            'site_ids' => $i->site_ids ?? [],
            'status' => $i->status(),
            'invited_by' => $i->inviter?->name,
            'expires_at' => $i->expires_at->toIso8601String(),
            'created_at' => $i->created_at?->toIso8601String(),
        ];
    }
}
