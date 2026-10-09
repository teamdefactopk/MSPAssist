<?php

namespace App\Services;

use App\Enums\Priority;
use App\Enums\Role;
use App\Enums\TicketStatus;
use App\Exceptions\VersionConflictException;
use App\Exceptions\WorkflowException;
use App\Models\Ticket;
use App\Models\TicketEvent;
use App\Models\User;
use App\Notifications\TicketAssigned;
use Illuminate\Support\Facades\DB;

/**
 * All ticket state changes go through this service so that history, SLA
 * accounting, versioning and audit records stay consistent. Callers are
 * responsible for authorization (see TicketPolicy).
 */
class TicketWorkflow
{
    public function __construct(
        private readonly SlaService $sla,
        private readonly TicketNumberGenerator $numbers,
    ) {}

    /**
     * Create a ticket. Idempotent on the client-generated uuid: replaying the
     * same uuid by the same requester returns the existing ticket.
     *
     * @param  array<string, mixed>  $data  validated input
     * @return array{0: Ticket, 1: bool} [ticket, created]
     */
    public function create(User $actor, array $data): array
    {
        $existing = Ticket::where('uuid', $data['uuid'])->first();
        if ($existing) {
            if ($existing->requester_id !== $actor->id) {
                throw new WorkflowException('This ticket id is already in use.', 'duplicate_uuid', 409);
            }

            return [$existing, false];
        }

        $ticket = DB::transaction(function () use ($actor, $data) {
            $ticket = new Ticket([
                'uuid' => $data['uuid'],
                'organization_id' => $data['organization_id'],
                'site_id' => $data['site_id'],
                'department_id' => $data['department_id'] ?? null,
                'equipment_id' => $data['equipment_id'] ?? null,
                'category_id' => $data['category_id'] ?? null,
                'contact_id' => $data['contact_id'] ?? null,
                'requester_id' => $actor->id,
                'subject' => $data['subject'],
                'description' => $data['description'],
                'priority' => $data['priority'] ?? Priority::Medium->value,
                'status' => TicketStatus::Open,
                'source' => $data['source'] ?? 'web',
                'version' => 1,
            ]);
            $ticket->number = $this->numbers->next();
            $ticket->created_at = now();
            $ticket->last_activity_at = now();
            $this->sla->initialize($ticket);
            $ticket->save();

            $this->event($ticket, $actor, 'created', null, null, $ticket->status->value);

            return $ticket;
        });

        AuditLogger::log('ticket.created', $ticket, ['number' => $ticket->number], $actor);

        if (! empty($data['assigned_to']) && $actor->isStaff()) {
            $ticket = $this->assign($actor, $ticket, User::findOrFail($data['assigned_to']), $ticket->version);
        }

        return [$ticket, true];
    }

    /** @param array<string, mixed> $data */
    public function update(User $actor, Ticket $ticket, array $data, ?int $expectedVersion): Ticket
    {
        return $this->mutate($ticket, $expectedVersion, function (Ticket $t) use ($actor, $data) {
            $fields = ['subject', 'description', 'category_id', 'department_id', 'equipment_id', 'contact_id', 'priority'];
            $changed = false;
            foreach ($fields as $field) {
                if (! array_key_exists($field, $data)) {
                    continue;
                }
                $old = $t->getAttribute($field);
                $oldRaw = $old instanceof \BackedEnum ? $old->value : $old;
                if ((string) $oldRaw === (string) $data[$field]) {
                    continue;
                }
                $t->setAttribute($field, $data[$field]);
                $changed = true;
                $isLong = $field === 'description';
                $this->event($t, $actor, $field === 'priority' ? 'priority_changed' : 'updated', $field,
                    $isLong ? null : $oldRaw, $isLong ? null : $data[$field]);
            }
            if (array_key_exists('priority', $data) && $t->isDirty('priority')) {
                $this->sla->recalculate($t);
            }

            return $changed;
        });
    }

    public function assign(User $actor, Ticket $ticket, ?User $assignee, ?int $expectedVersion): Ticket
    {
        if ($assignee && (! $assignee->isStaff() || ! $assignee->is_active)) {
            throw new WorkflowException('Tickets can only be assigned to active CyberCraft staff.', 'invalid_assignee', 422);
        }

        $result = $this->mutate($ticket, $expectedVersion, function (Ticket $t) use ($actor, $assignee) {
            if (! $t->status->isActive()) {
                throw new WorkflowException('Reopen the ticket before changing its assignment.');
            }
            if ($t->assigned_to === $assignee?->id) {
                return false;
            }
            $previous = $t->assignee;
            $t->assigned_to = $assignee?->id;
            $t->setRelation('assignee', $assignee);
            $this->event($t, $actor, $assignee ? 'assigned' : 'unassigned', 'assigned_to', $previous?->name, $assignee?->name);

            if ($assignee && $t->status === TicketStatus::Open) {
                $this->setStatus($t, $actor, TicketStatus::Assigned);
            } elseif (! $assignee && $t->status === TicketStatus::Assigned) {
                $this->setStatus($t, $actor, TicketStatus::Open);
            }

            return true;
        });

        if ($assignee && $assignee->id !== $actor->id && $result->wasChanged('assigned_to')) {
            $assignee->notify(new TicketAssigned($result));
        }

        return $result;
    }

