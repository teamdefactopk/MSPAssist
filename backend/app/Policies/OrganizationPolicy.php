<?php

namespace App\Policies;

use App\Enums\Role;
use App\Models\Organization;
use App\Models\User;
use Illuminate\Auth\Access\Response;

/**
 * Covers organizations and their child records (sites, departments,
 * contacts, equipment). Child controllers authorize against the parent
 * organization with the relevant ability.
 */
class OrganizationPolicy
{
    public function viewAny(User $user): bool
    {
        return true;
    }

    public function view(User $user, Organization $org): Response
    {
        return $user->canAccessOrganization($org->id) ? Response::allow() : Response::denyAsNotFound();
    }

    public function create(User $user): bool
    {
        return $user->isManager();
    }

    public function update(User $user, Organization $org): bool
    {
        return $user->isManager();
    }

    public function delete(User $user, Organization $org): bool
    {
        return $user->isAdmin();
    }

    public function manageSites(User $user, Organization $org): bool
    {
        return $user->isManager();
    }

    /** Departments and contacts: CyberCraft managers, or the client's own administrators. */
    public function manageDirectory(User $user, Organization $org): bool
    {
        return $user->isManager() || ($user->role === Role::ClientAdmin && $user->organization_id === $org->id);
    }

    /** Equipment can also be recorded by technicians in the field. */
    public function manageEquipment(User $user, Organization $org): bool
    {
        return $user->isStaff() || ($user->role === Role::ClientAdmin && $user->organization_id === $org->id);
    }

    public function viewUsers(User $user, Organization $org): bool
    {
        return $user->isStaff() || ($user->role === Role::ClientAdmin && $user->organization_id === $org->id);
    }
}
