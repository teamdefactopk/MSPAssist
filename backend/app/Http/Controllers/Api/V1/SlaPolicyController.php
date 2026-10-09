<?php

namespace App\Http\Controllers\Api\V1;

use App\Enums\Priority;
use App\Enums\TicketStatus;
use App\Http\Controllers\Controller;
use App\Models\SlaPolicy;
use App\Services\AuditLogger;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Validation\Rule;
use Illuminate\Validation\ValidationException;

class SlaPolicyController extends Controller
{
    private const DAYS = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];

    public function index(Request $request): JsonResponse
    {
        abort_unless($request->user()->isStaff(), 403);

        return response()->json(['data' => SlaPolicy::with('targets')->orderBy('name')->get()->map(fn ($p) => $this->present($p))]);
    }

    public function store(Request $request): JsonResponse
    {
        abort_unless($request->user()->isManager(), 403);
        $policy = DB::transaction(fn () => $this->save(new SlaPolicy, $this->validated($request)));
        AuditLogger::log('sla_policy.created', $policy, ['name' => $policy->name]);

        return response()->json(['data' => $this->present($policy)], 201);
    }

    public function update(Request $request, SlaPolicy $slaPolicy): JsonResponse
    {
        abort_unless($request->user()->isManager(), 403);
        $policy = DB::transaction(fn () => $this->save($slaPolicy, $this->validated($request, true)));
        AuditLogger::log('sla_policy.updated', $policy, $request->except([]));

        return response()->json(['data' => $this->present($policy)]);
    }

    /** @return array<string, mixed> */
    private function validated(Request $request, bool $update = false): array
    {
        $req = $update ? 'sometimes' : 'required';
        $data = $request->validate([
            'name' => [$req, 'string', 'max:120'],
            'is_default' => ['sometimes', 'boolean'],
            'timezone' => [$req, 'timezone:all'],
            'business_hours' => ['nullable', 'array'],
            'business_hours.*' => ['array'],
            'business_hours.*.*' => ['array', 'size:2'],
            'business_hours.*.*.*' => ['string', 'regex:/^([01]\d|2[0-3]):[0-5]\d$|^24:00$/'],
            'holidays' => ['nullable', 'array'],
            'holidays.*' => ['date_format:Y-m-d'],
            'pause_statuses' => ['nullable', 'array'],
            'pause_statuses.*' => [Rule::in([TicketStatus::WaitingClient->value, TicketStatus::WaitingVendor->value])],
            'warning_percent' => ['sometimes', 'integer', 'min:10', 'max:99'],
            'targets' => [$req, 'array'],
            'targets.*.priority' => ['required', Rule::enum(Priority::class)],
            'targets.*.response_minutes' => ['required', 'integer', 'min:1', 'max:525600'],
            'targets.*.resolution_minutes' => ['required', 'integer', 'min:1', 'max:525600'],
        ]);
        foreach (array_keys($data['business_hours'] ?? []) as $day) {
            if (! in_array($day, self::DAYS, true)) {
                throw ValidationException::withMessages(['business_hours' => "Unknown day '{$day}'. Use mon..sun."]);
            }
            foreach ($data['business_hours'][$day] as [$open, $close]) {
                if ($close !== '24:00' && $close <= $open) {
                    throw ValidationException::withMessages(['business_hours' => "Closing time must be after opening time on {$day}."]);
                }
            }
        }
        foreach ($data['targets'] ?? [] as $t) {
            if ($t['resolution_minutes'] < $t['response_minutes']) {
                throw ValidationException::withMessages(['targets' => 'Resolution targets must be at least the response target.']);
            }
        }

        return $data;
    }

    private function save(SlaPolicy $policy, array $data): SlaPolicy
    {
        $targets = $data['targets'] ?? null;
        unset($data['targets']);
        $policy->fill($data)->save();
        if (! empty($data['is_default'])) {
            SlaPolicy::whereKeyNot($policy->id)->update(['is_default' => false]);
        }
        if ($targets !== null) {
            foreach ($targets as $t) {
                $policy->targets()->updateOrCreate(['priority' => $t['priority']], [
                    'response_minutes' => $t['response_minutes'],
                    'resolution_minutes' => $t['resolution_minutes'],
                ]);
            }
        }

        return $policy->load('targets');
    }

    /** @return array<string, mixed> */
    private function present(SlaPolicy $p): array
    {
        return [
            'id' => $p->id,
            'name' => $p->name,
            'is_default' => $p->is_default,
            'timezone' => $p->timezone,
            'business_hours' => $p->business_hours,
            'holidays' => $p->holidays ?? [],
            'pause_statuses' => $p->pause_statuses ?? [],
            'warning_percent' => $p->warning_percent,
            'targets' => $p->targets->map(fn ($t) => $t->only('priority', 'response_minutes', 'resolution_minutes'))->values(),
        ];
    }
}
