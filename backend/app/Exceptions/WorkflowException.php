<?php

namespace App\Exceptions;

use Illuminate\Http\JsonResponse;
use RuntimeException;

/** A request that is well-formed but not allowed in the ticket's current state. */
class WorkflowException extends RuntimeException
{
    public function __construct(string $message, public readonly string $errorCode = 'invalid_transition', public readonly int $status = 409)
    {
        parent::__construct($message);
    }

    public function render(): JsonResponse
    {
        return response()->json(['message' => $this->getMessage(), 'code' => $this->errorCode], $this->status);
    }
}
