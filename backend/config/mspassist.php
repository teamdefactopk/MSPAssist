<?php

return [
    // Prefix for human-readable ticket numbers, e.g. CC-2026-000123.
    'ticket_prefix' => env('MSPASSIST_TICKET_PREFIX', 'CC'),

    // Base URL of the Flutter web app, used in invitation and password-reset links.
    'frontend_url' => rtrim(env('MSPASSIST_FRONTEND_URL', env('APP_URL', 'http://localhost').'/app'), '/'),

    'invitation_ttl_hours' => (int) env('MSPASSIST_INVITATION_TTL_HOURS', 72),

    // Client users may reopen a closed ticket for this many days after closing.
    'client_reopen_days' => (int) env('MSPASSIST_CLIENT_REOPEN_DAYS', 14),

    // Move a ticket from "Waiting for Client" back to "In Progress" when the client replies.
    'resume_on_client_reply' => (bool) env('MSPASSIST_RESUME_ON_CLIENT_REPLY', true),

    'attachments' => [
        'disk' => env('MSPASSIST_ATTACHMENT_DISK', 'local'),
        'max_kb' => (int) env('MSPASSIST_ATTACHMENT_MAX_KB', 10240),
        // Extensions are validated together with the detected MIME type.
        'extensions' => ['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'pdf', 'txt', 'log', 'csv', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'zip'],
    ],

    'sla' => [
        // Escalate a resolution breach to administrators after this many minutes.
        'admin_escalation_minutes' => (int) env('MSPASSIST_SLA_ADMIN_ESCALATION_MINUTES', 240),
        'send_mail' => (bool) env('MSPASSIST_SLA_SEND_MAIL', true),
    ],

    'messages' => [
        'page_size' => 30,
        'max_page_size' => 100,
    ],
];
