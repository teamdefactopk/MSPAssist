# AGENTS.md — guidance for contributors and coding agents

MSPAssist is CyberCraft's IT support system: a Laravel REST API (`/backend`)
and one Flutter app (`/apps/flutter_app`) that targets Android, iOS, Windows,
macOS and the web dashboard. Read `docs/architecture.md` first.

## Repository layout

| Path | What lives there |
| --- | --- |
| `backend/` | Laravel 13 API (`/api/v1`), MySQL schema, scheduler, tests |
| `apps/flutter_app/` | Flutter client (all platforms) |
| `docs/` | Architecture, schema, API, setup, offline sync, permissions, cPanel deployment |
| `scripts/` | Helper scripts (e.g. `build_web.sh`) |
| `.github/workflows/` | CI (backend + Flutter + Android) and manual desktop/iOS builds |

## Non-negotiable rules

1. **Authorization is enforced in the backend.** Every ticket query that is
   driven by user input must go through `Ticket::scopeVisibleTo()` or
   `TicketPolicy::view`. Organization/site boundaries come from
   `User::accessibleSiteIds()` / `canAccessOrganization()`. Hiding a button in
   Flutter is never a security control.
2. **Out-of-scope records return 404**, not 403, so IDs of other clients'
   records are not confirmed.
3. **Internal notes and internal attachments never reach client roles.**
   Filter on `is_internal` for clients in every list, poll, unread count,
   history and download path. Tests in `tests/Feature/MessageTest.php` and
   `AttachmentTest.php` must keep passing.
4. **All ticket state changes go through `App\Services\TicketWorkflow`** so
   history (`ticket_events`), SLA accounting, optimistic `version` checks and
   audit logs stay consistent. Do not update `tickets.status` directly.
5. **Client-created records are idempotent on a client UUID** (`uuid` on
   tickets, messages, work logs, attachments). Replays by the same user return
   the existing record (HTTP 200); reuse by another user is a 409.
6. **Server is authoritative.** The Flutter outbox may only queue *creates*
   (tickets, messages, work logs, files). Status, assignment and edits are
   online-only and use the `version` field; a 409 `version_conflict` must be
   shown to the user, never silently retried with the new version.
7. **Never mark a queued item as delivered** in the UI until the server
   responds with the created record.
8. **Attachments are private.** Store on the `local` (private) disk under a
   random name with no extension; serve only through
   `AttachmentController::download` with authorization on every request.
9. **No secrets in Git.** Only `.env.example` with placeholders. Demo data in
   `DemoSeeder` must stay fictional (`*.example` domains) and must not run in
   production.
10. Production constraints: standard cPanel shared hosting — no Docker, Redis,
    Supabase/Firebase DB or long-running Node/queue workers. Background work
    runs from `php artisan schedule:run` via cron.

## Commands

Backend (from `backend/`):

```bash
composer install
cp .env.example .env && php artisan key:generate   # then edit DB settings
php artisan migrate --seed                           # reference data only
php artisan db:seed --class=DemoSeeder               # fictional demo data (dev only)
php artisan serve                                    # http://127.0.0.1:8000
php artisan test                                     # all backend tests
vendor/bin/pint                                      # format (CI runs pint --test)
php artisan sla:check                                # run the SLA monitor once
```

Flutter (from `apps/flutter_app/`):

```bash
flutter pub get
flutter analyze
flutter test
dart format lib test                                  # page width 160 (analysis_options.yaml)
flutter run -d chrome --web-port 5173                 # needs API_BASE_URL + CORS/stateful setup, see docs/setup.md
flutter run -d windows|macos|<device> --dart-define=API_BASE_URL=http://127.0.0.1:8000/api/v1
../../scripts/build_web.sh                            # build web into backend/public/app
```

## Conventions

- PHP: Laravel defaults, Pint formatting, string-backed enums in `app/Enums`,
  validation in controllers via `$request->validate()`, JSON resources in
  `app/Http/Resources`. Use `Gate::authorize()` with the policies in
  `app/Policies`. Keep SQL portable between MySQL 8/MariaDB and SQLite (tests).
- Every new endpoint needs a feature test, including a cross-client denial
  case when it touches client data.
- Flutter: `provider` for app-wide services, `go_router` for navigation,
  plain `StatefulWidget`s per screen. Data access goes through
  `Repository` (reads with offline cache) or `SyncService` (queued creates).
  Platform-specific code lives behind conditional imports in
  `lib/src/core/platform/` and `lib/src/data/local_store_factory*.dart`;
  never import `dart:io`, `sqflite` or `dart:ffi` from code compiled for web.
- Do not add placeholder buttons for unfinished features. If something is not
  implemented, leave it out and document it in `docs/architecture.md`
  ("Known limitations").
- Update `docs/api.md` and `docs/database-schema.md` when you change routes or
  migrations.
