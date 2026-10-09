# Architecture

MSPAssist (working name for the CyberCraft IT Support System) lets CyberCraft
staff run IT support for many client organizations, and lets each client's own
users raise and follow tickets for their sites.

```
 ┌────────────────────────── Flutter app (one codebase) ───────────────────────────┐
 │ Android · iOS · Windows · macOS                    │ Web dashboard (static files) │
 │  - bearer token in OS keystore (secure storage)    │  - HttpOnly session cookie   │
 │  - SQLite cache + outbox (offline)                 │  - CSRF via XSRF-TOKEN       │
 │                                                    │  - in-memory cache only      │
 └───────────────▲────────────────────────────────────┴──────────────▲──────────────┘
                 │ HTTPS JSON  /api/v1/*                              │ same origin
 ┌───────────────┴────────────────────────────────────────────────────┴──────────────┐
 │ Laravel 13 API (PHP 8.3) on cPanel shared hosting                                  │
 │  Sanctum auth · Policies + visibility scopes · TicketWorkflow · SlaService          │
 │  Private attachment storage (storage/app/private) · Audit log · Notifications       │
 │  cron → php artisan schedule:run → sla:check, queue:work --stop-when-empty, pruning │
 └───────────────────────────────────────▲─────────────────────────────────────────────┘
                                         │ PDO (only the API talks to the database)
                                 ┌───────┴────────┐
                                 │ MySQL 8 / MariaDB │  authoritative data
                                 └──────────────────┘
```

## Backend (`/backend`)

| Concern | Where |
| --- | --- |
| Routes (versioned) | `routes/api.php` → `/api/v1/...` |
| Roles | `app/Enums/Role.php` (admin, support_manager, technician, client_admin, client_user) |
| Visibility | `Ticket::scopeVisibleTo`, `User::accessibleSiteIds`, `app/Policies/*` |
| Ticket state machine | `app/Enums/TicketStatus.php`, `app/Services/TicketWorkflow.php` |
| SLA maths | `app/Services/BusinessCalendar.php`, `SlaService.php` |
| Escalation (cron) | `app/Services/SlaMonitor.php`, `routes/console.php` (`sla:check`) |
| Reports | `app/Services/Reports/ReportService.php`, `ReportController` (JSON/CSV/PDF) |
| Audit trail | `app/Services/AuditLogger.php` → `audit_logs` |
| Web app hosting | `routes/web.php` serves `public/app/index.html` for client-side routes |

Key design decisions:

- **One API for every client.** Native apps authenticate with Sanctum
  personal access tokens (30-day expiry, revoked on logout/password change).
  The browser uses Sanctum's SPA mode: `GET /sanctum/csrf-cookie`, then
  `POST /api/v1/auth/login` creates an HttpOnly, encrypted session cookie; the
  `X-XSRF-TOKEN` header protects every state-changing request. No token is
  ever stored in browser storage.
- **Server-side authorization.** Policies and the `visibleTo` scope enforce
  organization and site boundaries on every query, download and poll. Records
  outside the caller's scope return 404.
- **Optimistic concurrency.** `tickets.version` increments on every user-visible
  change; mutations require the client's `version` and return 409
  `version_conflict` with the current ticket when it is stale. System
  bookkeeping (SLA flags, first-response timestamps) does not bump the version.
- **Idempotent creates.** Tickets, messages, work logs and attachments carry a
  client-generated UUID with a unique index. Retries return the original record.
- **Shared-hosting friendly.** No daemons: mail is sent inline (`QUEUE_CONNECTION=sync`)
  or by `queue:work --stop-when-empty` from the scheduler; SLA checks run every
  5 minutes from cron; cache/session use the database.
- **Human-readable ticket numbers** (`CC-2026-000123`) come from a locked
  yearly counter table, so they are unique and gap-free per year.

## Flutter app (`/apps/flutter_app`)

```
lib/
  main.dart                    path URL strategy, bootstraps AppServices
  src/app.dart                 MaterialApp.router, routes, auth redirects
  src/core/                    config, ApiClient, AuthController, TokenStore, platform helpers
  src/data/                    LocalStore (SQLite | memory), Repository (API + cache)
  src/sync/sync_service.dart   outbox replay, backoff, conflict/failure states
  src/models/                  thin typed wrappers over API JSON
  src/ui/                      responsive shell, shared widgets, generic form dialog
  src/features/<area>/         screens: auth, dashboard, tickets, clients, users, reports,
                               settings, notifications, profile, outbox
```

- **Responsive layout:** phones get a navigation drawer and tabbed ticket view;
  tablets a navigation rail; desktops an extended rail and a two-pane ticket
  view (details/work/history beside the live conversation).
- **Storage abstraction:** `LocalStore` has a SQLite implementation
  (`sqflite` on Android/iOS/macOS, `sqflite_common_ffi` on Windows/Linux) and an
  in-memory implementation for the browser. The factory is selected with a
  conditional import so web builds never reference `dart:ffi`/SQLite.
- **Offline:** see [offline-sync.md](offline-sync.md).
- **Chat:** history is cursor-paginated (`before_id`), new messages are polled
  every 5 s with `after_id` while the conversation is visible; failures back
  off exponentially to 60 s; polling stops when the app is backgrounded.

## Known limitations (first version)

- Real-time push (WebSockets/FCM) is not used; chat relies on polling, and
  notifications appear in-app and by email.
- The web dashboard keeps its cache in memory only: reloading the tab drops
  unsent drafts. Offline work is supported on mobile/desktop.
- Ticket edits other than creation (status, assignment, priority) require a
  connection; they are not queued offline by design (server-authoritative).
- Time zones: timestamps are stored in UTC and shown in the device's local
  time; SLA business hours use the policy's time zone. Per-user display time
  zone is stored but not yet applied in the app.
- Reports cap the period at 400 days and are generated synchronously.
- No voice/video calls or WhatsApp integration (out of scope).
- Android/iOS push notifications, signed release builds and app-store
  packaging are not configured.

## Growing past one server

The path from one cPanel server to several servers, object storage and
real-time chat is in [scaling.md](scaling.md).