    public function changeStatus(User $actor, Ticket $ticket, TicketStatus $to, ?int $expectedVersion, ?string $note = null, ?string $resolutionNotes = null): Ticket
    {
        return $this->mutate($ticket, $expectedVersion, function (Ticket $t) use ($actor, $to, $note, $resolutionNotes) {
            if ($t->status === $to) {
                return false;
            }
            if (! $t->status->canTransitionTo($to)) {
                throw new WorkflowException("A ticket cannot move from {$t->status->label()} to {$to->label()}.");
            }
            if ($actor->isClient() && ! ($t->status === TicketStatus::Resolved && $to === TicketStatus::Closed)) {
                throw new WorkflowException('Clients may only close a resolved ticket.', 'forbidden_transition', 403);
            }
            if ($to === TicketStatus::Resolved) {
                $notes = trim((string) ($resolutionNotes ?? $t->resolution_notes));
                if ($notes === '') {
                    throw new WorkflowException('Resolution notes are required to resolve a ticket.', 'resolution_notes_required', 422);
                }
                $t->resolution_notes = $notes;
            }
            if ($to === TicketStatus::Assigned && ! $t->assigned_to) {
                throw new WorkflowException('Assign a technician first.', 'assignee_required', 422);
            }
            if ($actor->isStaff() && in_array($to, [TicketStatus::InProgress, TicketStatus::WaitingClient, TicketStatus::WaitingVendor, TicketStatus::Resolved], true)) {
                $this->sla->recordFirstResponse($t);
            }
            $this->setStatus($t, $actor, $to, $to === TicketStatus::Resolved ? $t->resolution_notes : $note);

            return true;
        });
    }

    public function reopen(User $actor, Ticket $ticket, string $reason, ?int $expectedVersion): Ticket
    {
        return $this->mutate($ticket, $expectedVersion, function (Ticket $t) use ($actor, $reason) {
            if ($t->status->isActive()) {
                throw new WorkflowException('Only resolved or closed tickets can be reopened.');
            }
            if ($actor->isClient() && $t->status === TicketStatus::Closed) {
                $days = (int) config('mspassist.client_reopen_days');
                if ($t->closed_at && $t->closed_at->lt(now()->subDays($days))) {
                    throw new WorkflowException("Closed tickets can only be reopened within {$days} days. Please create a new ticket.", 'reopen_window_expired', 422);
                }
            }
            $t->reopen_count++;
            $t->resolved_at = null;
            $t->closed_at = null;
            $t->resolution_breached_at = null;
            $t->resolution_warned_at = null;
            $this->setStatus($t, $actor, $t->assigned_to ? TicketStatus::Assigned : TicketStatus::Open, $reason, 'reopened');

            return true;
        });
    }

    /** Called when a client replies; may resume a ticket waiting for the client. */
    public function onClientReply(User $actor, Ticket $ticket): void
    {
        if (! config('mspassist.resume_on_client_reply') || $ticket->status !== TicketStatus::WaitingClient) {
            return;
        }
        $this->mutate($ticket, null, function (Ticket $t) use ($actor) {
            if ($t->status !== TicketStatus::WaitingClient) {
                return false;
            }
            $this->setStatus($t, $actor, TicketStatus::InProgress, 'Client replied');

            return true;
        });
    }

    /**
     * Lock the ticket row, verify the expected version, apply the change and
     * bump the version. Throws VersionConflictException on a stale version.
     *
     * System bookkeeping (e.g. SLA flags) passes $bumpVersion = false so it
     * never causes conflicts for users editing the ticket.
     *
     * @param  callable(Ticket): bool  $change  returns whether anything changed
     */
    public function mutate(Ticket $ticket, ?int $expectedVersion, callable $change, bool $bumpVersion = true): Ticket
    {
        return DB::transaction(function () use ($ticket, $expectedVersion, $change, $bumpVersion) {
            /** @var Ticket $locked */
            $locked = Ticket::whereKey($ticket->id)->lockForUpdate()->firstOrFail();
            if ($expectedVersion !== null && $locked->version !== $expectedVersion) {
                throw new VersionConflictException($locked);
            }
            if ($change($locked)) {
                if ($bumpVersion) {
                    $locked->version++;
                    $locked->last_activity_at = now();
                }
                $locked->save();
            }

            return $locked;
        });
    }

    private function setStatus(Ticket $t, User $actor, TicketStatus $to, ?string $note = null, string $eventType = 'status_changed'): void
    {
        $from = $t->status;
        $this->sla->onStatusChange($t, $from, $to);
        $t->status = $to;
        if ($to === TicketStatus::Resolved) {
            $t->resolved_at = now();
        }
        if ($to === TicketStatus::Closed) {
            $t->closed_at = now();
            $t->resolved_at ??= now();
        }
        $this->event($t, $actor, $eventType, 'status', $from->value, $to->value, $note);
        AuditLogger::log('ticket.'.$eventType, $t, ['from' => $from->value, 'to' => $to->value], $actor);
    }

    public function event(Ticket $t, ?User $actor, string $type, ?string $field = null, mixed $from = null, mixed $to = null, ?string $note = null, bool $internal = false): TicketEvent
    {
        return TicketEvent::create([
            'ticket_id' => $t->id,
            'user_id' => $actor?->id,
            'type' => $type,
            'field' => $field,
            'from_value' => $from === null ? null : mb_substr((string) $from, 0, 255),
            'to_value' => $to === null ? null : mb_substr((string) $to, 0, 255),
            'note' => $note,
            'is_internal' => $internal,
            'created_at' => now(),
        ]);
    }

    /** Roles that are allowed to be assigned tickets. */
    public static function assignableRoles(): array
    {
        return [Role::Technician->value, Role::SupportManager->value, Role::Admin->value];
    }
}
