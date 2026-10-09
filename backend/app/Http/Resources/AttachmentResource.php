<?php

namespace App\Http\Resources;

use App\Models\Attachment;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;

/** @mixin Attachment */
class AttachmentResource extends JsonResource
{
    public function toArray(Request $request): array
    {
        return [
            'id' => $this->id,
            'uuid' => $this->uuid,
            'ticket_id' => $this->ticket_id,
            'message_id' => $this->message_id,
            'work_log_id' => $this->work_log_id,
            'original_name' => $this->original_name,
            'mime_type' => $this->mime_type,
            'size' => $this->size,
            'is_internal' => $this->is_internal,
            'is_image' => str_starts_with($this->mime_type, 'image/'),
            'uploaded_by' => $this->uploaded_by,
            // Relative to the API base; downloads always require authentication.
            'download_path' => "attachments/{$this->id}/download",
            'created_at' => $this->created_at?->toIso8601String(),
        ];
    }
}
