<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Http\Resources\EquipmentResource;
use App\Models\Equipment;
use App\Models\Organization;
use App\Rules\BelongsToOrganization;
use App\Services\AuditLogger;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\AnonymousResourceCollection;
use Illuminate\Support\Facades\Gate;

class EquipmentController extends Controller
{
    public function index(Request $request, Organization $organization): AnonymousResourceCollection
    {
        Gate::authorize('view', $organization);
        $siteIds = $request->user()->accessibleSiteIds();

        return EquipmentResource::collection(
            $organization->equipment()
                ->when($siteIds !== null, fn ($q) => $q->whereIn('site_id', $siteIds ?: [0]))
                ->when($request->filled('site_id'), fn ($q) => $q->where('site_id', $request->integer('site_id')))
                ->orderBy('name')->get()
        );
    }

    public function store(Request $request, Organization $organization): JsonResponse
    {
        Gate::authorize('manageEquipment', $organization);
        $equipment = $organization->equipment()->create($this->validated($request, $organization->id));
        AuditLogger::log('equipment.created', $equipment, ['name' => $equipment->name]);

        return (new EquipmentResource($equipment))->response()->setStatusCode(201);
    }

    public function update(Request $request, Equipment $equipment): EquipmentResource
    {
        Gate::authorize('manageEquipment', $equipment->organization);
        $equipment->update($this->validated($request, $equipment->organization_id, true));
        AuditLogger::log('equipment.updated', $equipment, $equipment->getChanges());

        return new EquipmentResource($equipment);
    }

    public function destroy(Equipment $equipment): JsonResponse
    {
        Gate::authorize('manageEquipment', $equipment->organization);
        AuditLogger::log('equipment.deleted', $equipment, ['name' => $equipment->name]);
        $equipment->delete();

        return response()->json(null, 204);
    }

    /** @return array<string, mixed> */
    private function validated(Request $request, int $orgId, bool $update = false): array
    {
        return $request->validate([
            'name' => [$update ? 'sometimes' : 'required', 'string', 'max:160'],
            'site_id' => ['nullable', 'integer', new BelongsToOrganization('sites', $orgId)],
            'department_id' => ['nullable', 'integer', new BelongsToOrganization('departments', $orgId)],
            'type' => ['nullable', 'string', 'max:60'],
            'manufacturer' => ['nullable', 'string', 'max:120'],
            'model' => ['nullable', 'string', 'max:120'],
            'serial_number' => ['nullable', 'string', 'max:120'],
            'asset_tag' => ['nullable', 'string', 'max:60'],
            'purchase_date' => ['nullable', 'date'],
            'warranty_expires_at' => ['nullable', 'date'],
            'status' => ['sometimes', 'in:active,in_repair,retired'],
            'notes' => ['nullable', 'string', 'max:5000'],
        ]);
    }
}
