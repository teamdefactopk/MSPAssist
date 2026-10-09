<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('categories', function (Blueprint $table) {
            $table->id();
            $table->string('name', 120)->unique();
            $table->boolean('is_active')->default(true);
            $table->timestamps();
        });

        // Gap-free yearly counter used to build human-readable ticket numbers.
        Schema::create('ticket_sequences', function (Blueprint $table) {
            $table->unsignedSmallInteger('year')->primary();
            $table->unsignedInteger('last_number')->default(0);
        });

        Schema::create('tickets', function (Blueprint $table) {
            $table->id();
            // Client-generated stable id (UUID) used for offline idempotency.
            $table->uuid('uuid')->unique();
            $table->string('number', 30)->unique();
            $table->foreignId('organization_id')->constrained();
            $table->foreignId('site_id')->constrained();
            $table->foreignId('department_id')->nullable()->constrained()->nullOnDelete();
            $table->foreignId('equipment_id')->nullable()->constrained('equipment')->nullOnDelete();
            $table->foreignId('category_id')->nullable()->constrained()->nullOnDelete();
            $table->foreignId('requester_id')->constrained('users');
            $table->foreignId('contact_id')->nullable()->constrained()->nullOnDelete();
            $table->foreignId('assigned_to')->nullable()->constrained('users')->nullOnDelete();
            $table->string('subject', 200);
            $table->text('description');
            $table->string('priority', 16)->index();
            $table->string('status', 24)->index();
            $table->string('source', 16)->default('web');
            $table->text('resolution_notes')->nullable();
            $table->unsignedInteger('reopen_count')->default(0);
            // Optimistic-concurrency version; incremented on every change.
            $table->unsignedInteger('version')->default(1);

            // SLA tracking
            $table->foreignId('sla_policy_id')->nullable()->constrained()->nullOnDelete();
            $table->timestamp('first_response_due_at')->nullable();
            $table->timestamp('resolution_due_at')->nullable();
            $table->timestamp('first_responded_at')->nullable();
            $table->timestamp('sla_paused_at')->nullable();
            $table->unsignedInteger('sla_paused_minutes')->default(0);
            $table->timestamp('response_breached_at')->nullable();
            $table->timestamp('resolution_breached_at')->nullable();
            $table->timestamp('resolution_warned_at')->nullable();
            $table->unsignedTinyInteger('escalation_level')->default(0);

            $table->timestamp('resolved_at')->nullable();
            $table->timestamp('closed_at')->nullable();
            $table->timestamp('last_activity_at')->nullable();
            $table->timestamps();

            $table->index(['organization_id', 'site_id', 'status']);
            $table->index(['assigned_to', 'status']);
            $table->index('updated_at');
        });

        Schema::create('ticket_events', function (Blueprint $table) {
            $table->id();
            $table->foreignId('ticket_id')->constrained()->cascadeOnDelete();
            $table->foreignId('user_id')->nullable()->constrained()->nullOnDelete();
            $table->string('type', 40);
            $table->string('field', 40)->nullable();
            $table->string('from_value', 255)->nullable();
            $table->string('to_value', 255)->nullable();
            $table->text('note')->nullable();
            // Staff-only events (internal notes) are hidden from client users.
            $table->boolean('is_internal')->default(false);
            $table->timestamp('created_at')->nullable();
            $table->index(['ticket_id', 'id']);
        });

        Schema::create('ticket_messages', function (Blueprint $table) {
            $table->id();
            $table->uuid('uuid')->unique();
            $table->foreignId('ticket_id')->constrained()->cascadeOnDelete();
            $table->foreignId('user_id')->constrained();
            $table->text('body');
            $table->boolean('is_internal')->default(false);
            $table->timestamps();
            $table->index(['ticket_id', 'is_internal', 'id']);
        });

        Schema::create('ticket_reads', function (Blueprint $table) {
            $table->foreignId('ticket_id')->constrained()->cascadeOnDelete();
            $table->foreignId('user_id')->constrained()->cascadeOnDelete();
            $table->unsignedBigInteger('last_read_message_id')->default(0);
            $table->timestamp('updated_at')->nullable();
            $table->primary(['ticket_id', 'user_id']);
        });

        Schema::create('work_logs', function (Blueprint $table) {
            $table->id();
            $table->uuid('uuid')->unique();
            $table->foreignId('ticket_id')->constrained()->cascadeOnDelete();
            $table->foreignId('user_id')->constrained();
            // remote | onsite | phone | workshop
            $table->string('type', 16);
            $table->timestamp('started_at');
            $table->timestamp('ended_at')->nullable();
            $table->unsignedInteger('minutes');
            $table->text('description');
            $table->string('client_confirmation_name', 160)->nullable();
            $table->foreignId('client_confirmed_by')->nullable()->constrained('users')->nullOnDelete();
            $table->timestamp('client_confirmed_at')->nullable();
            $table->text('client_confirmation_note')->nullable();
            $table->timestamps();
            $table->index(['user_id', 'started_at']);
        });

        Schema::create('attachments', function (Blueprint $table) {
            $table->id();
            $table->uuid('uuid')->unique();
            $table->foreignId('ticket_id')->constrained()->cascadeOnDelete();
            $table->foreignId('message_id')->nullable()->constrained('ticket_messages')->nullOnDelete();
            $table->foreignId('work_log_id')->nullable()->constrained()->nullOnDelete();
            $table->foreignId('uploaded_by')->constrained('users');
            $table->string('disk', 30);
            $table->string('path', 255);
            $table->string('original_name', 255);
            $table->string('mime_type', 120);
            $table->unsignedBigInteger('size');
            $table->string('sha256', 64);
            $table->boolean('is_internal')->default(false);
            $table->timestamps();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('attachments');
        Schema::dropIfExists('work_logs');
        Schema::dropIfExists('ticket_reads');
        Schema::dropIfExists('ticket_messages');
        Schema::dropIfExists('ticket_events');
        Schema::dropIfExists('tickets');
        Schema::dropIfExists('ticket_sequences');
        Schema::dropIfExists('categories');
    }
};
