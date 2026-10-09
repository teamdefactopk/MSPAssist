<?php

namespace App\Policies;

use App\Enums\Role;
use App\Enums\TicketStatus;
use App\Models\Ticket;
use App\Models\User;
use Illuminate\Auth\Access\Response;

class TicketPolicy
{
    /** Tickets outside the user's scope are reported as not found, not forbidden. */
    public function view(User $user, Ticket $ticket): Response
    {
        return $ticket->isVisibleTo($user) ? Response::allow() : Response::denyAsNotFound();
    }

    /** Staff work on a ticket if they manage the queue or it is assigned to them. */
    public function work(User $user, Ticket $ticket): bool
    {
        return $user->isManager()
            || ($user->role === Role::Technician && $ticket->assigned_to === $user->id);
    }

    public function update(User $user, Ticket $ticket): bool
    {
        return $this->work($user, $ticket);
    }

    public function assign(User $user, Ticket $ticket, ?User $assignee = null): bool
    {
        if ($user->isManager()) {
            return true;
        }

        // Technicians may pick up an unassigned ticket for themselves only.
        return $user->role === Role::Technician
            && $assignee?->id === $user->id
            && ($ticket->assigned_to === null || $ticket->assigned_to === $user->id);
    }

    public function changeStatus(User $user, Ticket $ticket, TicketStatus $to): bool
    {
        if ($user->isStaff()) {
            return $this->work($user, $ticket);
        }

        // Requesters and client administrators may accept (close) a resolution.
        return $to === TicketStatus::Closed && $this->isClientOwner($user, $ticket);
    }

    public function reopen(User $user, Ticket $ticket): bool
    {
        return $user->isStaff() ? $this->work($user, $ticket) : $this->isClientOwner($user, $ticket);
    }

    public function postMessage(User $user, Ticket $ticket, bool $internal): bool
    {
        if ($internal) {
            return $user->isStaff();
        }

        return $ticket->isVisibleTo($user);
    }

    public function logWork(User $user, Ticket $ticket): bool
    {
        return $this->work($user, $ticket);
    }

    public function confirmWork(User $user, Ticket $ticket): bool
    {
        return $user->isClient() && $ticket->isVisibleTo($user);
    }

    private function isClientOwner(User $user, Ticket $ticket): bool
    {
        return $user->isClient() && $ticket->organization_id === $user->organization_id
            && ($ticket->requester_id === $user->id || $user->role === Role::ClientAdmin);
    }
}
