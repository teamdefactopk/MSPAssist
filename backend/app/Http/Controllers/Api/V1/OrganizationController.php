<?php

namespace App\Http\Controllers\Api\V1;

use App\Enums\TicketStatus;
use App\Http\Controllers\Controller;
use App\Http\Resources\OrganizationResource;
use App\Models\Organization;
use App\Services\AuditLogger;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\AnonymousResourceCollection;
use Illuminate\Support\Facades\Gate;
use Illuminate\Validation\Rule;

class OrganizationController extends Controller
{
    public function index(Request $request): AnonymousResourceCollection
    {
        $user = $request->user();
        $orgs = Organization::query()
            ->withCount(['sites', 'tickets' => fn ($q) => $q->whereIn('status', TicketStatus::activeValues())])
            ->when($user->isClient(), fn ($q) => $q->whereKey($user->organization_id))
            ->when($request->filled('search'), function ($q) use ($request) {
                $term = '%'.$request->string('search').'%';
                $q->where(fn ($w) => $w->where('name', 'like', $term)->orWhere('code', 'like', $term));
            })
            ->when($request->has('active'), fn ($q) => $q->where('is_active', $request->boolean('active')))
            ->orderBy('name')
            ->paginate(min($request->integer('per_page', 50), 200));

        return OrganizationResource::collection($orgs);
    }

    public function show(Organization $organization): OrganizationResource
    {
        Gate::authorize('view', $organization);

        return new OrganizationResource($organization->loadCount(['sites', 'tickets' => fn ($q) => $q->whereIn('status', TicketStatus::activeValues())]));
    }

    public function store(Request $request): JsonResponse
    {
        Gate::authorize('create', Organization::class);
        $org = Organization::create($this->validated($request));
        AuditLogger::log('organization.created', $org, ['name' => $org->name]);

        return (new OrganizationResource($org))->response()->setStatusCode(201);
    }

    public function update(Request $request, Organization $organization): OrganizationResource
    {
        Gate::authorize('update', $organization);
        $organization->update($this->validated($request, $organization));
        AuditLogger::log('organization.updated', $organization, $organization->getChanges());

        return new OrganizationResource($organization);
    }

    public function destroy(Organization $organization): JsonResponse
    {
        Gate::authorize('delete', $organization);
        if ($organization->tickets()->exists()) {
            return response()->json(['message' => 'Organizations with tickets cannot be deleted. Deactivate it instead.', 'code' => 'has_tickets'], 409);
        }
        AuditLogger::log('organization.deleted', $organization, ['name' => $organization->name]);
        $organization->delete();

        return response()->json(null, 204);
    }

    /** @return array<string, mixed> */
    private function validated(Request $request, ?Organization $org = null): array
    {
        $req = $org ? 'sometimes' : 'required';

        return $request->validate([
            'name' => [$req, 'string', 'max:160'],
            'code' => [$req, 'string', 'max:20', 'alpha_dash', Rule::unique('organizations', 'code')->ignore($org?->id)],
            'email' => ['nullable', 'email', 'max:255'],
            'phone' => ['nullable', 'string', 'max:50'],
            'address' => ['nullable', 'string', 'max:500'],
            'timezone' => ['sometimes', 'timezone:all'],
            'sla_policy_id' => ['nullable', 'integer', 'exists:sla_policies,id'],
            'is_active' => ['sometimes', 'boolean'],
            'notes' => ['nullable', 'string', 'max:5000'],
        ]);
    }
}
