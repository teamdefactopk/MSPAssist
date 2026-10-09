<?php

namespace App\Notifications;

use App\Models\Ticket;

class SlaAlert extends TicketNotification
{
    /** @param string $kind response_breached | resolution_warning | resolution_breached | escalated */
    public function __construct(Ticket $ticket, public readonly string $kind)
    {
        parent::__construct($ticket);
    }

    protected function sendsMail(): bool
    {
        return (bool) config('mspassist.sla.send_mail');
    }

    protected function title(): string
    {
        return match ($this->kind) {
            'response_breached' => 'First-response SLA breached',
            'resolution_warning' => 'Resolution SLA due soon',
            'resolution_breached' => 'Resolution SLA breached',
            'escalated' => 'Overdue ticket escalated',
            default => 'SLA alert',
        };
    }

    protected function body(): string
    {
        $due = $this->kind === 'response_breached' ? $this->ticket->first_response_due_at : $this->ticket->resolution_due_at;

        return "{$this->ticket->number}: {$this->ticket->subject} ({$this->ticket->priority->label()}) — due "
            .($due?->toDayDateTimeString() ?? 'n/a').' UTC';
    }

    public function toArray(object $notifiable): array
    {
        return parent::toArray($notifiable) + ['kind' => $this->kind];
    }
}
