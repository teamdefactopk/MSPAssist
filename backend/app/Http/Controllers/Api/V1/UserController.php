<?php

namespace App\Http\Controllers\Api\V1;

use App\Enums\Role;
use App\Http\Controllers\Controller;
use App\Http\Resources\UserResource;
use App\Models\Site;
use App\Models\User;
use App\Services\AuditLogger;
use App\Services\TicketWorkflow;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\AnonymousResourceCollection;
use Illuminate\Validation\Rule;
use Illuminate\Validation\ValidationException;

class UserController extends Controller
{
    public function index(Request $request): AnonymousResourceCollection
    {
        $actor = $request->user();
        abort_unless($actor->isStaff() || $actor->role === Role::ClientAdmin, 403);

        $users = User::with('organization', 'sites')
            ->when($actor->isClient(), fn ($q) => $q->where('organization_id', $actor->organization_id))
            ->when($request->filled('organization_id'), fn ($q) => $q->where('organization_id', $request->integer('organization_id')))
            ->when($request->filled('role'), fn ($q) => $q->whereIn('role', explode(',', $request->string('role'))))
            ->when($request->boolean('staff'), fn ($q) => $q->whereNull('organization_id'))
            ->when($request->boolean('assignable'), fn ($q) => $q->whereIn('role', TicketWorkflow::assignableRoles())->where('is_active', true))
            ->when($request->filled('search'), function ($q) use ($request) {
                $term = '%'.$request->string('search').'%';
                $q->where(fn ($w) => $w->where('name', 'like', $term)->orWhere('email', 'like', $term));
            })
            ->orderBy('name')
            ->paginate(min($request->integer('per_page', 50), 200));

        return UserResource::collection($users);
    }

    public function show(Request $request, User $user): UserResource
    {
        $this->authorizeManage($request->user(), $user, viewOnly: true);

        return new UserResource($user->load('organization', 'sites'));
    }

    public function update(Request $request, User $user): UserResource
    {
        $actor = $request->user();
        $this->authorizeManage($actor, $user);
        $allowed = array_map(fn (Role $r) => $r->value, $actor->role->assignableRoles());

        $data = $request->validate([
            'name' => ['sometimes', 'required', 'string', 'max:160'],
            'role' => ['sometimes', Rule::in($allowed)],
            'is_active' => ['sometimes', 'boolean'],
            'phone' => ['sometimes', 'nullable', 'string', 'max:50'],
            'job_title' => ['sometimes', 'nullable', 'string', 'max:120'],
            'site_ids' => ['sometimes', 'array'],
            'site_ids.*' => ['integer', 'exists:sites,id'],
        ]);
        if ($user->id === $actor->id && (isset($data['role']) || (isset($data['is_active']) && ! $data['is_active']))) {
            throw ValidationException::withMessages(['role' => 'You cannot change your own role or deactivate yourself.']);
        }
        if (isset($data['role']) && Role::from($data['role'])->isClient() !== $user->isClient()) {
            throw ValidationException::withMessages(['role' => 'Staff and client roles cannot be swapped; invite a new account instead.']);
        }
        if (array_key_exists('site_ids', $data)) {
            $foreign = Site::whereIn('id', $data['site_ids'])->where('organization_id', '!=', $user->organization_id)->exists();
            if ($foreign || $user->isStaff()) {
                throw ValidationException::withMessages(['site_ids' => 'Sites must belong to the user\'s organization.']);
            }
            $user->sites()->sync($data['site_ids']);
            unset($data['site_ids']);
        }
        $user->fill($data)->save();
        if (isset($data['is_active']) && ! $data['is_active']) {
            $user->tokens()->delete();
        }
        AuditLogger::log('user.updated', $user, $request->only('role', 'is_active', 'site_ids'));

        return new UserResource($user->load('organization', 'sites'));
    }

    private function authorizeManage(User $actor, User $target, bool $viewOnly = false): void
    {
        if ($actor->isAdmin()) {
            return;
        }
        if ($actor->role === Role::SupportManager) {
            abort_if(! $viewOnly && $target->role === Role::Admin, 403);

            return;
        }
        if ($viewOnly && $actor->isStaff()) {
            return;
        }
        abort_unless($actor->role === Role::ClientAdmin && $target->organization_id === $actor->organization_id, 403);
    }
}
