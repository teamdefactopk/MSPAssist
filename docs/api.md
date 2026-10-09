# REST API (v1)

Base URL: `https://<your-domain>/api/v1/`. JSON in and out (`Accept: application/json`).
Collections return `{ "data": [...], "meta": {...} }`; single records `{ "data": {...} }`.

## Authentication

| Client | Flow |
| --- | --- |
| Mobile / desktop | `POST /auth/token {email, password, device_name}` → `{token, expires_at, user}`. Send `Authorization: Bearer <token>`. |
| Web dashboard (same origin) | `GET /sanctum/csrf-cookie`, then `POST /auth/login {email, password}`. Session cookie is HttpOnly; send `X-XSRF-TOKEN` (value of the `XSRF-TOKEN` cookie) on POST/PATCH/PUT/DELETE. |

`/auth/login`, `/auth/token`, password reset and invitation endpoints are rate limited (10/min/IP);
failed logins are additionally limited to 5/min per email+IP (HTTP 429). Authenticated routes: 240/min/user;
uploads 30/min/user. Deactivated accounts get `403 {code: "account_inactive"}`.

## Errors

| Status | Body | Meaning |
| --- | --- | --- |
| 401 | `{message}` | Not authenticated / token expired |
| 403 | `{message}` | Authenticated but not allowed |
| 404 | `{message}` | Not found **or outside your organization/site scope** |
| 409 | `{message, code}` | `version_conflict` (+ `current` ticket), `invalid_transition`, `ticket_closed`, `duplicate_uuid`, `already_confirmed`, `has_tickets` |
| 422 | `{message, errors: {field: [..]}}` or `{message, code}` | Validation; `resolution_notes_required`, `invalid_assignee`, `reopen_window_expired` |
| 429 | `{message}` | Rate limited |

## Endpoints

### Auth & profile
| Method | Path | Notes |
| --- | --- | --- |
| POST | `/auth/token` | Native login |
| POST | `/auth/login` | Browser session login |
| POST | `/auth/logout` | Revokes current token / ends session |
| POST | `/auth/forgot-password` | `{email}` — always 200 (no account enumeration) |
| POST | `/auth/reset-password` | `{token, email, password, password_confirmation}` — revokes all tokens |
| GET | `/me` | Profile + `abilities` map for UI |
| PATCH | `/me` | `name, phone, job_title, timezone` |
| PUT | `/me/password` | `current_password, password, password_confirmation` — revokes other tokens |

### Invitations & users (no public registration)
| Method | Path | Notes |
| --- | --- | --- |
| GET | `/invitations` | Managers: all; client admins: own org |
| POST | `/invitations` | `{email, name, role, organization_id?, site_ids?}` — emails a 64-char token link (72 h) |
| DELETE | `/invitations/{id}` | Revoke pending invitation |
| GET | `/invitations/{token}` | Public: preview |
| POST | `/invitations/accept` | Public: `{token, name, password, password_confirmation}` |
| GET | `/users` | Filters: `organization_id, role, staff, assignable, search` |
| GET/PATCH | `/users/{id}` | `name, role, is_active, phone, job_title, site_ids` (deactivation revokes tokens) |

### Clients
| Method | Path |
| --- | --- |
| GET/POST | `/organizations` (filters `search`, `active`) |
| GET/PATCH/DELETE | `/organizations/{id}` (delete only without tickets, admin) |
| GET/POST | `/organizations/{id}/sites` · PATCH/DELETE `/sites/{id}` |
| GET/POST | `/organizations/{id}/departments` · PATCH/DELETE `/departments/{id}` |
| GET/POST | `/organizations/{id}/contacts` · PATCH/DELETE `/contacts/{id}` |
| GET/POST | `/organizations/{id}/equipment` (filter `site_id`) · PATCH/DELETE `/equipment/{id}` |

