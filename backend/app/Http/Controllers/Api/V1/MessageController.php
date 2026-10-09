<?php

namespace App\Http\Controllers\Api\V1;

use App\Exceptions\WorkflowException;
use App\Http\Controllers\Controller;
use App\Http\Resources\MessageResource;
use App\Models\Attachment;
use App\Models\Ticket;
use App\Models\TicketMessage;
use App\Models\User;
use App\Notifications\NewTicketMessage;
use App\Services\SlaService;
use App\Services\TicketWorkflow;
use Illuminate\Database\UniqueConstraintViolationException;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Gate;
use Illuminate\Validation\ValidationException;

class MessageController extends Controller
{
    public function __construct(
        private readonly TicketWorkflow $workflow,
        private readonly SlaService $sla,
    ) {}

    /**
     * Cursor-paginated history.
     *  - `after_id`: messages newer than the id, oldest first (used for polling).
     *  - `before_id` (or nothing): the page of messages preceding the id, oldest first.
     */
    public function index(Request $request, Ticket $ticket): JsonResponse
    {
        Gate::authorize('view', $ticket);
        $user = $request->user();
        $data = $request->validate([
            'after_id' => ['nullable', 'integer', 'min:0'],
            'before_id' => ['nullable', 'integer', 'min:1'],
            'limit' => ['nullable', 'integer', 'min:1', 'max:'.config('mspassist.messages.max_page_size')],
        ]);
        $limit = (int) ($data['limit'] ?? config('mspassist.messages.page_size'));

        $base = $ticket->messages()->with(['user', 'attachments'])
            ->when($user->isClient(), fn ($q) => $q->where('is_internal', false));

        if (isset($data['after_id'])) {
            $rows = (clone $base)->where('id', '>', $data['after_id'])->orderBy('id')->limit($limit + 1)->get();
            $hasMore = $rows->count() > $limit;
            $rows = $rows->take($limit);
        } else {
            $rows = (clone $base)->when(isset($data['before_id']), fn ($q) => $q->where('id', '<', $data['before_id']))
                ->orderByDesc('id')->limit($limit + 1)->get();
            $hasMore = $rows->count() > $limit;
            $rows = $rows->take($limit)->reverse()->values();
        }

        $lastRead = (int) DB::table('ticket_reads')->where('ticket_id', $ticket->id)->where('user_id', $user->id)->value('last_read_message_id');
        $fresh = $ticket->fresh();

        return response()->json([
            'data' => MessageResource::collection($rows)->resolve($request),
            'meta' => [
                'has_more' => $hasMore,
                'last_read_message_id' => $lastRead,
                'unread_count' => (int) (clone $base)->where('id', '>', $lastRead)->where('user_id', '!=', $user->id)->count(),
                // Lets an open conversation notice ticket changes without another request.
                'ticket_version' => $fresh->version,
                'ticket_status' => $fresh->status->value,
            ],
        ]);
    }

    public function store(Request $request, Ticket $ticket): JsonResponse
    {
        Gate::authorize('view', $ticket);
        $user = $request->user();
        $data = $request->validate([
            'uuid' => ['required', 'uuid'],
            'body' => ['required', 'string', 'max:20000'],
            'is_internal' => ['sometimes', 'boolean'],
            'attachment_uuids' => ['sometimes', 'array', 'max:10'],
            'attachment_uuids.*' => ['uuid'],
        ]);
        $internal = (bool) ($data['is_internal'] ?? false);
        Gate::authorize('postMessage', [$ticket, $internal]);

        // Idempotent replay: the same client message id returns the stored message.
        if ($existing = TicketMessage::where('uuid', $data['uuid'])->first()) {
            return $this->replay($existing, $user, $ticket);
        }
        if ($ticket->status->value === 'closed') {
            throw new WorkflowException('This ticket is closed. Reopen it to continue the conversation.', 'ticket_closed');
        }

        try {
            $message = DB::transaction(function () use ($data, $ticket, $user, $internal) {
                $message = TicketMessage::create([
                    'uuid' => $data['uuid'],
                    'ticket_id' => $ticket->id,
                    'user_id' => $user->id,
                    'body' => $data['body'],
                    'is_internal' => $internal,
                ]);
                $this->attach($message, $data['attachment_uuids'] ?? [], $user);
                $this->markRead($ticket, $user, $message->id);

                return $message;
            });
        } catch (UniqueConstraintViolationException) {
            // A concurrent retry with the same uuid won the race.
            return $this->replay(TicketMessage::where('uuid', $data['uuid'])->firstOrFail(), $user, $ticket);
        }

        $this->afterPost($ticket, $message, $user);

        return (new MessageResource($message->load('user', 'attachments')))->response()->setStatusCode(201);
    }

