<?php

namespace App\Http\Controllers\Api\V1;

use App\Enums\Priority;
use App\Enums\Role;
use App\Enums\TicketStatus;
use App\Enums\WorkLogType;
use App\Http\Controllers\Controller;
use App\Models\Category;
use App\Models\Organization;
use App\Models\Site;
use App\Models\User;
use App\Services\TicketWorkflow;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;

/** Reference data the apps cache for forms and offline use. */
class LookupController extends Controller
{
    public function __invoke(Request $request): JsonResponse
    {
        $user = $request->user();
        $siteIds = $user->accessibleSiteIds();

        return response()->json(['data' => [
            'statuses' => array_map(fn (TicketStatus $s) => [
                'value' => $s->value, 'label' => $s->label(), 'active' => $s->isActive(),
                'transitions' => array_map(fn (TicketStatus $t) => $t->value, $s->allowedTransitions()),
            ], TicketStatus::cases()),
            'priorities' => array_map(fn (Priority $p) => ['value' => $p->value, 'label' => $p->label()], Priority::cases()),
            'roles' => array_map(fn (Role $r) => ['value' => $r->value, 'label' => $r->label(), 'is_staff' => $r->isStaff()], Role::cases()),
            'work_log_types' => array_map(fn (WorkLogType $t) => ['value' => $t->value, 'label' => ucfirst($t->value)], WorkLogType::cases()),
            'categories' => Category::where('is_active', true)->orderBy('name')->get(['id', 'name']),
            'organizations' => Organization::query()
                ->when($user->isClient(), fn ($q) => $q->whereKey($user->organization_id))
                ->where('is_active', true)->orderBy('name')->get(['id', 'name', 'code']),
            'sites' => Site::query()
                ->when($siteIds !== null, fn ($q) => $q->whereIn('id', $siteIds ?: [0]))
                ->where('is_active', true)->orderBy('name')->get(['id', 'organization_id', 'name']),
            'technicians' => $user->isStaff()
                ? User::whereIn('role', TicketWorkflow::assignableRoles())->where('is_active', true)->orderBy('name')->get(['id', 'name', 'role'])
                : [],
            'attachment' => [
                'max_kb' => config('mspassist.attachments.max_kb'),
                'extensions' => config('mspassist.attachments.extensions'),
            ],
            'client_reopen_days' => config('mspassist.client_reopen_days'),
        ]]);
    }
}
