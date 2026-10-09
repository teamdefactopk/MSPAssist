<?php

namespace App\Services;

use App\Models\AuditLog;
use App\Models\User;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Str;

class AuditLogger
{
    /** @param array<string, mixed> $data */
    public static function log(string $action, ?Model $subject = null, array $data = [], ?User $user = null, ?int $organizationId = null): AuditLog
    {
        $request = request();
        $user ??= $request?->user();

        return AuditLog::create([
            'user_id' => $user?->id,
            'action' => $action,
            'subject_type' => $subject ? class_basename($subject) : null,
            'subject_id' => $subject?->getKey(),
            'organization_id' => $organizationId ?? ($subject?->getAttribute('organization_id')) ?? $user?->organization_id,
            'ip_address' => $request?->ip(),
            'user_agent' => $request ? Str::limit((string) $request->userAgent(), 250, '') : null,
            'data' => $data ?: null,
        ]);
    }
}
