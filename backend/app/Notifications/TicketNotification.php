<?php

namespace App\Notifications;

use App\Models\Ticket;
use Illuminate\Notifications\Messages\MailMessage;
use Illuminate\Notifications\Notification;

/** Base class for ticket notifications stored in the database and optionally mailed. */
abstract class TicketNotification extends Notification
{
    public function __construct(public readonly Ticket $ticket) {}

    abstract protected function title(): string;

    abstract protected function body(): string;

    protected function sendsMail(): bool
    {
        return true;
    }

    /** @return list<string> */
    public function via(object $notifiable): array
    {
        return $this->sendsMail() && ($notifiable->is_active ?? true) ? ['database', 'mail'] : ['database'];
    }

    public function url(): string
    {
        return config('mspassist.frontend_url').'/tickets/'.$this->ticket->id;
    }

    public function toMail(object $notifiable): MailMessage
    {
        return (new MailMessage)
            ->subject("[{$this->ticket->number}] {$this->title()}")
            ->line($this->body())
            ->action('Open ticket', $this->url());
    }

    /** @return array<string, mixed> */
    public function toArray(object $notifiable): array
    {
        return [
            'title' => $this->title(),
            'body' => $this->body(),
            'ticket_id' => $this->ticket->id,
            'ticket_number' => $this->ticket->number,
        ];
    }
}
