# Scaling beyond cPanel

MSPAssist runs on one cPanel server today. This page says what has to change,
and in what order, when traffic outgrows that server. The code was written so
each step is a configuration change or a small package install, not a rewrite.

## What already keeps the door open

| Decision | Why it matters later |
| --- | --- |
| Only the Laravel API talks to the database; every client uses `/api/v1` | Servers can be added or swapped behind the API without changing the apps |
| SQL kept portable (MySQL 8 / MariaDB, SQLite in tests) | Moving to a managed MySQL service needs only new `DB_*` values |
| `attachments.disk` and `path` are stored on every attachment row, and downloads go through `Storage::disk($attachment->disk)` | Old files can stay on `local` while new files go to object storage |
| Queue, cache and sessions are behind Laravel drivers (`database` today) | Switching to Redis is an `.env` change |
| No in-memory state between requests; background work runs from `schedule:run` | Several web servers can run the same code |
| Optimistic `version` checks and row locks (`lockForUpdate`) for ticket changes and ticket numbers | Correct with more than one web server |
| `TRUSTED_PROXIES` is read from the environment | A load balancer or Cloudflare can sit in front |

## Signs it is time to move

- PHP-FPM / LiteSpeed workers are often all busy, or p95 API latency is above about 500 ms.
- The `sessions`, `cache` or `jobs` tables are among the busiest in MySQL.
- `schedule:run` tasks overlap, or queued mail is minutes late.
- Attachments use a large share of the server's disk or backups take too long.
- Chat polling (every 5 s per open conversation, `AppConfig.pollInterval`)
  dominates request logs. 200 open conversations is about 40 requests a second
  before anyone does real work.

## Stage 1: same server, more out of it

You have a cPanel **VPS** (with WHM/root), not shared hosting, so this stage
costs nothing extra.

1. PHP 8.3 with OPcache on, PHP-FPM pool sized to the RAM; `php artisan optimize` on every deploy.
2. Install Redis on the VPS and set `CACHE_STORE=redis`, `SESSION_DRIVER=redis`,
   `QUEUE_CONNECTION=redis` (`REDIS_CLIENT=phpredis` if the extension is
   installed, otherwise `composer require predis/predis` and `REDIS_CLIENT=predis`).
3. Run a real queue worker under systemd or Supervisor
   (`php artisan queue:work --tries=3 --max-time=3600`) and drop the
   `queue:work --stop-when-empty` line from `routes/console.php`.
4. Put Cloudflare (or similar) in front for TLS, caching of `/app` static files and DDoS protection;
   set `TRUSTED_PROXIES` accordingly.

Keep the `database` drivers working: they are what a fresh cPanel install uses.

## Stage 2: split storage and database off the web server

1. **Attachments to object storage** (Backblaze B2, Cloudflare R2, Wasabi,
   DigitalOcean Spaces or AWS S3):
   `composer require league/flysystem-aws-s3-v3`, fill in the `AWS_*` values,
   set `MSPASSIST_ATTACHMENT_DISK=s3`. The bucket must be private; downloads
   still go through `AttachmentController::download`. Existing rows keep
   `disk = local` and keep working; copy them across later and update the
   `disk` column if you want to free the server's disk.
2. **Database on its own server** or a managed MySQL 8 service, with daily
   snapshots and point-in-time recovery. Change `DB_HOST`.
3. Mail through a transactional provider (SES, Postmark, Mailgun) instead of
   the cPanel mailbox when volume grows.

## Stage 3: more than one web server

Requires Stage 2 (no files on local disk) and Redis (shared sessions, cache and locks).

1. Two or more identical app servers behind a load balancer. Build the Flutter
   web app once in CI and deploy the same release to each.
2. Run the scheduler on every server but add `->onOneServer()` to the scheduled
   commands in `routes/console.php`, or run cron on one server only.
3. Queue workers can run on a separate small server.
4. Read replicas only when reports become heavy: point report queries at a
   read connection; keep ticket writes on the primary.

## Stage 4: real-time instead of polling

Replace the 5-second chat poll, and the in-app notification list that only refreshes when opened, with:

- **WebSockets** through Laravel Reverb (self-hosted) or a hosted service
  (Pusher, Ably). Authorize private channels with the same `TicketPolicy::view`
  check so client roles never receive internal notes.
- **Push notifications** with FCM (Android, web) and APNs (iOS).

Keep polling as the fallback for networks that block WebSockets.

## What not to do early

- Microservices, Kubernetes or a rewrite in another stack. One Laravel API on
  a few servers carries a support desk with thousands of client users.
- Moving the database to Firebase/Supabase. The authorization rules depend on
  SQL scopes and policies in Laravel.
