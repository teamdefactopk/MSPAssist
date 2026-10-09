<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Http\Resources\DepartmentResource;
use App\Models\Department;
use App\Models\Organization;
use App\Rules\BelongsToOrganization;
use App\Services\AuditLogger;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\AnonymousResourceCollection;
use Illuminate\Support\Facades\Gate;

class DepartmentController extends Controller
{
    public function index(Organization $organization): AnonymousResourceCollection
    {
        Gate::authorize('view', $organization);

        return DepartmentResource::collection($organization->departments()->orderBy('name')->get());
    }

    public function store(Request $request, Organization $organization): JsonResponse
    {
        Gate::authorize('manageDirectory', $organization);
        $department = $organization->departments()->create($this->validated($request, $organization->id));
        AuditLogger::log('department.created', $department, ['name' => $department->name]);

        return (new DepartmentResource($department))->response()->setStatusCode(201);
    }

    public function update(Request $request, Department $department): DepartmentResource
    {
        Gate::authorize('manageDirectory', $department->organization);
        $department->update($this->validated($request, $department->organization_id, true));

        return new DepartmentResource($department);
    }

    public function destroy(Department $department): JsonResponse
    {
        Gate::authorize('manageDirectory', $department->organization);
        AuditLogger::log('department.deleted', $department, ['name' => $department->name]);
        $department->delete();

        return response()->json(null, 204);
    }

    /** @return array<string, mixed> */
    private function validated(Request $request, int $orgId, bool $update = false): array
    {
        return $request->validate([
            'name' => [$update ? 'sometimes' : 'required', 'string', 'max:160'],
            'site_id' => ['nullable', 'integer', new BelongsToOrganization('sites', $orgId)],
        ]);
    }
}
