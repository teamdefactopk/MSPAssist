<?php

namespace App\Services;

use App\Enums\TicketStatus;
use App\Models\SlaPolicy;
use App\Models\Ticket;
use Carbon\CarbonImmutable;

/**
 * Computes and maintains SLA due dates on tickets. Pausing works by
 * accumulating paused business minutes and shifting the due dates forward
 * when the clock resumes, so breach checks can be simple date comparisons.
 */
class SlaService
{
    public function policyFor(Ticket $ticket): ?SlaPolicy
    {
        $ticket->loadMissing('organization.slaPolicy.targets');

        $policy = $ticket->organization?->slaPolicy ?? SlaPolicy::default();
        $policy?->loadMissing('targets');

        return $policy;
    }

    /** Set initial due dates on a new (unsaved or saved) ticket. */
    public function initialize(Ticket $ticket): void
    {
        $policy = $this->policyFor($ticket);
        $ticket->sla_policy_id = $policy?->id;
        $this->computeDueDates($ticket, $policy);
    }

    /** Recalculate due dates, e.g. after a priority change. Preserves paused time. */
    public function recalculate(Ticket $ticket): void
    {
        $policy = $ticket->sla_policy_id ? SlaPolicy::with('targets')->find($ticket->sla_policy_id) : $this->policyFor($ticket);
        $this->computeDueDates($ticket, $policy);
    }

    private function computeDueDates(Ticket $ticket, ?SlaPolicy $policy): void
    {
        $target = $policy?->targetFor($ticket->priority);
        if (! $target) {
            $ticket->first_response_due_at = null;
            $ticket->resolution_due_at = null;

            return;
        }
        $calendar = BusinessCalendar::forPolicy($policy);
        $start = CarbonImmutable::instance($ticket->created_at ?? now());
        $paused = (int) $ticket->sla_paused_minutes;
        $ticket->first_response_due_at = $calendar->addMinutes($start, $target->response_minutes + $paused);
        $ticket->resolution_due_at = $calendar->addMinutes($start, $target->resolution_minutes + $paused);
    }

    /** Apply pause/resume rules when the status changes. Call before saving. */
    public function onStatusChange(Ticket $ticket, TicketStatus $from, TicketStatus $to): void
    {
        $policy = $ticket->sla_policy_id ? SlaPolicy::find($ticket->sla_policy_id) : null;
        $wasPaused = $ticket->sla_paused_at !== null;
        // Resolved/closed tickets stop the clock; reopening resumes it with the
        // time spent resolved excluded.
        $shouldPause = ! $to->isActive() || ($policy?->pausesOn($to->value) ?? false);

        if (! $wasPaused && $shouldPause) {
            $ticket->sla_paused_at = now();
        } elseif ($wasPaused && ! $shouldPause) {
            $this->resume($ticket, $policy);
        }
    }

    private function resume(Ticket $ticket, ?SlaPolicy $policy): void
    {
        $calendar = BusinessCalendar::forPolicy($policy);
        $pausedMinutes = $calendar->minutesBetween($ticket->sla_paused_at, now());
        $ticket->sla_paused_minutes = (int) $ticket->sla_paused_minutes + $pausedMinutes;
        if ($ticket->resolution_due_at) {
            $ticket->resolution_due_at = $calendar->addMinutes($ticket->resolution_due_at, $pausedMinutes);
        }
        if ($ticket->first_response_due_at && ! $ticket->first_responded_at) {
            $ticket->first_response_due_at = $calendar->addMinutes($ticket->first_response_due_at, $pausedMinutes);
        }
        $ticket->sla_paused_at = null;
    }

    /** Record the first staff response (public reply or work started). */
    public function recordFirstResponse(Ticket $ticket): void
    {
        if ($ticket->first_responded_at) {
            return;
        }
        $ticket->first_responded_at = now();
        if ($ticket->first_response_due_at && $ticket->first_response_due_at->lt(now()) && ! $ticket->response_breached_at) {
            $ticket->response_breached_at = now();
        }
    }

    /** @return array<string, mixed> */
    public function summary(Ticket $ticket): array
    {
        $now = now();
        $responseMet = $ticket->first_responded_at && $ticket->first_response_due_at
            ? $ticket->first_responded_at->lte($ticket->first_response_due_at) : null;
        $resolvedAt = $ticket->resolved_at;
        $resolutionMet = $resolvedAt && $ticket->resolution_due_at ? $resolvedAt->lte($ticket->resolution_due_at) : null;

        return [
            'policy_id' => $ticket->sla_policy_id,
            'first_response_due_at' => $ticket->first_response_due_at?->toIso8601String(),
            'resolution_due_at' => $ticket->resolution_due_at?->toIso8601String(),
            'first_responded_at' => $ticket->first_responded_at?->toIso8601String(),
            'paused' => $ticket->sla_paused_at !== null && $ticket->status->isActive(),
            'paused_minutes' => $ticket->sla_paused_minutes,
            'response_met' => $responseMet,
            'resolution_met' => $resolutionMet,
            'response_breached' => $ticket->response_breached_at !== null
                || (! $ticket->first_responded_at && $ticket->first_response_due_at?->lt($now) && ! $ticket->sla_paused_at),
            'resolution_breached' => $ticket->resolution_breached_at !== null || $resolutionMet === false,
            'escalation_level' => $ticket->escalation_level,
        ];
    }
}
