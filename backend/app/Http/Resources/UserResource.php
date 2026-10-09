<?php

namespace App\Http\Resources;

use App\Models\User;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;

/** @mixin User */
class UserResource extends JsonResource
{
    public function toArray(Request $request): array
    {
        $viewer = $request->user();
        $full = $viewer && ($viewer->id === $this->id || $viewer->isManager() || $viewer->role->value === 'client_admin');

        return [
            'id' => $this->id,
            'name' => $this->name,
            'email' => $this->when($full || $viewer?->isStaff(), $this->email),
            'role' => $this->role->value,
            'role_label' => $this->role->label(),
            'is_staff' => $this->isStaff(),
            'organization_id' => $this->organization_id,
            'organization' => $this->whenLoaded('organization', fn () => $this->organization ? ['id' => $this->organization->id, 'name' => $this->organization->name] : null),
            'site_ids' => $this->whenLoaded('sites', fn () => $this->sites->pluck('id')->values()),
            'phone' => $this->when($full, $this->phone),
            'job_title' => $this->job_title,
            'timezone' => $this->when($full, $this->timezone),
            'is_active' => $this->is_active,
            'last_login_at' => $this->when($full, fn () => $this->last_login_at?->toIso8601String()),
            'created_at' => $this->created_at?->toIso8601String(),
        ];
    }
}
