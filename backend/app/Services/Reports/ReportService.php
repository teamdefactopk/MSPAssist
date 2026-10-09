<?php

namespace App\Services\Reports;

use App\Enums\Priority;
use App\Enums\TicketStatus;
use App\Enums\WorkLogType;
use App\Models\Organization;
use App\Models\Ticket;
use App\Models\User;
use App\Models\WorkLog;
use App\Services\TicketWorkflow;
use Carbon\CarbonImmutable;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Collection;

/**
 * Builds report data as a list of tables, so the same structure can be
 * rendered as JSON (in-app), CSV or PDF.
 *
 * @phpstan-type Table array{title: string, columns: array<string, string>, rows: list<array<string, mixed>>}
 */
class ReportService
{
    public const TYPES = ['ticket-history', 'technician-activity', 'sla-performance', 'client-monthly'];

    /**
     * @param  array{from: CarbonImmutable, to: CarbonImmutable, organization_id: ?int, site_id: ?int, user_id: ?int}  $p
     * @return array{title: string, period: string, tables: list<array<string, mixed>>}
     */
    public function build(string $type, User $viewer, array $p): array
    {
        return match ($type) {
            'ticket-history' => $this->ticketHistory($viewer, $p),
            'technician-activity' => $this->technicianActivity($viewer, $p),
            'sla-performance' => $this->slaPerformance($viewer, $p),
            'client-monthly' => $this->clientMonthly($viewer, $p),
        };
    }

    private function tickets(User $viewer, array $p): Builder
    {
        return Ticket::query()->visibleTo($viewer)
            ->when($p['organization_id'], fn ($q, $id) => $q->where('tickets.organization_id', $id))
            ->when($p['site_id'], fn ($q, $id) => $q->where('tickets.site_id', $id))
            ->whereBetween('tickets.created_at', [$p['from'], $p['to']]);
    }

    private function period(array $p): string
    {
        return $p['from']->format('Y-m-d').' to '.$p['to']->format('Y-m-d');
    }

    private function ticketHistory(User $viewer, array $p): array
    {
        $tickets = $this->tickets($viewer, $p)
            ->with(['organization', 'site', 'category', 'requester', 'assignee'])
            ->withSum('workLogs as minutes_logged', 'minutes')
            ->orderBy('tickets.created_at')->get();

        return [
            'title' => 'Ticket history',
            'period' => $this->period($p),
            'tables' => [[
                'title' => 'Tickets',
                'columns' => [
                    'number' => 'Ticket', 'created_at' => 'Created (UTC)', 'client' => 'Client', 'site' => 'Site',
                    'category' => 'Category', 'priority' => 'Priority', 'status' => 'Status', 'subject' => 'Subject',
                    'requester' => 'Requester', 'assignee' => 'Technician', 'first_responded_at' => 'First response',
                    'resolved_at' => 'Resolved', 'closed_at' => 'Closed', 'response_sla' => 'Response SLA',
                    'resolution_sla' => 'Resolution SLA', 'reopen_count' => 'Reopened', 'minutes_logged' => 'Minutes logged',
                ],
                'rows' => $tickets->map(fn (Ticket $t) => [
                    'number' => $t->number,
                    'created_at' => $t->created_at->format('Y-m-d H:i'),
                    'client' => $t->organization->name,
                    'site' => $t->site->name,
                    'category' => $t->category?->name,
                    'priority' => $t->priority->label(),
                    'status' => $t->status->label(),
                    'subject' => $t->subject,
                    'requester' => $t->requester?->name,
                    'assignee' => $t->assignee?->name,
                    'first_responded_at' => $t->first_responded_at?->format('Y-m-d H:i'),
                    'resolved_at' => $t->resolved_at?->format('Y-m-d H:i'),
                    'closed_at' => $t->closed_at?->format('Y-m-d H:i'),
                    'response_sla' => $this->slaLabel($t->first_response_due_at, $t->first_responded_at),
                    'resolution_sla' => $this->slaLabel($t->resolution_due_at, $t->resolved_at),
                    'reopen_count' => $t->reopen_count,
                    'minutes_logged' => (int) $t->minutes_logged,
                ])->all(),
            ]],
        ];
    }

    private function slaLabel($due, $done): string
    {
        if (! $due) {
            return 'n/a';
        }
        if (! $done) {
            return $due->isPast() ? 'Breached' : 'Pending';
        }

        return $done->lte($due) ? 'Met' : 'Breached';
    }