    public function read(Request $request, Ticket $ticket): JsonResponse
    {
        Gate::authorize('view', $ticket);
        $data = $request->validate(['last_message_id' => ['required', 'integer', 'min:0']]);
        $this->markRead($ticket, $request->user(), (int) $data['last_message_id']);

        return response()->json(['last_read_message_id' => (int) DB::table('ticket_reads')
            ->where('ticket_id', $ticket->id)->where('user_id', $request->user()->id)->value('last_read_message_id')]);
    }

    private function replay(TicketMessage $existing, User $user, Ticket $ticket): JsonResponse
    {
        if ($existing->user_id !== $user->id || $existing->ticket_id !== $ticket->id) {
            return response()->json(['message' => 'This message id is already in use.', 'code' => 'duplicate_uuid'], 409);
        }

        return (new MessageResource($existing->load('user', 'attachments')))->response()->setStatusCode(200);
    }

    /** @param list<string> $uuids */
    private function attach(TicketMessage $message, array $uuids, User $user): void
    {
        if (! $uuids) {
            return;
        }
        $attachments = Attachment::whereIn('uuid', $uuids)->where('ticket_id', $message->ticket_id)
            ->where('uploaded_by', $user->id)->whereNull('message_id')->whereNull('work_log_id')->get();
        if ($attachments->count() !== count(array_unique($uuids))) {
            throw ValidationException::withMessages(['attachment_uuids' => 'One or more attachments are missing or already used.']);
        }
        Attachment::whereIn('id', $attachments->pluck('id'))->update([
            'message_id' => $message->id,
            'is_internal' => $message->is_internal,
        ]);
    }

    private function markRead(Ticket $ticket, User $user, int $messageId): void
    {
        $current = DB::table('ticket_reads')->where('ticket_id', $ticket->id)->where('user_id', $user->id)->value('last_read_message_id');
        if ($current === null) {
            DB::table('ticket_reads')->insertOrIgnore(['ticket_id' => $ticket->id, 'user_id' => $user->id, 'last_read_message_id' => $messageId, 'updated_at' => now()]);
        } elseif ($messageId > $current) {
            DB::table('ticket_reads')->where('ticket_id', $ticket->id)->where('user_id', $user->id)
                ->update(['last_read_message_id' => $messageId, 'updated_at' => now()]);
        }
    }

    private function afterPost(Ticket $ticket, TicketMessage $message, User $user): void
    {
        if ($user->isStaff() && ! $message->is_internal && ! $ticket->first_responded_at) {
            $this->workflow->mutate($ticket, null, function (Ticket $t) {
                $this->sla->recordFirstResponse($t);

                return true;
            }, bumpVersion: false);
        }
        if ($user->isClient()) {
            $this->workflow->onClientReply($user, $ticket->fresh());
        }
        Ticket::whereKey($ticket->id)->update(['last_activity_at' => now()]);

        $ticket->loadMissing('requester', 'assignee');
        $recipients = collect([$ticket->assignee, $message->is_internal ? null : $ticket->requester])
            ->filter(fn ($u) => $u && $u->id !== $user->id && $u->is_active)
            ->unique('id');
        $message->setRelation('user', $user);
        foreach ($recipients as $recipient) {
            $recipient->notify(new NewTicketMessage($ticket, $message));
        }
    }
}
