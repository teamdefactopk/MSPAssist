<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Http\Resources\AttachmentResource;
use App\Models\Attachment;
use App\Models\Ticket;
use App\Models\WorkLog;
use App\Services\AuditLogger;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\AnonymousResourceCollection;
use Illuminate\Support\Facades\Gate;
use Illuminate\Support\Facades\Storage;
use Illuminate\Validation\ValidationException;
use Symfony\Component\HttpFoundation\StreamedResponse;
use Symfony\Component\Mime\MimeTypes;

class AttachmentController extends Controller
{
    /** Image types that are safe to render inline in the app. */
    private const INLINE_TYPES = ['image/png', 'image/jpeg', 'image/gif', 'image/webp'];

    public function index(Request $request, Ticket $ticket): AnonymousResourceCollection
    {
        Gate::authorize('view', $ticket);

        return AttachmentResource::collection(
            $ticket->attachments()
                ->when($request->user()->isClient(), fn ($q) => $q->where('is_internal', false))
                ->where(fn ($q) => $q->whereNotNull('message_id')->orWhereNotNull('work_log_id')->orWhere('uploaded_by', $request->user()->id))
                ->orderBy('id')->get()
        );
    }

    /**
     * Upload a file to a ticket. Idempotent on `uuid`. Files are stored on a
     * private disk under a random name without extension and are only ever
     * served through the authorized download endpoint.
     */
    public function store(Request $request, Ticket $ticket): JsonResponse
    {
        Gate::authorize('view', $ticket);
        $user = $request->user();
        $extensions = config('mspassist.attachments.extensions');
        $data = $request->validate([
            'uuid' => ['required', 'uuid'],
            'file' => ['required', 'file', 'max:'.config('mspassist.attachments.max_kb'), 'mimes:'.implode(',', $extensions)],
            'is_internal' => ['sometimes', 'boolean'],
            'work_log_uuid' => ['nullable', 'uuid'],
        ]);
        $internal = (bool) ($data['is_internal'] ?? false);
        if ($internal && ! $user->isStaff()) {
            abort(403, 'Only staff can add internal attachments.');
        }

        if ($existing = Attachment::where('uuid', $data['uuid'])->first()) {
            if ($existing->uploaded_by !== $user->id || $existing->ticket_id !== $ticket->id) {
                return response()->json(['message' => 'This attachment id is already in use.', 'code' => 'duplicate_uuid'], 409);
            }

            return (new AttachmentResource($existing))->response()->setStatusCode(200);
        }

        $file = $request->file('file');
        $clientExtension = strtolower($file->getClientOriginalExtension());
        if (! in_array($clientExtension, $extensions, true)) {
            throw ValidationException::withMessages(['file' => 'This file type is not allowed.']);
        }

        // Sniff the real content type; never trust the client's extension or header.
        $detected = (new \finfo(FILEINFO_MIME_TYPE))->file($file->getRealPath()) ?: 'application/octet-stream';
        $detectedExtensions = MimeTypes::getDefault()->getExtensions($detected);
        if (str_contains($detected, 'php') || ! array_intersect($detectedExtensions, $extensions)) {
            throw ValidationException::withMessages(['file' => 'The file content does not match an allowed type.']);
        }

        $workLogId = null;
        if (! empty($data['work_log_uuid'])) {
            $workLog = WorkLog::where('uuid', $data['work_log_uuid'])->where('ticket_id', $ticket->id)->first();
            if (! $workLog || ($workLog->user_id !== $user->id && ! $user->isManager())) {
                throw ValidationException::withMessages(['work_log_uuid' => 'Work log not found on this ticket.']);
            }
            $workLogId = $workLog->id;
        }

        $disk = config('mspassist.attachments.disk');
        $path = $file->storeAs("attachments/{$ticket->id}", $data['uuid'], ['disk' => $disk]);

        $attachment = Attachment::create([
            'uuid' => $data['uuid'],
            'ticket_id' => $ticket->id,
            'work_log_id' => $workLogId,
            'uploaded_by' => $user->id,
            'disk' => $disk,
            'path' => $path,
            'original_name' => mb_substr(basename($file->getClientOriginalName()), 0, 255),
            'mime_type' => $detected,
            'size' => $file->getSize(),
            'sha256' => hash_file('sha256', $file->getRealPath()),
            'is_internal' => $internal,
        ]);
        AuditLogger::log('attachment.uploaded', $attachment, ['ticket_id' => $ticket->id, 'name' => $attachment->original_name], $user, $ticket->organization_id);

        return (new AttachmentResource($attachment))->response()->setStatusCode(201);
    }

    public function download(Request $request, Attachment $attachment): StreamedResponse
    {
        $user = $request->user();
        $ticket = $attachment->ticket;
        // Authorization on every download: ticket visibility plus internal flag.
        Gate::authorize('view', $ticket);
        abort_if($attachment->is_internal && ! $user->isStaff(), 404);
        // Unlinked uploads are only visible to their uploader.
        abort_if(! $attachment->message_id && ! $attachment->work_log_id && $attachment->uploaded_by !== $user->id, 404);

        $inline = $request->boolean('inline') && in_array($attachment->mime_type, self::INLINE_TYPES, true);
        $disposition = $inline ? 'inline' : 'attachment';

        return Storage::disk($attachment->disk)->download($attachment->path, $attachment->original_name, [
            'Content-Type' => $inline ? $attachment->mime_type : 'application/octet-stream',
            'Content-Disposition' => $disposition.'; filename="'.addcslashes(preg_replace('/[^\x20-\x7E]/', '_', $attachment->original_name), '"\\').'"',
            'X-Content-Type-Options' => 'nosniff',
            'Content-Security-Policy' => "default-src 'none'; sandbox",
            'Cache-Control' => 'private, no-store',
        ]);
    }

    public function destroy(Request $request, Attachment $attachment): JsonResponse
    {
        $user = $request->user();
        Gate::authorize('view', $attachment->ticket);
        $ownUnlinked = $attachment->uploaded_by === $user->id && ! $attachment->message_id;
        abort_unless($ownUnlinked || $user->isManager(), 403);

        Storage::disk($attachment->disk)->delete($attachment->path);
        AuditLogger::log('attachment.deleted', $attachment, ['name' => $attachment->original_name], $user, $attachment->ticket->organization_id);
        $attachment->delete();

        return response()->json(null, 204);
    }
}
