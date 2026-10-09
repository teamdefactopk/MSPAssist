<?php

namespace App\Http\Resources;

use App\Models\Ticket;
use App\Services\SlaService;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;

/** @mixin Ticket */
class TicketResource extends JsonResource
{
    public function toArray(Request $request): array
    {
        $ref = fn ($model, array $extra = []) => $model ? ['id' => $model->id, 'name' => $model->name] + $extra : null;

        return [
            'id' => $this->id,
            'uuid' => $this->uuid,
            'number' => $this->number,
            'subject' => $this->subject,
            'description' => $this->description,
            'priority' => $this->priority->value,
            'status' => $this->status->value,
            'status_label' => $this->status->label(),
            'source' => $this->source,
            'organization' => $ref($this->organization),
            'site' => $ref($this->site),
            'department' => $ref($this->department),
            'equipment' => $ref($this->equipment, ['asset_tag' => $this->equipment?->asset_tag]),
            'category' => $ref($this->category),
            'contact' => $ref($this->contact),
            'requester' => $ref($this->requester),
            'assignee' => $ref($this->assignee),
            'resolution_notes' => $this->resolution_notes,
            'reopen_count' => $this->reopen_count,
            'version' => $this->version,
            'sla' => app(SlaService::class)->summary($this->resource),
            'is_overdue' => $this->isOverdue(),
            'unread_count' => (int) ($this->unread_count ?? 0),
            'created_at' => $this->created_at?->toIso8601String(),
            'updated_at' => $this->updated_at?->toIso8601String(),
            'last_activity_at' => $this->last_activity_at?->toIso8601String(),
            'resolved_at' => $this->resolved_at?->toIso8601String(),
            'closed_at' => $this->closed_at?->toIso8601String(),
        ];
    }
}
