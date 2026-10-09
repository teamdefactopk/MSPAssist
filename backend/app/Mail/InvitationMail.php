<?php

namespace App\Mail;

use App\Models\Invitation;
use Illuminate\Bus\Queueable;
use Illuminate\Mail\Mailable;
use Illuminate\Mail\Mailables\Content;
use Illuminate\Mail\Mailables\Envelope;

class InvitationMail extends Mailable
{
    use Queueable;

    public function __construct(public readonly Invitation $invitation, public readonly string $token) {}

    public function envelope(): Envelope
    {
        return new Envelope(subject: 'You have been invited to '.config('app.name'));
    }

    public function content(): Content
    {
        return new Content(markdown: 'mail.invitation', with: [
            'url' => config('mspassist.frontend_url').'/accept-invitation?token='.urlencode($this->token),
            'name' => $this->invitation->name,
            'role' => $this->invitation->role->label(),
            'organization' => $this->invitation->organization?->name,
            'expires' => $this->invitation->expires_at->toDayDateTimeString().' UTC',
        ]);
    }
}
