<?php

namespace App\Http\Controllers\Api\V1;

use App\Enums\TicketStatus;
use App\Http\Controllers\Controller;
use App\Http\Resources\TicketEventResource;
use App\Models\Ticket;
use App\Models\TicketEvent;
use App\Models\User;
use App\Services\TicketWorkflow;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;

class DashboardController extends Controller
{
    public function __invoke(Request $request): JsonResponse
    {
        $user = $request->user();
        $request->validate([
            'organization_id' => ['nullable', 'integer'],
            'site_id' => ['nullable', 'integer'],
            'from' => ['nullable', 'date'],
            'to' => ['nullable', 'date'],
        ]);
        $scoped = fn () => TicketController::applyFilters($request, Ticket::query()->visibleTo($user));
        $active = fn () => $scoped()->whereIn('tickets.status', TicketStatus::activeValues());

        $byStatus = $scoped()->selectRaw('tickets.status, count(*) as c')->groupBy('tickets.status')->pluck('c', 'status');
        $byPriority = $active()->selectRaw('tickets.priority, count(*) as c')->groupBy('tickets.priority')->pluck('c', 'priority');

        $data = [
            'counts' => [
                'active' => $active()->count(),
                'open' => (int) ($byStatus[TicketStatus::Open->value] ?? 0),
                'unassigned' => $active()->whereNull('tickets.assigned_to')->count(),
                'overdue' => $active()->overdue()->count(),
                'waiting' => $active()->whereIn('tickets.status', [TicketStatus::WaitingClient->value, TicketStatus::WaitingVendor->value])->count(),
                'assigned_to_me' => $user->isStaff() ? $active()->where('tickets.assigned_to', $user->id)->count() : null,
                'resolved_last_7_days' => $scoped()->where('tickets.resolved_at', '>=', now()->subDays(7))->count(),
            ],
            'by_status' => collect(TicketStatus::cases())->map(fn ($s) => [
                'status' => $s->value, 'label' => $s->label(), 'count' => (int) ($byStatus[$s->value] ?? 0),
            ])->values(),
            'by_priority' => collect(['critical', 'high', 'medium', 'low'])->map(fn ($p) => [
                'priority' => $p, 'count' => (int) ($byPriority[$p] ?? 0),
            ])->values(),
            'by_client' => $active()->join('organizations as o', 'o.id', '=', 'tickets.organization_id')
                ->selectRaw('o.id as organization_id, o.name, count(*) as active')
                ->groupBy('o.id', 'o.name')->orderByDesc('active')->limit(10)->get(),
            'by_site' => $active()->join('sites as s', 's.id', '=', 'tickets.site_id')
                ->join('organizations as o', 'o.id', '=', 'tickets.organization_id')
                ->selectRaw('s.id as site_id, s.name, o.name as organization, count(*) as active')
                ->groupBy('s.id', 's.name', 'o.name')->orderByDesc('active')->limit(10)->get(),
            'technician_workload' => $user->isStaff() ? $this->workload($request) : [],
            'recent_activity' => $this->recentActivity($request, $user),
            'generated_at' => now()->toIso8601String(),
        ];

        return response()->json(['data' => $data]);
    }

    /** @return list<array<string, mixed>> */
    private function workload(Request $request): array
    {
        $techs = User::whereIn('role', TicketWorkflow::assignableRoles())->where('is_active', true)->orderBy('name')->get(['id', 'name', 'role']);
        $user = $request->user();
        $active = TicketController::applyFilters($request, Ticket::query()->visibleTo($user))
            ->whereIn('tickets.status', TicketStatus::activeValues())->whereNotNull('tickets.assigned_to');

        $counts = (clone $active)->selectRaw('tickets.assigned_to, count(*) as total, sum(case when tickets.status = ? then 1 else 0 end) as in_progress', [TicketStatus::InProgress->value])
            ->groupBy('tickets.assigned_to')->get()->keyBy('assigned_to');
        $overdue = (clone $active)->overdue()->selectRaw('tickets.assigned_to, count(*) as c')->groupBy('tickets.assigned_to')->pluck('c', 'assigned_to');
        $minutes = DB::table('work_logs')->where('started_at', '>=', now()->subDays(7))
            ->selectRaw('user_id, sum(minutes) as m')->groupBy('user_id')->pluck('m', 'user_id');

        return $techs->map(fn (User $t) => [
            'user_id' => $t->id,
            'name' => $t->name,
            'role' => $t->role->value,
            'active' => (int) ($counts[$t->id]->total ?? 0),
            'in_progress' => (int) ($counts[$t->id]->in_progress ?? 0),
            'overdue' => (int) ($overdue[$t->id] ?? 0),
            'minutes_last_7_days' => (int) ($minutes[$t->id] ?? 0),
        ])->sortByDesc('active')->values()->all();
    }

    private function recentActivity(Request $request, User $user): array
    {
        $ticketIds = TicketController::applyFilters($request, Ticket::query()->visibleTo($user))->select('tickets.id');

        $events = TicketEvent::with(['user', 'ticket'])
            ->whereIn('ticket_id', $ticketIds)
            ->when($user->isClient(), fn ($q) => $q->where('is_internal', false))
            ->orderByDesc('id')->limit(20)->get();

        return TicketEventResource::collection($events)->resolve($request);
    }
}
