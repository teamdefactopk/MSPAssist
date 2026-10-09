<?php

namespace App\Models;

use App\Enums\Role;
use Database\Factories\UserFactory;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\BelongsToMany;
use Illuminate\Foundation\Auth\User as Authenticatable;
use Illuminate\Notifications\Notifiable;
use Laravel\Sanctum\HasApiTokens;

class User extends Authenticatable
{
    /** @use HasFactory<UserFactory> */
    use HasApiTokens, HasFactory, Notifiable;

    protected $fillable = [
        'name', 'email', 'password', 'role', 'organization_id', 'phone',
        'job_title', 'timezone', 'is_active', 'invited_by',
    ];

    protected $hidden = ['password', 'remember_token'];

    protected function casts(): array
    {
        return [
            'email_verified_at' => 'datetime',
            'last_login_at' => 'datetime',
            'password' => 'hashed',
            'role' => Role::class,
            'is_active' => 'boolean',
        ];
    }

    public function organization(): BelongsTo
    {
        return $this->belongsTo(Organization::class);
    }

    public function sites(): BelongsToMany
    {
        return $this->belongsToMany(Site::class);
    }

    public function isStaff(): bool
    {
        return $this->role->isStaff();
    }

    public function isClient(): bool
    {
        return $this->role->isClient();
    }

    public function isManager(): bool
    {
        return $this->role->isManager();
    }

    public function isAdmin(): bool
    {
        return $this->role === Role::Admin;
    }

    /**
     * Site ids a client user may access. Client administrators may access every
     * site of their organization; client users only their assigned sites.
     * Returns null for staff (meaning: unrestricted).
     *
     * @return list<int>|null
     */
    public function accessibleSiteIds(): ?array
    {
        if ($this->isStaff()) {
            return null;
        }
        if ($this->role === Role::ClientAdmin) {
            return Site::where('organization_id', $this->organization_id)->pluck('id')->all();
        }

        return $this->sites()->where('sites.organization_id', $this->organization_id)->pluck('sites.id')->all();
    }

    public function canAccessOrganization(int $organizationId): bool
    {
        return $this->isStaff() || $this->organization_id === $organizationId;
    }

    public function canAccessSite(Site $site): bool
    {
        if ($this->isStaff()) {
            return true;
        }

        return $site->organization_id === $this->organization_id
            && in_array($site->id, $this->accessibleSiteIds(), true);
    }
}