    private function technicianActivity(User $viewer, array $p): array
    {
        $techs = User::whereIn('role', TicketWorkflow::assignableRoles())
            ->when(! $viewer->isManager(), fn ($q) => $q->whereKey($viewer->id))
            ->when($p['user_id'], fn ($q, $id) => $q->whereKey($id))
            ->orderBy('name')->get();

        $logs = WorkLog::with('ticket.organization', 'user')
            ->whereIn('user_id', $techs->pluck('id'))
            ->whereBetween('started_at', [$p['from'], $p['to']])
            ->when($p['organization_id'], fn ($q, $id) => $q->whereHas('ticket', fn ($t) => $t->where('organization_id', $id)))
            ->orderBy('started_at')->get();

        $resolved = Ticket::query()->whereIn('assigned_to', $techs->pluck('id'))
            ->whereBetween('resolved_at', [$p['from'], $p['to']])
            ->when($p['organization_id'], fn ($q, $id) => $q->where('organization_id', $id))
            ->selectRaw('assigned_to, count(*) as c')->groupBy('assigned_to')->pluck('c', 'assigned_to');
        $active = Ticket::query()->whereIn('assigned_to', $techs->pluck('id'))
            ->whereIn('status', TicketStatus::activeValues())
            ->selectRaw('assigned_to, count(*) as c')->groupBy('assigned_to')->pluck('c', 'assigned_to');

        $byUser = $logs->groupBy('user_id');

        return [
            'title' => 'Technician activity',
            'period' => $this->period($p),
            'tables' => [
                [
                    'title' => 'Summary',
                    'columns' => [
                        'technician' => 'Technician', 'active_tickets' => 'Active tickets', 'resolved' => 'Resolved in period',
                        'work_logs' => 'Work logs', 'minutes' => 'Minutes', 'hours' => 'Hours', 'onsite_visits' => 'Onsite visits',
                        'confirmed' => 'Client-confirmed logs',
                    ],
                    'rows' => $techs->map(function (User $t) use ($byUser, $resolved, $active) {
                        /** @var Collection<int, WorkLog> $l */
                        $l = $byUser->get($t->id, collect());
                        $minutes = (int) $l->sum('minutes');

                        return [
                            'technician' => $t->name,
                            'active_tickets' => (int) ($active[$t->id] ?? 0),
                            'resolved' => (int) ($resolved[$t->id] ?? 0),
                            'work_logs' => $l->count(),
                            'minutes' => $minutes,
                            'hours' => round($minutes / 60, 2),
                            'onsite_visits' => $l->where('type', WorkLogType::Onsite)->count(),
                            'confirmed' => $l->whereNotNull('client_confirmed_at')->count(),
                        ];
                    })->all(),
                ],
                [
                    'title' => 'Work logs',
                    'columns' => [
                        'date' => 'Started (UTC)', 'technician' => 'Technician', 'ticket' => 'Ticket', 'client' => 'Client',
                        'type' => 'Type', 'minutes' => 'Minutes', 'description' => 'Description', 'confirmed' => 'Confirmed',
                    ],
                    'rows' => $logs->map(fn (WorkLog $l) => [
                        'date' => $l->started_at->format('Y-m-d H:i'),
                        'technician' => $l->user->name,
                        'ticket' => $l->ticket->number,
                        'client' => $l->ticket->organization->name,
                        'type' => ucfirst($l->type->value),
                        'minutes' => $l->minutes,
                        'description' => $l->description,
                        'confirmed' => $l->client_confirmed_at ? 'Yes' : ($l->client_confirmation_name ? 'Onsite: '.$l->client_confirmation_name : 'No'),
                    ])->all(),
                ],
            ],
        ];
    }

    private function slaPerformance(User $viewer, array $p): array
    {
        $tickets = $this->tickets($viewer, $p)->with('organization')->get();

        $row = function (string $label, Collection $set) {
            $respMeasured = $set->filter(fn (Ticket $t) => $t->first_response_due_at && ($t->first_responded_at || $t->first_response_due_at->isPast()));
            $respMet = $respMeasured->filter(fn (Ticket $t) => $t->first_responded_at && $t->first_responded_at->lte($t->first_response_due_at));
            $resMeasured = $set->filter(fn (Ticket $t) => $t->resolution_due_at && ($t->resolved_at || ($t->resolution_due_at->isPast() && ! $t->sla_paused_at)));
            $resMet = $resMeasured->filter(fn (Ticket $t) => $t->resolved_at && $t->resolved_at->lte($t->resolution_due_at));
            $responseTimes = $set->filter(fn (Ticket $t) => $t->first_responded_at)->map(fn (Ticket $t) => $t->created_at->diffInMinutes($t->first_responded_at));
            $resolutionTimes = $set->filter(fn (Ticket $t) => $t->resolved_at)->map(fn (Ticket $t) => $t->created_at->diffInMinutes($t->resolved_at));

            return [
                'group' => $label,
                'tickets' => $set->count(),
                'response_met' => $respMet->count(),
                'response_measured' => $respMeasured->count(),
                'response_pct' => $respMeasured->count() ? round($respMet->count() / $respMeasured->count() * 100, 1) : null,
                'resolution_met' => $resMet->count(),
                'resolution_measured' => $resMeasured->count(),
                'resolution_pct' => $resMeasured->count() ? round($resMet->count() / $resMeasured->count() * 100, 1) : null,
                'avg_first_response_min' => $responseTimes->count() ? (int) round($responseTimes->avg()) : null,
                'avg_resolution_min' => $resolutionTimes->count() ? (int) round($resolutionTimes->avg()) : null,
            ];
        };
        $columns = [
            'group' => 'Group', 'tickets' => 'Tickets', 'response_met' => 'Response met', 'response_measured' => 'Response measured',
            'response_pct' => 'Response %', 'resolution_met' => 'Resolution met', 'resolution_measured' => 'Resolution measured',
            'resolution_pct' => 'Resolution %', 'avg_first_response_min' => 'Avg first response (min)', 'avg_resolution_min' => 'Avg resolution (min)',
        ];

        $byPriority = collect(Priority::cases())->map(fn (Priority $pr) => $row($pr->label(), $tickets->where('priority', $pr)))->all();
        $byPriority[] = $row('All', $tickets);
        $byClient = $tickets->groupBy('organization_id')->map(fn ($set) => $row($set->first()->organization->name, $set))->sortBy('group')->values()->all();

        return [
            'title' => 'SLA performance',
            'period' => $this->period($p),
            'tables' => [
                ['title' => 'By priority', 'columns' => $columns, 'rows' => $byPriority],
                ['title' => 'By client', 'columns' => $columns, 'rows' => $byClient],
            ],
        ];
    }

