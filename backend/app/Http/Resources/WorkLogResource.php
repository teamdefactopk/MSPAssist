<?php

namespace App\Http\Resources;

use App\Models\WorkLog;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;

/** @mixin WorkLog */
class WorkLogResource extends JsonResource
{
    public function toArray(Request $request): array
    {
        $viewer = $request->user();

        return [
            'id' => $this->id,
            'uuid' => $this->uuid,
            'ticket_id' => $this->ticket_id,
            'ticket' => $this->whenLoaded('ticket', fn () => ['id' => $this->ticket->id, 'number' => $this->ticket->number, 'subject' => $this->ticket->subject]),
            'user' => ['id' => $this->user->id, 'name' => $this->user->name],
            'type' => $this->type->value,
            'started_at' => $this->started_at?->toIso8601String(),
            'ended_at' => $this->ended_at?->toIso8601String(),
            'minutes' => $this->minutes,
            'description' => $this->description,
            'client_confirmation_name' => $this->client_confirmation_name,
            'client_confirmed_by' => $this->confirmedBy ? ['id' => $this->confirmedBy->id, 'name' => $this->confirmedBy->name] : null,
            'client_confirmed_at' => $this->client_confirmed_at?->toIso8601String(),
            'client_confirmation_note' => $this->client_confirmation_note,
            'attachments' => AttachmentResource::collection(
                $this->whenLoaded('attachments', fn () => $viewer?->isStaff() ? $this->attachments : $this->attachments->where('is_internal', false))
            ),
            'created_at' => $this->created_at?->toIso8601String(),
            'updated_at' => $this->updated_at?->toIso8601String(),
        ];
    }
}
