<?php

namespace App\Models;

use App\Enums\Priority;
use App\Enums\Role;
use App\Enums\TicketStatus;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\HasMany;

class Ticket extends Model
{
    protected $guarded = ['id'];

    protected function casts(): array
    {
        return [
            'status' => TicketStatus::class,
            'priority' => Priority::class,
            'version' => 'integer',
            'reopen_count' => 'integer',
            'sla_paused_minutes' => 'integer',
            'escalation_level' => 'integer',
            'first_response_due_at' => 'datetime',
            'resolution_due_at' => 'datetime',
            'first_responded_at' => 'datetime',
            'sla_paused_at' => 'datetime',
            'response_breached_at' => 'datetime',
            'resolution_breached_at' => 'datetime',
            'resolution_warned_at' => 'datetime',
            'resolved_at' => 'datetime',
            'closed_at' => 'datetime',
            'last_activity_at' => 'datetime',
        ];
    }

    /**
     * Restrict a query to tickets the given user may see. This is the single
     * source of truth for ticket visibility and must be applied to every
     * ticket query that is driven by user input.
     */
    public function scopeVisibleTo(Builder $query, User $user): Builder
    {
        if ($user->isStaff()) {
            return $query;
        }

        $query->where('tickets.organization_id', $user->organization_id);

        if ($user->role === Role::ClientAdmin) {
            return $query;
        }

        $siteIds = $user->accessibleSiteIds();

        return $query->where(function (Builder $q) use ($siteIds, $user) {
            $q->whereIn('tickets.site_id', $siteIds ?: [0])
                ->orWhere('tickets.requester_id', $user->id);
        });
    }

    public function scopeOverdue(Builder $query): Builder
    {
        $now = now();

        return $query->whereIn('tickets.status', TicketStatus::activeValues())
            ->whereNull('tickets.sla_paused_at')
            ->where(function (Builder $q) use ($now) {
                $q->where('tickets.resolution_due_at', '<', $now)
                    ->orWhere(fn (Builder $r) => $r->whereNull('tickets.first_responded_at')->where('tickets.first_response_due_at', '<', $now));
            });
    }

    public function isVisibleTo(User $user): bool
    {
        return static::query()->visibleTo($user)->whereKey($this->id)->exists();
    }

    public function isOverdue(): bool
    {
        if (! $this->status->isActive() || $this->sla_paused_at) {
            return false;
        }
        $now = now();

        return ($this->resolution_due_at && $this->resolution_due_at->lt($now))
            || (! $this->first_responded_at && $this->first_response_due_at && $this->first_response_due_at->lt($now));
    }

    public function organization(): BelongsTo
    {
        return $this->belongsTo(Organization::class);
    }

    public function site(): BelongsTo
    {
        return $this->belongsTo(Site::class);
    }

    public function department(): BelongsTo
    {
        return $this->belongsTo(Department::class);
    }

    public function equipment(): BelongsTo
    {
        return $this->belongsTo(Equipment::class);
    }

    public function category(): BelongsTo
    {
        return $this->belongsTo(Category::class);
    }

    public function requester(): BelongsTo
    {
        return $this->belongsTo(User::class, 'requester_id');
    }

    public function contact(): BelongsTo
    {
        return $this->belongsTo(Contact::class);
    }

    public function assignee(): BelongsTo
    {
        return $this->belongsTo(User::class, 'assigned_to');
    }

    public function slaPolicy(): BelongsTo
    {
        return $this->belongsTo(SlaPolicy::class);
    }

    public function events(): HasMany
    {
        return $this->hasMany(TicketEvent::class);
    }

    public function messages(): HasMany
    {
        return $this->hasMany(TicketMessage::class);
    }

    public function workLogs(): HasMany
    {
        return $this->hasMany(WorkLog::class);
    }

    public function attachments(): HasMany
    {
        return $this->hasMany(Attachment::class);
    }
}
