<?php

namespace App\Notifications;

use App\Models\Ticket;
use App\Models\TicketMessage;

/** In-app only; chat unread counts are the primary signal. */
class NewTicketMessage extends TicketNotification
{
    public function __construct(Ticket $ticket, public readonly TicketMessage $message)
    {
        parent::__construct($ticket);
    }

    protected function sendsMail(): bool
    {
        return false;
    }

    protected function title(): string
    {
        return ($this->message->is_internal ? 'Internal note' : 'New message').' from '.$this->message->user->name;
    }

    protected function body(): string
    {
        return "{$this->ticket->number}: ".mb_strimwidth($this->message->body, 0, 140, '…');
    }
}
