<?php

use App\Http\Controllers\Api\V1;
use Illuminate\Support\Facades\Route;

/*
| Versioned REST API. All routes are prefixed with /api/v1.
| Authentication: Sanctum bearer tokens (mobile/desktop) or the session cookie
| with CSRF protection (web dashboard on a stateful domain).
*/

Route::prefix('v1')->group(function () {
    Route::get('health', fn () => ['status' => 'ok', 'time' => now()->toIso8601String()]);

    // Public auth endpoints (rate limited)
    Route::middleware('throttle:auth')->group(function () {
        Route::post('auth/login', [V1\AuthController::class, 'login']);
        Route::post('auth/token', [V1\AuthController::class, 'token']);
        Route::post('auth/forgot-password', [V1\AuthController::class, 'forgotPassword']);
        Route::post('auth/reset-password', [V1\AuthController::class, 'resetPassword']);
        Route::get('invitations/{token}', [V1\InvitationController::class, 'show'])->where('token', '[A-Za-z0-9]{64}');
        Route::post('invitations/accept', [V1\InvitationController::class, 'accept']);
    });

    Route::middleware(['auth:sanctum', 'active', 'throttle:api'])->group(function () {
        Route::post('auth/logout', [V1\AuthController::class, 'logout']);
        Route::get('me', [V1\AuthController::class, 'me']);
        Route::patch('me', [V1\AuthController::class, 'updateProfile']);
        Route::put('me/password', [V1\AuthController::class, 'changePassword']);

        Route::get('lookups', V1\LookupController::class);
        Route::get('dashboard', V1\DashboardController::class);

        Route::get('invitations', [V1\InvitationController::class, 'index']);
        Route::post('invitations', [V1\InvitationController::class, 'store']);
        Route::delete('invitations/{invitation}', [V1\InvitationController::class, 'destroy']);

        Route::get('users', [V1\UserController::class, 'index']);
        Route::get('users/{user}', [V1\UserController::class, 'show']);
        Route::patch('users/{user}', [V1\UserController::class, 'update']);

        Route::apiResource('organizations', V1\OrganizationController::class);
        Route::get('organizations/{organization}/sites', [V1\SiteController::class, 'index']);
        Route::post('organizations/{organization}/sites', [V1\SiteController::class, 'store']);
        Route::patch('sites/{site}', [V1\SiteController::class, 'update']);
        Route::delete('sites/{site}', [V1\SiteController::class, 'destroy']);
        Route::get('organizations/{organization}/departments', [V1\DepartmentController::class, 'index']);
        Route::post('organizations/{organization}/departments', [V1\DepartmentController::class, 'store']);
        Route::patch('departments/{department}', [V1\DepartmentController::class, 'update']);
        Route::delete('departments/{department}', [V1\DepartmentController::class, 'destroy']);
        Route::get('organizations/{organization}/contacts', [V1\ContactController::class, 'index']);
        Route::post('organizations/{organization}/contacts', [V1\ContactController::class, 'store']);
        Route::patch('contacts/{contact}', [V1\ContactController::class, 'update']);
        Route::delete('contacts/{contact}', [V1\ContactController::class, 'destroy']);
        Route::get('organizations/{organization}/equipment', [V1\EquipmentController::class, 'index']);
        Route::post('organizations/{organization}/equipment', [V1\EquipmentController::class, 'store']);
        Route::patch('equipment/{equipment}', [V1\EquipmentController::class, 'update']);
        Route::delete('equipment/{equipment}', [V1\EquipmentController::class, 'destroy']);

        Route::get('categories', [V1\CategoryController::class, 'index']);
        Route::post('categories', [V1\CategoryController::class, 'store']);
        Route::patch('categories/{category}', [V1\CategoryController::class, 'update']);
        Route::get('sla-policies', [V1\SlaPolicyController::class, 'index']);
        Route::post('sla-policies', [V1\SlaPolicyController::class, 'store']);
        Route::patch('sla-policies/{slaPolicy}', [V1\SlaPolicyController::class, 'update']);

        Route::get('tickets', [V1\TicketController::class, 'index']);
        Route::post('tickets', [V1\TicketController::class, 'store']);
        Route::get('tickets/{ticket}', [V1\TicketController::class, 'show']);
        Route::patch('tickets/{ticket}', [V1\TicketController::class, 'update']);
        Route::post('tickets/{ticket}/assign', [V1\TicketController::class, 'assign']);
        Route::post('tickets/{ticket}/status', [V1\TicketController::class, 'changeStatus']);
        Route::post('tickets/{ticket}/reopen', [V1\TicketController::class, 'reopen']);
        Route::get('tickets/{ticket}/history', [V1\TicketController::class, 'history']);

        Route::get('tickets/{ticket}/messages', [V1\MessageController::class, 'index']);
        Route::post('tickets/{ticket}/messages', [V1\MessageController::class, 'store']);
        Route::post('tickets/{ticket}/read', [V1\MessageController::class, 'read']);

        Route::get('tickets/{ticket}/attachments', [V1\AttachmentController::class, 'index']);
        Route::post('tickets/{ticket}/attachments', [V1\AttachmentController::class, 'store'])->middleware('throttle:uploads');
        Route::get('attachments/{attachment}/download', [V1\AttachmentController::class, 'download']);
        Route::delete('attachments/{attachment}', [V1\AttachmentController::class, 'destroy']);

        Route::get('tickets/{ticket}/work-logs', [V1\WorkLogController::class, 'index']);
        Route::post('tickets/{ticket}/work-logs', [V1\WorkLogController::class, 'store']);
        Route::get('work-logs', [V1\WorkLogController::class, 'activity']);
        Route::patch('work-logs/{workLog}', [V1\WorkLogController::class, 'update']);
        Route::delete('work-logs/{workLog}', [V1\WorkLogController::class, 'destroy']);
        Route::post('work-logs/{workLog}/confirm', [V1\WorkLogController::class, 'confirm']);

        Route::get('reports/{type}', [V1\ReportController::class, 'show']);

        Route::get('notifications', [V1\NotificationController::class, 'index']);
        Route::post('notifications/read-all', [V1\NotificationController::class, 'markAllRead']);
        Route::post('notifications/{id}/read', [V1\NotificationController::class, 'markRead']);

        Route::get('audit-logs', [V1\AuditLogController::class, 'index']);
    });
});
