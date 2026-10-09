<?php

namespace App\Http\Resources;

use App\Models\TicketEvent;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;

/** @mixin TicketEvent */
class TicketEventResource extends JsonResource
{
    public function toArray(Request $request): array
    {
        return [
            'id' => $this->id,
            'ticket_id' => $this->ticket_id,
            'ticket' => $this->whenLoaded('ticket', fn () => ['id' => $this->ticket->id, 'number' => $this->ticket->number, 'subject' => $this->ticket->subject]),
            'type' => $this->type,
            'field' => $this->field,
            'from_value' => $this->from_value,
            'to_value' => $this->to_value,
            'note' => $this->note,
            'is_internal' => $this->is_internal,
            'user' => $this->user ? ['id' => $this->user->id, 'name' => $this->user->name] : null,
            'created_at' => $this->created_at?->toIso8601String(),
        ];
    }
}
