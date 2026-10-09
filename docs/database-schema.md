# Database schema (MySQL 8 / MariaDB 10.6+)

Migrations live in `backend/database/migrations`. All timestamps are stored in
UTC. IDs are `BIGINT UNSIGNED AUTO_INCREMENT`; records that clients may create
offline also carry a `uuid` (client-generated, unique) for idempotency.

## Identity and access

**users** — `id, name, email (unique), password (bcrypt), role, organization_id → organizations (null for staff),
phone, job_title, timezone, is_active, last_login_at, invited_by → users, email_verified_at, remember_token, timestamps`

- `role`: `admin | support_manager | technician | client_admin | client_user`
- Client roles must have `organization_id`; staff have `NULL`.

**site_user** — `site_id, user_id` (PK both). Sites a `client_user` may access.
Client administrators implicitly access all sites of their organization.

**invitations** — `id, email, name, role, organization_id, site_ids (JSON), token_hash (SHA-256, unique), invited_by,
expires_at, accepted_at, revoked_at, timestamps`. The plain token only exists in the e-mailed link.

**password_reset_tokens**, **sessions**, **personal_access_tokens** — Laravel/Sanctum standard tables.

**audit_logs** — `id, user_id, action, subject_type, subject_id, organization_id, ip_address, user_agent, data (JSON), created_at`.
Actions include `auth.login`, `auth.login_failed`, `auth.password_reset`, `invitation.*`, `user.updated`,
`organization.*`, `site.*`, `ticket.*`, `attachment.uploaded/deleted`, `work_log.*`, `report.generated`.

## Clients

**organizations** — `id, name, code (unique), email, phone, address, timezone, sla_policy_id → sla_policies, is_active, notes, timestamps`

**sites** — `id, organization_id, name, code, address, city, phone, timezone, is_active, timestamps`

**departments** — `id, organization_id, site_id (nullable = all sites), name, timestamps`

**contacts** — `id, organization_id, site_id, department_id, user_id, name, email, phone, job_title, is_primary, timestamps`

**equipment** — `id, organization_id, site_id, department_id, name, type, manufacturer, model, serial_number, asset_tag,
purchase_date, warranty_expires_at, status (active|in_repair|retired), notes, timestamps`

## SLA

**sla_policies** — `id, name, is_default, timezone, business_hours (JSON or NULL = 24x7), holidays (JSON dates),
pause_statuses (JSON, subset of waiting_client|waiting_vendor), warning_percent, timestamps`

`business_hours` example: `{"mon":[["09:00","18:00"]],"tue":[["09:00","13:00"],["14:00","18:00"]],"sat":[],"sun":[]}`

**sla_targets** — `id, sla_policy_id, priority (low|medium|high|critical), response_minutes, resolution_minutes` (unique policy+priority).
Minutes are *business* minutes under the policy's calendar.

## Tickets

**categories** — `id, name (unique), is_active`

**ticket_sequences** — `year (PK), last_number`. Locked row used to generate `CC-YYYY-NNNNNN`.

**tickets**

| Column | Notes |
| --- | --- |
| `uuid` | client-generated, unique (idempotent create) |
| `number` | unique human number |
| `organization_id, site_id` | required; site must belong to the organization |
| `department_id, equipment_id, category_id, contact_id` | optional, validated to belong to the organization |
| `requester_id` | creating user |
| `assigned_to` | staff user or NULL |
| `subject, description, priority, status, source` | status: `open, assigned, in_progress, waiting_client, waiting_vendor, resolved, closed` |
| `resolution_notes, reopen_count` | |
| `version` | optimistic concurrency counter |
| `sla_policy_id, first_response_due_at, resolution_due_at, first_responded_at` | SLA targets |
| `sla_paused_at, sla_paused_minutes` | pause accounting (business minutes) |
| `response_breached_at, resolution_warned_at, resolution_breached_at, escalation_level` | set once by the monitor |
| `resolved_at, closed_at, last_activity_at, created_at, updated_at` | |

Indexes: `(organization_id, site_id, status)`, `(assigned_to, status)`, `status`, `priority`, `updated_at`.

**ticket_events** — `id, ticket_id, user_id (NULL = system), type, field, from_value, to_value, note, is_internal, created_at`.
Full change history: `created, assigned, unassigned, status_changed, reopened, priority_changed, updated, work_logged,
work_confirmed, sla_response_breached, sla_resolution_warning, sla_resolution_breached, sla_escalated` (SLA events are internal).

**ticket_messages** — `id, uuid (unique), ticket_id, user_id, body, is_internal, timestamps`. Index `(ticket_id, is_internal, id)`.

**ticket_reads** — `ticket_id, user_id (PK), last_read_message_id, updated_at`. Unread count = visible messages from
others with `id > last_read_message_id`.

**work_logs** — `id, uuid (unique), ticket_id, user_id, type (remote|onsite|phone|workshop), started_at, ended_at, minutes,
description, client_confirmation_name (onsite sign-off), client_confirmed_by → users, client_confirmed_at, client_confirmation_note, timestamps`

**attachments** — `id, uuid (unique), ticket_id, message_id, work_log_id, uploaded_by, disk, path, original_name, mime_type
(sniffed), size, sha256, is_internal, timestamps`. Files live on the private disk at `attachments/{ticket_id}/{uuid}`.

## Framework tables

`cache`, `cache_locks`, `jobs`, `job_batches`, `failed_jobs`, `notifications` (database notifications: assignment,
resolution, new messages, SLA alerts).

## Entity relationships

```
organizations 1─* sites 1─* departments
      │            │
      │            *─* users (client_user site access)
      ├─* contacts, equipment, users (client roles)
      └─* tickets *─1 sites, *─1 users (requester / assignee)
              ├─* ticket_events
              ├─* ticket_messages ─* attachments
              ├─* work_logs ─* attachments (photos)
              └─* ticket_reads
sla_policies 1─* sla_targets ; organizations *─1 sla_policies ; tickets *─1 sla_policies
```
