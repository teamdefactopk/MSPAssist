<?php

namespace App\Http\Controllers\Api\V1;

use App\Enums\Priority;
use App\Enums\TicketStatus;
use App\Http\Controllers\Controller;
use App\Http\Resources\TicketEventResource;
use App\Http\Resources\TicketResource;
use App\Models\Site;
use App\Models\Ticket;
use App\Models\User;
use App\Notifications\TicketResolved;
use App\Rules\BelongsToOrganization;
use App\Services\TicketWorkflow;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\AnonymousResourceCollection;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Gate;
use Illuminate\Validation\Rule;
use Illuminate\Validation\ValidationException;

class TicketController extends Controller
{
    public function __construct(private readonly TicketWorkflow $workflow) {}

    public function index(Request $request): JsonResponse
    {
        $user = $request->user();
        $request->validate([
            'status' => ['nullable', 'string'],
            'priority' => ['nullable', 'string'],
            'updated_since' => ['nullable', 'date'],
            'per_page' => ['nullable', 'integer', 'min:1', 'max:200'],
            'sort' => ['nullable', Rule::in(['updated', 'created', 'priority', 'due'])],
        ]);

        $query = $this->filtered($request, Ticket::query()->visibleTo($user));
        $query->with(['organization', 'site', 'department', 'equipment', 'category', 'requester', 'assignee', 'contact'])
            ->addSelect(['unread_count' => $this->unreadSubquery($user)]);

        match ($request->input('sort', 'updated')) {
            'created' => $query->orderByDesc('tickets.created_at'),
            'priority' => $query->orderByRaw("CASE tickets.priority WHEN 'critical' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END")->orderByDesc('tickets.updated_at'),
            'due' => $query->orderByRaw('tickets.resolution_due_at IS NULL')->orderBy('tickets.resolution_due_at'),
            default => $query->orderByDesc('tickets.updated_at'),
        };
        $query->orderByDesc('tickets.id');

        $page = $query->paginate($request->integer('per_page', 25));

        return response()->json([
            'data' => TicketResource::collection($page->getCollection())->resolve($request),
            'meta' => [
                'current_page' => $page->currentPage(),
                'last_page' => $page->lastPage(),
                'per_page' => $page->perPage(),
                'total' => $page->total(),
                // Clients use this as the next `updated_since` cursor for incremental sync.
                'server_time' => now()->toIso8601String(),
            ],
        ]);
    }

    /** Applies list filters shared by the ticket list, dashboard and reports. */
    public static function applyFilters(Request $request, Builder $query): Builder
    {
        $user = $request->user();

        return $query
            ->when($request->filled('status'), fn ($q) => $q->whereIn('tickets.status', explode(',', $request->string('status'))))
            ->when($request->input('state') === 'active', fn ($q) => $q->whereIn('tickets.status', TicketStatus::activeValues()))
            ->when($request->input('state') === 'inactive', fn ($q) => $q->whereNotIn('tickets.status', TicketStatus::activeValues()))
            ->when($request->filled('priority'), fn ($q) => $q->whereIn('tickets.priority', explode(',', $request->string('priority'))))
            ->when($request->filled('organization_id'), fn ($q) => $q->where('tickets.organization_id', $request->integer('organization_id')))
            ->when($request->filled('site_id'), fn ($q) => $q->where('tickets.site_id', $request->integer('site_id')))
            ->when($request->filled('category_id'), fn ($q) => $q->where('tickets.category_id', $request->integer('category_id')))
            ->when($request->filled('assigned_to'), function ($q) use ($request, $user) {
                $v = $request->input('assigned_to');
                match ($v) {
                    'me' => $q->where('tickets.assigned_to', $user->id),
                    'none' => $q->whereNull('tickets.assigned_to'),
                    default => $q->where('tickets.assigned_to', (int) $v),
                };
            })
            ->when($request->boolean('mine'), fn ($q) => $q->where('tickets.requester_id', $user->id))
            ->when($request->boolean('overdue'), fn ($q) => $q->overdue())
            ->when($request->filled('from'), fn ($q) => $q->where('tickets.created_at', '>=', $request->date('from')->startOfDay()))
            ->when($request->filled('to'), fn ($q) => $q->where('tickets.created_at', '<=', $request->date('to')->endOfDay()))
            ->when($request->filled('updated_since'), fn ($q) => $q->where('tickets.updated_at', '>', $request->date('updated_since')))
            ->when($request->filled('search'), function ($q) use ($request) {
                $term = '%'.$request->string('search').'%';
                $q->where(fn ($w) => $w->where('tickets.subject', 'like', $term)->orWhere('tickets.number', 'like', $term)->orWhere('tickets.description', 'like', $term));
            });
    }

    private function filtered(Request $request, Builder $query): Builder
    {
        return self::applyFilters($request, $query->select('tickets.*'));
    }

    /** Count of visible messages newer than the user's read marker, excluding their own. */
    public static function unreadSubquery(User $user): \Illuminate\Database\Query\Builder
    {
        return DB::table('ticket_messages as m')
            ->selectRaw('count(*)')
            ->whereColumn('m.ticket_id', 'tickets.id')
            ->where('m.user_id', '!=', $user->id)
            ->when($user->isClient(), fn ($q) => $q->where('m.is_internal', false))
            ->whereRaw('m.id > coalesce((select r.last_read_message_id from ticket_reads r where r.ticket_id = tickets.id and r.user_id = ?), 0)', [$user->id]);
    }