    private function clientMonthly(User $viewer, array $p): array
    {
        $org = Organization::findOrFail($p['organization_id']);
        $tickets = $this->tickets($viewer, $p)->with(['site', 'category', 'assignee'])->withSum('workLogs as minutes_logged', 'minutes')->get();
        $logs = WorkLog::whereHas('ticket', fn ($q) => $q->visibleTo($viewer)->where('organization_id', $org->id)
            ->when($p['site_id'], fn ($q, $id) => $q->where('site_id', $id)))
            ->whereBetween('started_at', [$p['from'], $p['to']])->get();
        $resolvedInPeriod = Ticket::query()->visibleTo($viewer)->where('organization_id', $org->id)
            ->when($p['site_id'], fn ($q, $id) => $q->where('site_id', $id))
            ->whereBetween('resolved_at', [$p['from'], $p['to']])->count();
        $openAtEnd = Ticket::query()->visibleTo($viewer)->where('organization_id', $org->id)
            ->when($p['site_id'], fn ($q, $id) => $q->where('site_id', $id))
            ->where('created_at', '<=', $p['to'])
            ->where(fn ($q) => $q->whereNull('resolved_at')->orWhere('resolved_at', '>', $p['to']))->count();
        $sla = $this->slaPerformance($viewer, $p)['tables'][0]['rows'];
        $all = end($sla);
        $minutes = (int) $logs->sum('minutes');

        $count = fn (string $key, callable $label) => $tickets->groupBy($key)->map(fn ($set) => [
            'name' => $label($set->first()) ?? 'Uncategorised', 'tickets' => $set->count(),
        ])->sortByDesc('tickets')->values()->all();

        return [
            'title' => "Monthly service report — {$org->name}",
            'period' => $this->period($p),
            'tables' => [
                [
                    'title' => 'Summary',
                    'columns' => ['metric' => 'Metric', 'value' => 'Value'],
                    'rows' => [
                        ['metric' => 'Tickets opened', 'value' => $tickets->count()],
                        ['metric' => 'Tickets resolved', 'value' => $resolvedInPeriod],
                        ['metric' => 'Open at period end', 'value' => $openAtEnd],
                        ['metric' => 'Response SLA met (%)', 'value' => $all['response_pct'] ?? 'n/a'],
                        ['metric' => 'Resolution SLA met (%)', 'value' => $all['resolution_pct'] ?? 'n/a'],
                        ['metric' => 'Support hours delivered', 'value' => round($minutes / 60, 2)],
                        ['metric' => 'Onsite visits', 'value' => $logs->where('type', WorkLogType::Onsite)->count()],
                    ],
                ],
                ['title' => 'Tickets by site', 'columns' => ['name' => 'Site', 'tickets' => 'Tickets'], 'rows' => $count('site_id', fn ($t) => $t->site?->name)],
                ['title' => 'Tickets by category', 'columns' => ['name' => 'Category', 'tickets' => 'Tickets'], 'rows' => $count('category_id', fn ($t) => $t->category?->name)],
                ['title' => 'Tickets by priority', 'columns' => ['name' => 'Priority', 'tickets' => 'Tickets'], 'rows' => $count('priority', fn ($t) => $t->priority->label())],
                [
                    'title' => 'Ticket details',
                    'columns' => [
                        'number' => 'Ticket', 'created_at' => 'Created (UTC)', 'site' => 'Site', 'subject' => 'Subject',
                        'priority' => 'Priority', 'status' => 'Status', 'technician' => 'Technician', 'minutes' => 'Minutes',
                    ],
                    'rows' => $tickets->sortBy('created_at')->map(fn (Ticket $t) => [
                        'number' => $t->number,
                        'created_at' => $t->created_at->format('Y-m-d H:i'),
                        'site' => $t->site->name,
                        'subject' => $t->subject,
                        'priority' => $t->priority->label(),
                        'status' => $t->status->label(),
                        'technician' => $t->assignee?->name,
                        'minutes' => (int) $t->minutes_logged,
                    ])->values()->all(),
                ],
            ],
        ];
    }
}
