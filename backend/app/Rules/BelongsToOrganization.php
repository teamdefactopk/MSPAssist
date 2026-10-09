<?php

namespace App\Rules;

use Closure;
use Illuminate\Contracts\Validation\ValidationRule;
use Illuminate\Support\Facades\DB;

/** Ensures a referenced row exists and belongs to the given organization. */
class BelongsToOrganization implements ValidationRule
{
    public function __construct(private readonly string $table, private readonly int $organizationId) {}

    public function validate(string $attribute, mixed $value, Closure $fail): void
    {
        if ($value === null) {
            return;
        }
        $ok = DB::table($this->table)->where('id', $value)->where('organization_id', $this->organizationId)->exists();
        if (! $ok) {
            $fail('The selected :attribute does not belong to this client.');
        }
    }
}
