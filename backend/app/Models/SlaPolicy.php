<?php

namespace App\Models;

use App\Enums\Priority;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\HasMany;

class SlaPolicy extends Model
{
    protected $guarded = ['id'];

    protected function casts(): array
    {
        return [
            'is_default' => 'boolean',
            'business_hours' => 'array',
            'holidays' => 'array',
            'pause_statuses' => 'array',
            'warning_percent' => 'integer',
        ];
    }

    public function targets(): HasMany
    {
        return $this->hasMany(SlaTarget::class);
    }

    public function targetFor(Priority $priority): ?SlaTarget
    {
        return $this->targets->firstWhere('priority', $priority->value);
    }

    public static function default(): ?self
    {
        return static::where('is_default', true)->first() ?? static::orderBy('id')->first();
    }

    public function pausesOn(string $status): bool
    {
        return in_array($status, $this->pause_statuses ?? [], true);
    }
}
