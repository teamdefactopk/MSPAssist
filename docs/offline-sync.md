# Offline behaviour and synchronization

## Goals

- Technicians and client users can keep working on mobile/desktop without a
  connection: read cached tickets, write ticket drafts, chat messages and work
  logs (with photos).
- Nothing is silently lost, duplicated or overwritten.
- The server remains authoritative for permissions, assignment and status.

## Storage

| Platform | Cache / outbox | Credentials |
| --- | --- | --- |
| Android, iOS, macOS | SQLite via `sqflite` (app support dir, one file per account) | `flutter_secure_storage` (Keychain / Android Keystore) |
| Windows (and Linux) | SQLite via `sqflite_common_ffi` (bundled sqlite3) | Windows Credential Manager via `flutter_secure_storage` |
| Web | In-memory `MemoryLocalStore` (lost on reload) | HttpOnly session cookie (no JS-readable token) |

Native SQLite is not used in the browser. The web build selects the in-memory
store through a conditional import; client data is deliberately not written to
`localStorage`/IndexedDB on shared browsers.

The database file is named after the account (`mspassist_<userId>_<host>.db`)
so two accounts on one device never share data.

## What is cached

`me`, `lookups`, dashboard, ticket list results (each ticket under
`ticket:<id>`), ticket detail, the latest page of messages per ticket, work
logs, history, organizations and their sites/departments/contacts/equipment.
Reads try the API first and fall back to the cache on a network error; screens
show an *Offline — showing saved data* banner when the data came from cache.

## The outbox

Only **create** operations are queued:

| Kind | Endpoint | Idempotency key |
| --- | --- | --- |
| `create_ticket` | `POST /tickets` | ticket `uuid` |
| `send_message` | `POST /tickets/{id}/messages` | message `uuid` |
| `create_work_log` | `POST /tickets/{id}/work-logs` | work log `uuid` |
| `upload_attachment` | `POST /tickets/{id}/attachments` | attachment `uuid` |

Each item stores the payload, status, attempt count, last error and the next
retry time. Files are copied into app-private storage until uploaded.

Dependencies are explicit: a message or work log for a ticket created offline
waits for that ticket (`ticket_uuid`); photos wait for their work log
(`work_log_uuid`); a message with attachments waits for its uploads
(`depends_on`). When the ticket is created the server id is recorded under
`ticketmap:<uuid>` and later items use it.

### States shown to the user

| State | Meaning | UI |
| --- | --- | --- |
| `pending` | Waiting to send (offline, or retrying after a transient error) | orange *Pending sync* / *Not delivered yet* |
| `syncing` | Request in flight | blue *Sending…* |
| `failed` | Server rejected it (validation, permission) | red *Failed* + error, Retry / Discard |
| `conflict` | Server state no longer allows it (e.g. ticket closed) | purple *Conflict* + explanation, Retry / Discard |
| synced | Server returned the created record | item leaves the outbox and appears as a normal record (*Synced*) |

Queued chat messages are rendered separately from delivered ones and are
labelled *Not delivered yet* — they are never shown as sent until the API has
returned the stored message.

### Replay algorithm (`SyncService`)

1. Triggered on enqueue, every 30 s, on app resume and by *Sync now*.
2. Items are processed oldest first. Items whose dependency is still queued
   are skipped; failed/conflicted items block their dependents.
3. Transient errors (no connection, timeout, 5xx, 429) keep the item `pending`
   with exponential backoff (5 s, 10 s, 20 s … max 10 min) and stop the pass
   when the device is offline.
4. 409 → `conflict`; other 4xx → `failed`. Nothing is retried automatically
   after a permanent error.
5. Because every request carries the same UUID, a retry after a lost response
   returns the already-created record (HTTP 200) instead of creating a
   duplicate. A UUID used by someone else is rejected (409 `duplicate_uuid`).

## Online-only changes and conflicts

Status changes, assignment, priority edits, reopening, resolution and
work-log confirmation are sent immediately and require a connection. Each
carries the ticket `version` the user was looking at. If someone else changed
the ticket first, the API answers `409 version_conflict` with the current
ticket and the app shows a dialog comparing the old and new status, assignee
and priority, offering **Apply my change** (re-send against the new version)
or **Discard my change**. Changes are never silently overwritten.

Background SLA bookkeeping does not bump the version, so it never causes
conflicts.

## Logout and session expiry

- **Logout** revokes the token/session on the server (best effort when
  offline), deletes the account's SQLite database, queued files and stored
  credentials. If items are still queued the user is warned first.
- **Expired/revoked token (401)** signs the user out but keeps the local
  database so the same user can sign back in and finish syncing. A different
  user signing in gets a different database file.

## Chat polling

While a conversation is visible the app polls
`GET /tickets/{id}/messages?after_id=<last>` every 5 seconds. Errors double the
interval up to 60 seconds; success resets it. Polling pauses when the app is
backgrounded and resumes immediately on return. The poll response includes
`ticket_version`, so the ticket header refreshes when someone else changes it.