### Tickets
| Method | Path | Body / query |
| --- | --- | --- |
| GET | `/tickets` | `status` (csv), `state=active|inactive`, `priority`, `organization_id`, `site_id`, `category_id`, `assigned_to=me|none|<id>`, `mine`, `overdue`, `from`, `to`, `updated_since`, `search`, `sort=updated|created|priority|due`, `page`, `per_page` — each item includes `unread_count`; `meta.server_time` |
| POST | `/tickets` | `uuid`, `organization_id`, `site_id`, `subject`, `description`, `priority?`, `category_id?`, `department_id?`, `equipment_id?`, `contact_id?`, `source?`, `assigned_to?` (managers). 201 created / 200 replay |
| GET | `/tickets/{id}` | |
| PATCH | `/tickets/{id}` | `version` + `subject, description, priority, category_id, department_id, equipment_id, contact_id` |
| POST | `/tickets/{id}/assign` | `{assigned_to: id|null, version}` |
| POST | `/tickets/{id}/status` | `{status, version, note?, resolution_notes?}` |
| POST | `/tickets/{id}/reopen` | `{reason, version}` |
| GET | `/tickets/{id}/history` | Events (internal ones hidden from clients) |

Status transitions (staff; clients may only close a resolved ticket):

```
open/assigned → in_progress | waiting_client | waiting_vendor | resolved* | closed
in_progress   → waiting_client | waiting_vendor | resolved*
waiting_*     → in_progress | other waiting | resolved*
resolved      → closed            (* resolved requires resolution_notes)
resolved/closed → reopen → assigned (if technician) or open
assign on open → assigned ; unassign on assigned → open
client reply while waiting_client → in_progress (configurable)
logging work on open/assigned → in_progress
```

### Conversation
| Method | Path | Notes |
| --- | --- | --- |
| GET | `/tickets/{id}/messages` | `after_id` (polling, ascending) or `before_id` (older page); `limit` ≤ 100. `meta`: `has_more, unread_count, last_read_message_id, ticket_version, ticket_status` |
| POST | `/tickets/{id}/messages` | `{uuid, body, is_internal?, attachment_uuids?}` — 201 new, 200 replay, 409 `ticket_closed` |
| POST | `/tickets/{id}/read` | `{last_message_id}` (never moves backwards) |

### Attachments
| Method | Path | Notes |
| --- | --- | --- |
| POST | `/tickets/{id}/attachments` | multipart: `uuid, file, is_internal?, work_log_uuid?`. Allowed: jpg, jpeg, png, gif, webp, heic, pdf, txt, log, csv, doc(x), xls(x), ppt(x), zip; max 10 MB (configurable). Content is sniffed; PHP/executables rejected. |
| GET | `/tickets/{id}/attachments` | Linked attachments visible to caller |
| GET | `/attachments/{id}/download` | Authorized on every call; `?inline=1` for safe images; `nosniff`, sandbox CSP |
| DELETE | `/attachments/{id}` | Own unlinked upload or managers |

### Work
| Method | Path | Notes |
| --- | --- | --- |
| GET/POST | `/tickets/{id}/work-logs` | `{uuid, type, started_at, ended_at?, minutes?, description, client_confirmation_name?}` |
| GET | `/work-logs` | Technician activity (`from, to, user_id` for managers) |
| PATCH/DELETE | `/work-logs/{id}` | Author or manager, not after confirmation |
| POST | `/work-logs/{id}/confirm` | Client users confirm completed work `{note?}` |

### Dashboard, reports, reference data
| Method | Path | Notes |
| --- | --- | --- |
| GET | `/dashboard` | `organization_id, site_id, from, to` → counts, by status/priority/client/site, technician workload, recent activity |
| GET | `/reports/{type}` | `type`: `ticket-history`, `technician-activity`, `sla-performance`, `client-monthly`; `format=json|csv|pdf`, `from/to` or `month=YYYY-MM`, `organization_id`, `site_id`, `user_id` |
| GET | `/lookups` | statuses (+transitions), priorities, roles, categories, accessible orgs/sites, technicians, upload limits |
| GET/POST/PATCH | `/categories`, `/sla-policies` | Managers |
| GET | `/notifications` · POST `/notifications/{id}/read` · POST `/notifications/read-all` | |
| GET | `/audit-logs` | Administrators |
| GET | `/health` | Public liveness check |
