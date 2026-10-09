<?php

namespace App\Http\Controllers\Api\V1;

use App\Enums\TicketStatus;
use App\Enums\WorkLogType;
use App\Exceptions\WorkflowException;
use App\Http\Controllers\Controller;
use App\Http\Resources\WorkLogResource;
use App\Models\Ticket;
use App\Models\WorkLog;
use App\Services\AuditLogger;
use App\Services\TicketWorkflow;
use Carbon\Carbon;
use Illuminate\Database\UniqueConstraintViolationException;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\AnonymousResourceCollection;
use Illuminate\Support\Facades\Gate;
use Illuminate\Validation\Rule;
use Illuminate\Validation\ValidationException;

class WorkLogController extends Controller
{
    public function __construct(private readonly TicketWorkflow $workflow) {}

    public function index(Request $request, Ticket $ticket): AnonymousResourceCollection
    {
        Gate::authorize('view', $ticket);

        return WorkLogResource::collection(
            $ticket->workLogs()->with(['user', 'confirmedBy', 'attachments'])->orderBy('started_at')->get()
        );
    }

    /** Technician activity across tickets (own logs for technicians, any for managers). */
    public function activity(Request $request): AnonymousResourceCollection
    {
        $user = $request->user();
        abort_unless($user->isStaff(), 403);
        $request->validate(['from' => ['nullable', 'date'], 'to' => ['nullable', 'date'], 'user_id' => ['nullable', 'integer']]);
        $userId = $user->isManager() ? $request->integer('user_id') ?: null : $user->id;

        return WorkLogResource::collection(
            WorkLog::with(['user', 'confirmedBy', 'ticket', 'attachments'])
                ->when($userId, fn ($q) => $q->where('user_id', $userId))
                ->when($request->filled('from'), fn ($q) => $q->where('started_at', '>=', $request->date('from')->startOfDay()))
                ->when($request->filled('to'), fn ($q) => $q->where('started_at', '<=', $request->date('to')->endOfDay()))
                ->orderByDesc('started_at')
                ->paginate(min($request->integer('per_page', 50), 200))
        );
    }

    public function store(Request $request, Ticket $ticket): JsonResponse
    {
        Gate::authorize('view', $ticket);
        Gate::authorize('logWork', $ticket);
        $user = $request->user();
        $data = $this->validated($request);

        if ($existing = WorkLog::where('uuid', $data['uuid'])->first()) {
            if ($existing->user_id !== $user->id || $existing->ticket_id !== $ticket->id) {
                return response()->json(['message' => 'This work log id is already in use.', 'code' => 'duplicate_uuid'], 409);
            }

            return (new WorkLogResource($existing->load('user', 'confirmedBy', 'attachments')))->response()->setStatusCode(200);
        }
        if ($ticket->status === TicketStatus::Closed) {
            throw new WorkflowException('Work cannot be logged on a closed ticket. Reopen it first.', 'ticket_closed');
        }

        try {
            $log = WorkLog::create($data + ['ticket_id' => $ticket->id, 'user_id' => $user->id]);
        } catch (UniqueConstraintViolationException) {
            $log = WorkLog::where('uuid', $data['uuid'])->firstOrFail();
        }

        // Logging work on an assigned ticket starts it.
        $ticket = $ticket->fresh();
        if (in_array($ticket->status, [TicketStatus::Open, TicketStatus::Assigned], true)) {
            $this->workflow->changeStatus($user, $ticket, TicketStatus::InProgress, null, 'Work logged');
            $ticket = $ticket->fresh();
        }
        $this->workflow->mutate($ticket, null, function (Ticket $t) use ($user, $log) {
            $this->workflow->event($t, $user, 'work_logged', null, null, $log->minutes.' min', $log->type->value.': '.mb_strimwidth($log->description, 0, 200, '…'));

            return true;
        });
        AuditLogger::log('work_log.created', $log, ['ticket_id' => $ticket->id, 'minutes' => $log->minutes], $user, $ticket->organization_id);

        return (new WorkLogResource($log->load('user', 'confirmedBy', 'attachments')))->response()->setStatusCode(201);
    }

