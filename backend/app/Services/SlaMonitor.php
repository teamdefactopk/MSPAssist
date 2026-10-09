<?php

namespace App\Services;

use App\Enums\Role;
use App\Enums\TicketStatus;
use App\Models\Ticket;
use App\Models\User;
use App\Notifications\SlaAlert;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Notification;

/**
 * Run from the scheduler (cPanel cron -> schedule:run). Each check flags the
 * ticket with a timestamp so alerts are sent exactly once even if cron
 * overlaps or runs late.
 *
 * Escalation levels: 1 = first response breached, 2 = resolution breached,
 * 3 = resolution breach escalated to administrators.
 */
class SlaMonitor
{
    public function __construct(private readonly TicketWorkflow $workflow) {}

    /** @return array<string, int> counts per alert kind */
    public function run(): array
    {
        $counts = ['response_breached' => 0, 'resolution_warning' => 0, 'resolution_breached' => 0, 'escalated' => 0];
        $now = now();

        Ticket::query()
            ->whereIn('status', TicketStatus::activeValues())
            ->whereNull('sla_paused_at')
            ->where(function ($q) use ($now) {
                $q->whereNull('resolution_breached_at')
                    ->orWhere('escalation_level', '<', 3)
                    ->orWhere(fn ($r) => $r->whereNull('first_responded_at')->whereNull('response_breached_at')->where('first_response_due_at', '<', $now));
            })
            ->with('assignee')
            ->chunkById(200, function (Collection $tickets) use (&$counts) {
                foreach ($tickets as $ticket) {
                    foreach ($this->check($ticket) as $kind) {
                        $counts[$kind]++;
                    }
                }
            });

        return $counts;
    }

    /** @return list<string> alert kinds raised for this ticket */
    public function check(Ticket $ticket): array
    {
        $now = now();
        $raised = [];

        if (! $ticket->first_responded_at && ! $ticket->response_breached_at
            && $ticket->first_response_due_at && $ticket->first_response_due_at->lt($now)) {
            $raised[] = 'response_breached';
        }

        if ($ticket->resolution_due_at && ! $ticket->resolution_breached_at) {
            if ($ticket->resolution_due_at->lt($now)) {
                $raised[] = 'resolution_breached';
            } elseif (! $ticket->resolution_warned_at && $this->warningReached($ticket)) {
                $raised[] = 'resolution_warning';
            }
        }

        $escalateAfter = (int) config('mspassist.sla.admin_escalation_minutes');
        if ($ticket->resolution_breached_at && $ticket->escalation_level < 3
            && $ticket->resolution_breached_at->lt($now->copy()->subMinutes($escalateAfter))) {
            $raised[] = 'escalated';
        }

        if (! $raised) {
            return [];
        }

        $updated = $this->workflow->mutate($ticket, null, function (Ticket $t) use ($raised, $now) {
            foreach ($raised as $kind) {
                match ($kind) {
                    'response_breached' => [$t->response_breached_at = $now, $t->escalation_level = max($t->escalation_level, 1)],
                    'resolution_warning' => $t->resolution_warned_at = $now,
                    'resolution_breached' => [$t->resolution_breached_at = $now, $t->resolution_warned_at ??= $now, $t->escalation_level = max($t->escalation_level, 2)],
                    'escalated' => $t->escalation_level = 3,
                };
                $this->workflow->event($t, null, 'sla_'.$kind, internal: true);
            }

            return true;
        }, bumpVersion: false);

        foreach ($raised as $kind) {
            Notification::send($this->recipients($updated, $kind), new SlaAlert($updated, $kind));
        }

        return $raised;
    }

    private function warningReached(Ticket $ticket): bool
    {
        $percent = $ticket->slaPolicy?->warning_percent ?? 80;
        $start = $ticket->created_at;
        $total = $start->diffInSeconds($ticket->resolution_due_at);
        if ($total <= 0) {
            return false;
        }

        return $start->diffInSeconds(now()) / $total * 100 >= $percent;
    }

    /** @return Collection<int, User> */
    private function recipients(Ticket $ticket, string $kind): Collection
    {
        $roles = match ($kind) {
            'resolution_warning' => $ticket->assigned_to ? [] : [Role::SupportManager],
            'escalated' => [Role::Admin, Role::SupportManager],
            default => [Role::SupportManager],
        };
        $users = User::where('is_active', true)->whereIn('role', array_map(fn ($r) => $r->value, $roles))->get();
        if ($ticket->assignee && $ticket->assignee->is_active) {
            $users->push($ticket->assignee);
        }

        return $users->unique('id')->values();
    }
}
