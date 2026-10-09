<?php

namespace App\Notifications;

class TicketAssigned extends TicketNotification
{
    protected function title(): string
    {
        return 'Ticket assigned to you';
    }

    protected function body(): string
    {
        return "{$this->ticket->number}: {$this->ticket->subject} ({$this->ticket->priority->label()} priority)";
    }
}
