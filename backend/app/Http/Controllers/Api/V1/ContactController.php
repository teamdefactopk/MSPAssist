<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Http\Resources\ContactResource;
use App\Models\Contact;
use App\Models\Organization;
use App\Rules\BelongsToOrganization;
use App\Services\AuditLogger;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\AnonymousResourceCollection;
use Illuminate\Support\Facades\Gate;

class ContactController extends Controller
{
    public function index(Organization $organization): AnonymousResourceCollection
    {
        Gate::authorize('view', $organization);

        return ContactResource::collection($organization->contacts()->orderByDesc('is_primary')->orderBy('name')->get());
    }

    public function store(Request $request, Organization $organization): JsonResponse
    {
        Gate::authorize('manageDirectory', $organization);
        $contact = $organization->contacts()->create($this->validated($request, $organization->id));
        AuditLogger::log('contact.created', $contact, ['name' => $contact->name]);

        return (new ContactResource($contact))->response()->setStatusCode(201);
    }

    public function update(Request $request, Contact $contact): ContactResource
    {
        Gate::authorize('manageDirectory', $contact->organization);
        $contact->update($this->validated($request, $contact->organization_id, true));
        AuditLogger::log('contact.updated', $contact, $contact->getChanges());

        return new ContactResource($contact);
    }

    public function destroy(Contact $contact): JsonResponse
    {
        Gate::authorize('manageDirectory', $contact->organization);
        AuditLogger::log('contact.deleted', $contact, ['name' => $contact->name]);
        $contact->delete();

        return response()->json(null, 204);
    }

    /** @return array<string, mixed> */
    private function validated(Request $request, int $orgId, bool $update = false): array
    {
        return $request->validate([
            'name' => [$update ? 'sometimes' : 'required', 'string', 'max:160'],
            'email' => ['nullable', 'email', 'max:255'],
            'phone' => ['nullable', 'string', 'max:50'],
            'job_title' => ['nullable', 'string', 'max:120'],
            'is_primary' => ['sometimes', 'boolean'],
            'site_id' => ['nullable', 'integer', new BelongsToOrganization('sites', $orgId)],
            'department_id' => ['nullable', 'integer', new BelongsToOrganization('departments', $orgId)],
        ]);
    }
}
