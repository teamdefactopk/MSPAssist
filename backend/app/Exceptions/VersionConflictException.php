<?php

namespace App\Exceptions;

use App\Http\Resources\TicketResource;
use App\Models\Ticket;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use RuntimeException;

/** Thrown when a client submits a change based on an outdated ticket version. */
class VersionConflictException extends RuntimeException
{
    public function __construct(public readonly Ticket $ticket)
    {
        parent::__construct('The ticket was changed by someone else. Review the latest version and try again.');
    }

    public function render(Request $request): JsonResponse
    {
        return response()->json([
            'message' => $this->getMessage(),
            'code' => 'version_conflict',
            'current' => (new TicketResource($this->ticket->fresh()))->resolve($request),
        ], 409);
    }
}
