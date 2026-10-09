<?php

namespace App\Http\Resources;

use App\Models\Equipment;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;

/** @mixin Equipment */
class EquipmentResource extends JsonResource
{
    public function toArray(Request $request): array
    {
        return [
            'id' => $this->id,
            'organization_id' => $this->organization_id,
            'site_id' => $this->site_id,
            'department_id' => $this->department_id,
            'name' => $this->name,
            'type' => $this->type,
            'manufacturer' => $this->manufacturer,
            'model' => $this->model,
            'serial_number' => $this->serial_number,
            'asset_tag' => $this->asset_tag,
            'purchase_date' => $this->purchase_date?->format('Y-m-d'),
            'warranty_expires_at' => $this->warranty_expires_at?->format('Y-m-d'),
            'status' => $this->status,
            'notes' => $this->notes,
        ];
    }
}
