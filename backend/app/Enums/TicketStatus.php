<?php

namespace App\Enums;

enum TicketStatus: string
{
    case Open = 'open';
    case Assigned = 'assigned';
    case InProgress = 'in_progress';
    case WaitingClient = 'waiting_client';
    case WaitingVendor = 'waiting_vendor';
    case Resolved = 'resolved';
    case Closed = 'closed';

    public function label(): string
    {
        return match ($this) {
            self::Open => 'Open',
            self::Assigned => 'Assigned',
            self::InProgress => 'In Progress',
            self::WaitingClient => 'Waiting for Client',
            self::WaitingVendor => 'Waiting for Vendor',
            self::Resolved => 'Resolved',
            self::Closed => 'Closed',
        };
    }

    public function isActive(): bool
    {
        return ! in_array($this, [self::Resolved, self::Closed], true);
    }

    /** @return list<string> */
    public static function activeValues(): array
    {
        return array_values(array_map(
            fn (self $s) => $s->value,
            array_filter(self::cases(), fn (self $s) => $s->isActive()),
        ));
    }

    /**
     * Staff workflow transitions. Reopening (resolved/closed -> open/assigned)
     * is a separate action handled by TicketWorkflow::reopen().
     *
     * @return list<TicketStatus>
     */
    public function allowedTransitions(): array
    {
        return match ($this) {
            self::Open => [self::InProgress, self::WaitingClient, self::WaitingVendor, self::Resolved, self::Closed],
            self::Assigned => [self::InProgress, self::WaitingClient, self::WaitingVendor, self::Resolved, self::Closed],
            self::InProgress => [self::WaitingClient, self::WaitingVendor, self::Resolved],
            self::WaitingClient => [self::InProgress, self::WaitingVendor, self::Resolved],
            self::WaitingVendor => [self::InProgress, self::WaitingClient, self::Resolved],
            self::Resolved => [self::Closed],
            self::Closed => [],
        };
    }

    public function canTransitionTo(self $to): bool
    {
        return in_array($to, $this->allowedTransitions(), true);
    }
}