    public function store(Request $request): JsonResponse
    {
        $user = $request->user();
        $data = $request->validate([
            'uuid' => ['required', 'uuid'],
            'organization_id' => ['required', 'integer', 'exists:organizations,id'],
            'site_id' => ['required', 'integer'],
            'subject' => ['required', 'string', 'max:200'],
            'description' => ['required', 'string', 'max:20000'],
            'priority' => ['nullable', Rule::enum(Priority::class)],
            'category_id' => ['nullable', 'integer', Rule::exists('categories', 'id')->where('is_active', true)],
            'source' => ['nullable', Rule::in(['web', 'mobile', 'desktop', 'email', 'phone'])],
            'assigned_to' => ['nullable', 'integer', 'exists:users,id'],
        ]);
        $orgId = (int) $data['organization_id'];
        if (! $user->canAccessOrganization($orgId)) {
            abort(403, 'You cannot create tickets for this client.');
        }
        $site = Site::where('id', $data['site_id'])->where('organization_id', $orgId)->first();
        if (! $site || ! $user->canAccessSite($site)) {
            throw ValidationException::withMessages(['site_id' => 'The selected site is not available to you.']);
        }
        $data += $request->validate([
            'department_id' => ['nullable', 'integer', new BelongsToOrganization('departments', $orgId)],
            'equipment_id' => ['nullable', 'integer', new BelongsToOrganization('equipment', $orgId)],
            'contact_id' => ['nullable', 'integer', new BelongsToOrganization('contacts', $orgId)],
        ]);
        if (! empty($data['assigned_to'])) {
            $assignee = $user->isManager() ? User::find($data['assigned_to']) : null;
            if (! $assignee) {
                unset($data['assigned_to']);
            } elseif (! $assignee->isStaff() || ! $assignee->is_active) {
                // Validate before creating so a bad assignee never leaves a half-done ticket.
                throw ValidationException::withMessages(['assigned_to' => 'Tickets can only be assigned to active CyberCraft staff.']);
            }
        }

        [$ticket, $created] = $this->workflow->create($user, $data);

        return (new TicketResource($this->load($ticket)))->response()->setStatusCode($created ? 201 : 200);
    }

    public function show(Request $request, Ticket $ticket): TicketResource
    {
        Gate::authorize('view', $ticket);
        $ticket = Ticket::whereKey($ticket->id)->select('tickets.*')
            ->addSelect(['unread_count' => $this->unreadSubquery($request->user())])->first();

        return new TicketResource($this->load($ticket));
    }

    public function update(Request $request, Ticket $ticket): TicketResource
    {
        Gate::authorize('update', $ticket);
        $orgId = $ticket->organization_id;
        $data = $request->validate([
            'version' => ['required', 'integer'],
            'subject' => ['sometimes', 'required', 'string', 'max:200'],
            'description' => ['sometimes', 'required', 'string', 'max:20000'],
            'priority' => ['sometimes', Rule::enum(Priority::class)],
            'category_id' => ['sometimes', 'nullable', 'integer', 'exists:categories,id'],
            'department_id' => ['sometimes', 'nullable', 'integer', new BelongsToOrganization('departments', $orgId)],
            'equipment_id' => ['sometimes', 'nullable', 'integer', new BelongsToOrganization('equipment', $orgId)],
            'contact_id' => ['sometimes', 'nullable', 'integer', new BelongsToOrganization('contacts', $orgId)],
        ]);
        $version = (int) $data['version'];
        unset($data['version']);

        return new TicketResource($this->load($this->workflow->update($request->user(), $ticket, $data, $version)));
    }

    public function assign(Request $request, Ticket $ticket): TicketResource
    {
        Gate::authorize('view', $ticket);
        $data = $request->validate([
            'assigned_to' => ['present', 'nullable', 'integer', 'exists:users,id'],
            'version' => ['required', 'integer'],
        ]);
        $assignee = $data['assigned_to'] ? User::find($data['assigned_to']) : null;
        Gate::authorize('assign', [$ticket, $assignee]);

        return new TicketResource($this->load($this->workflow->assign($request->user(), $ticket, $assignee, (int) $data['version'])));
    }

    public function changeStatus(Request $request, Ticket $ticket): TicketResource
    {
        Gate::authorize('view', $ticket);
        $data = $request->validate([
            'status' => ['required', Rule::enum(TicketStatus::class)],
            'version' => ['required', 'integer'],
            'note' => ['nullable', 'string', 'max:5000'],
            'resolution_notes' => ['nullable', 'string', 'max:20000'],
        ]);
        $to = TicketStatus::from($data['status']);
        Gate::authorize('changeStatus', [$ticket, $to]);

        $user = $request->user();
        $updated = $this->workflow->changeStatus($user, $ticket, $to, (int) $data['version'], $data['note'] ?? null, $data['resolution_notes'] ?? null);
        if ($to === TicketStatus::Resolved && $updated->wasChanged('status') && $updated->requester_id !== $user->id) {
            $updated->requester?->notify(new TicketResolved($updated));
        }

        return new TicketResource($this->load($updated));
    }

    public function reopen(Request $request, Ticket $ticket): TicketResource
    {
        Gate::authorize('view', $ticket);
        Gate::authorize('reopen', $ticket);
        $data = $request->validate([
            'reason' => ['required', 'string', 'max:5000'],
            'version' => ['required', 'integer'],
        ]);

        return new TicketResource($this->load($this->workflow->reopen($request->user(), $ticket, $data['reason'], (int) $data['version'])));
    }

    public function history(Request $request, Ticket $ticket): AnonymousResourceCollection
    {
        Gate::authorize('view', $ticket);
        $events = $ticket->events()->with('user')
            ->when($request->user()->isClient(), fn ($q) => $q->where('is_internal', false))
            ->orderBy('id')->get();

        return TicketEventResource::collection($events);
    }

    private function load(Ticket $ticket): Ticket
    {
        return $ticket->load(['organization', 'site', 'department', 'equipment', 'category', 'requester', 'assignee', 'contact']);
    }
}
