<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

class SlaTarget extends Model
{
    protected $guarded = ['id'];

    protected function casts(): array
    {
        return ['response_minutes' => 'integer', 'resolution_minutes' => 'integer'];
    }

    public function policy(): BelongsTo
    {
        return $this->belongsTo(SlaPolicy::class, 'sla_policy_id');
    }
}