    public function update(Request $request, WorkLog $workLog): WorkLogResource
    {
        $this->authorizeEdit($request, $workLog);
        $data = $this->validated($request, $workLog);
        $workLog->update($data);
        AuditLogger::log('work_log.updated', $workLog, $workLog->getChanges(), null, $workLog->ticket->organization_id);

        return new WorkLogResource($workLog->load('user', 'confirmedBy', 'attachments'));
    }

    public function destroy(Request $request, WorkLog $workLog): JsonResponse
    {
        $this->authorizeEdit($request, $workLog);
        AuditLogger::log('work_log.deleted', $workLog, ['minutes' => $workLog->minutes], null, $workLog->ticket->organization_id);
        $workLog->delete();

        return response()->json(null, 204);
    }

    /** A client user confirms the work was carried out. */
    public function confirm(Request $request, WorkLog $workLog): WorkLogResource
    {
        Gate::authorize('view', $workLog->ticket);
        Gate::authorize('confirmWork', $workLog->ticket);
        $data = $request->validate(['note' => ['nullable', 'string', 'max:2000']]);
        if ($workLog->isConfirmed()) {
            throw new WorkflowException('This work log has already been confirmed.', 'already_confirmed');
        }
        $workLog->update([
            'client_confirmed_by' => $request->user()->id,
            'client_confirmed_at' => now(),
            'client_confirmation_note' => $data['note'] ?? null,
        ]);
        $this->workflow->mutate($workLog->ticket, null, function (Ticket $t) use ($request, $workLog) {
            $this->workflow->event($t, $request->user(), 'work_confirmed', null, null, null, "Work log #{$workLog->id} confirmed");

            return true;
        });
        AuditLogger::log('work_log.confirmed', $workLog, [], null, $workLog->ticket->organization_id);

        return new WorkLogResource($workLog->load('user', 'confirmedBy', 'attachments'));
    }

    private function authorizeEdit(Request $request, WorkLog $workLog): void
    {
        $user = $request->user();
        abort_unless($user->isManager() || $workLog->user_id === $user->id, 403);
        Gate::authorize('view', $workLog->ticket);
        if ($workLog->isConfirmed()) {
            throw new WorkflowException('Confirmed work logs cannot be changed.', 'already_confirmed');
        }
    }

    /** @return array<string, mixed> */
    private function validated(Request $request, ?WorkLog $existing = null): array
    {
        $req = $existing ? 'sometimes' : 'required';
        $data = $request->validate([
            'uuid' => [$existing ? 'prohibited' : 'required', 'uuid'],
            'type' => [$req, Rule::enum(WorkLogType::class)],
            'started_at' => [$req, 'date'],
            'ended_at' => ['nullable', 'date'],
            'minutes' => ['nullable', 'integer', 'min:1', 'max:1440'],
            'description' => [$req, 'string', 'max:20000'],
            'client_confirmation_name' => ['nullable', 'string', 'max:160'],
        ]);
        $start = isset($data['started_at']) ? Carbon::parse($data['started_at'])->utc() : $existing?->started_at;
        $end = array_key_exists('ended_at', $data) ? ($data['ended_at'] ? Carbon::parse($data['ended_at'])->utc() : null) : $existing?->ended_at;
        if ($start && $end && $end->lte($start)) {
            throw ValidationException::withMessages(['ended_at' => 'The end time must be after the start time.']);
        }
        if ($start && $start->gt(now()->addMinutes(5))) {
            throw ValidationException::withMessages(['started_at' => 'Work cannot be logged in the future.']);
        }
        if (empty($data['minutes']) && ! $existing) {
            if (! $start || ! $end) {
                throw ValidationException::withMessages(['minutes' => 'Provide the time spent or an end time.']);
            }
            $data['minutes'] = max(1, (int) round($start->diffInMinutes($end)));
        }
        if (isset($data['started_at'])) {
            $data['started_at'] = $start;
        }
        if (array_key_exists('ended_at', $data)) {
            $data['ended_at'] = $end;
        }

        return $data;
    }
}
