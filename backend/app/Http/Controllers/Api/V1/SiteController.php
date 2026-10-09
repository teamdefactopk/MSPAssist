<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Http\Resources\SiteResource;
use App\Models\Organization;
use App\Models\Site;
use App\Models\Ticket;
use App\Services\AuditLogger;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\AnonymousResourceCollection;
use Illuminate\Support\Facades\Gate;

class SiteController extends Controller
{
    public function index(Request $request, Organization $organization): AnonymousResourceCollection
    {
        Gate::authorize('view', $organization);
        $siteIds = $request->user()->accessibleSiteIds();

        return SiteResource::collection(
            $organization->sites()
                ->when($siteIds !== null, fn ($q) => $q->whereIn('id', $siteIds))
                ->orderBy('name')->get()
        );
    }

    public function store(Request $request, Organization $organization): JsonResponse
    {
        Gate::authorize('manageSites', $organization);
        $site = $organization->sites()->create($this->validated($request));
        AuditLogger::log('site.created', $site, ['name' => $site->name]);

        return (new SiteResource($site))->response()->setStatusCode(201);
    }

    public function update(Request $request, Site $site): SiteResource
    {
        Gate::authorize('manageSites', $site->organization);
        $site->update($this->validated($request, true));
        AuditLogger::log('site.updated', $site, $site->getChanges());

        return new SiteResource($site);
    }

    public function destroy(Site $site): JsonResponse
    {
        Gate::authorize('manageSites', $site->organization);
        if (Ticket::where('site_id', $site->id)->exists()) {
            return response()->json(['message' => 'Sites with tickets cannot be deleted. Deactivate the site instead.', 'code' => 'has_tickets'], 409);
        }
        AuditLogger::log('site.deleted', $site, ['name' => $site->name]);
        $site->delete();

        return response()->json(null, 204);
    }

    /** @return array<string, mixed> */
    private function validated(Request $request, bool $update = false): array
    {
        return $request->validate([
            'name' => [$update ? 'sometimes' : 'required', 'string', 'max:160'],
            'code' => ['nullable', 'string', 'max:30'],
            'address' => ['nullable', 'string', 'max:500'],
            'city' => ['nullable', 'string', 'max:120'],
            'phone' => ['nullable', 'string', 'max:50'],
            'timezone' => ['nullable', 'timezone:all'],
            'is_active' => ['sometimes', 'boolean'],
        ]);
    }
}
