<?php

namespace App\Notifications;

class TicketResolved extends TicketNotification
{
    protected function title(): string
    {
        return 'Your ticket has been resolved';
    }

    protected function body(): string
    {
        return "{$this->ticket->number}: {$this->ticket->subject}. Resolution: {$this->ticket->resolution_notes}. "
            .'Reply or reopen the ticket if the problem persists.';
    }
}
