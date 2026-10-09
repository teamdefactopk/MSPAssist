# Deploying to cPanel shared hosting

This guide deploys the Laravel API and the Flutter web dashboard on one
domain (for example `support.example.com`) on standard cPanel hosting with
HTTPS and cron. No Docker, Redis, Node.js process or queue daemon is needed.
Production deployment is always manual; CI never deploys.

## 1. Requirements

- PHP **8.3** or newer (cPanel → *MultiPHP Manager*) with extensions:
  `bcmath, ctype, curl, dom, fileinfo, gd, intl, json, mbstring, openssl,
  pdo_mysql, tokenizer, xml, zip`. (*Select PHP Version* → Extensions.)
- PHP settings (*MultiPHP INI Editor*): `upload_max_filesize = 12M`,
  `post_max_size = 16M`, `memory_limit = 256M`, `max_execution_time = 60`.
- MySQL 8 or MariaDB 10.6+.
- SSH access (recommended) and Composer (`composer` is available on most cPanel
  hosts; otherwise upload a `vendor/` built locally with the same PHP version).
- An SSL certificate for the domain (cPanel *SSL/TLS Status* → AutoSSL).

## 2. Directory layout

Keep the application **outside** `public_html` and expose only Laravel's
`public/` directory:

```
/home/<cpaneluser>/mspassist/            ← backend/ contents (app, config, storage, vendor, .env …)
/home/<cpaneluser>/mspassist/public/     ← document root for support.example.com
/home/<cpaneluser>/mspassist/public/app/ ← Flutter web build
```

In cPanel → *Domains*, create (or edit) `support.example.com` and set its
**Document Root** to `mspassist/public`. If the host forces `public_html`,
point the domain at a subdirectory and symlink it:
`ln -s ~/mspassist/public ~/public_html/support` — never copy `.env` or
`storage/` under `public_html`.

## 3. Database

cPanel → *MySQL® Databases*:

1. Create database `<cpaneluser>_mspassist`.
2. Create user `<cpaneluser>_msp` with a long random password.
3. Add the user to the database with **ALL PRIVILEGES**.

Use `utf8mb4` / `utf8mb4_unicode_ci` (default on current cPanel).

## 4. Upload the backend

From your workstation (or CI artifact), on a tagged release:

```bash
git clone <repo> && cd <repo>/backend
composer install --no-dev --optimize-autoloader
```

Upload the contents of `backend/` to `~/mspassist/` (SFTP/rsync), excluding
`.env`, `storage/logs/*`, `tests/`. Alternatively `git clone` on the server and
run `composer install --no-dev --optimize-autoloader` there.

## 5. Environment variables

Create `~/mspassist/.env` from `.env.example` **on the server** (never commit it):

```dotenv
APP_NAME="MSPAssist"
APP_ENV=production
APP_DEBUG=false
APP_URL=https://support.example.com
APP_KEY=                       # php artisan key:generate --force

LOG_STACK=daily
LOG_LEVEL=warning

DB_CONNECTION=mysql
DB_HOST=localhost
DB_PORT=3306
DB_DATABASE=<cpaneluser>_mspassist
DB_USERNAME=<cpaneluser>_msp
DB_PASSWORD=<strong password>

SESSION_DRIVER=database
SESSION_ENCRYPT=true
SESSION_SECURE_COOKIE=true
SESSION_SAME_SITE=lax
SESSION_DOMAIN=support.example.com
SANCTUM_STATEFUL_DOMAINS=support.example.com
SANCTUM_TOKEN_DAYS=30
CORS_ALLOWED_ORIGINS=
TRUSTED_PROXIES=*              # only if the host terminates TLS in a proxy; otherwise 127.0.0.1

CACHE_STORE=database
QUEUE_CONNECTION=database      # mail is sent by the cron-driven worker; "sync" also works
FILESYSTEM_DISK=local

MAIL_MAILER=smtp
MAIL_SCHEME=smtps
MAIL_HOST=mail.example.com
MAIL_PORT=465
MAIL_USERNAME=support@example.com
MAIL_PASSWORD=<mailbox password>
MAIL_FROM_ADDRESS=support@example.com
MAIL_FROM_NAME="CyberCraft Support"

MSPASSIST_FRONTEND_URL=https://support.example.com/app
MSPASSIST_TICKET_PREFIX=CC
MSPASSIST_DEFAULT_TIMEZONE=Asia/Karachi
MSPASSIST_ATTACHMENT_MAX_KB=10240
```

Then, over SSH in `~/mspassist`:

```bash
php artisan key:generate --force
chmod 600 .env
```

## 6. Migrations and first administrator

```bash
php artisan migrate --force
php artisan db:seed --force          # reference data only: categories + default SLA policies
php artisan config:cache
php artisan route:cache
php artisan view:cache
```

Create the first CyberCraft administrator (there is no public registration):

```bash
php artisan mspassist:create-admin you@example.com "Your Name"   # prompts for the password
```

Sign in, change the password under *Profile*, then invite everyone else from
*Users → Invite*. **Do not run `DemoSeeder` in production** (it refuses when
`APP_ENV=production`).

## 7. Storage permissions

```bash
chmod -R 775 storage bootstrap/cache
find storage -type f -exec chmod 664 {} \;
```

Attachments are written to `storage/app/private/attachments/` — outside the
document root, under random names without extensions, and only ever streamed
through the authorized API endpoint. Do **not** run `php artisan storage:link`
for attachments. As defence in depth, Laravel's `storage/` folder already
contains deny rules; you can also add `~/mspassist/storage/.htaccess` with
`Require all denied`.

## 8. Cron (scheduler)

cPanel → *Cron Jobs* → add (every minute):

```
* * * * * cd /home/<cpaneluser>/mspassist && /usr/local/bin/php artisan schedule:run >> /dev/null 2>&1
```

Use the PHP binary matching your MultiPHP version, e.g.
`/opt/cpanel/ea-php83/root/usr/bin/php`. The scheduler runs:

| Task | Frequency |
| --- | --- |
| `sla:check` — SLA warnings, breaches, escalation e-mails | every 5 minutes |
| `queue:work --stop-when-empty --max-time=50` — queued mail | every minute |
| `auth:clear-resets` | every 15 minutes |
| `sanctum:prune-expired --hours=24` | daily |

Verify with `php artisan schedule:list` and by checking `storage/logs`.

## 9. E-mail

Create a mailbox (e.g. `support@example.com`) in cPanel → *Email Accounts* and
use its SMTP settings (port 465 + `MAIL_SCHEME=smtps`, or 587 + STARTTLS).
Add SPF/DKIM (cPanel → *Email Deliverability*) so invitations, password resets
and SLA alerts are not marked as spam. Test with:

```bash
php artisan tinker --execute="Mail::raw('MSPAssist mail test', fn(\$m) => \$m->to('you@example.com')->subject('Test'));"
```

## 10. Flutter web dashboard

Build locally or download the `web-build` artifact from CI:

```bash
cd apps/flutter_app
flutter build web --release --base-href /app/ --no-web-resources-cdn
```

Upload `build/web/*` to `~/mspassist/public/app/`. The app calls the API on
its own origin (`https://support.example.com/api/v1/`), so no CORS is needed.

Routing: the app uses clean URLs (`/app/tickets/42`). Real files under
`public/app` are served by Apache directly; any other `/app/...` path falls
through Laravel's `public/.htaccess` to `index.php`, and the `/app/{path?}`
route returns `public/app/index.html`. No extra rewrite rules are required.
Optionally add `public/app/.htaccess` for caching:

```apache
<IfModule mod_headers.c>
  <FilesMatch "\.(js|wasm|otf|ttf|png|json)$">
    Header set Cache-Control "public, max-age=604800"
  </FilesMatch>
  <FilesMatch "(index\.html|flutter_service_worker\.js|flutter_bootstrap\.js)$">
    Header set Cache-Control "no-cache"
  </FilesMatch>
</IfModule>
```

Mobile/desktop builds point at the production API with
`--dart-define=API_BASE_URL=https://support.example.com/api/v1`.

## 11. HTTPS hardening

- Force HTTPS: cPanel → *Domains* → *Force HTTPS Redirect* (or add a rewrite
  in `public/.htaccess` before Laravel's rules).
- `SESSION_SECURE_COOKIE=true` and `APP_DEBUG=false` are mandatory in production.
- The API sends `X-Content-Type-Options`, `X-Frame-Options`,
  `Referrer-Policy` and HSTS (over HTTPS).

## 12. Backups

- **Database:** cPanel → *Backup* (daily account backups) plus a nightly dump:
  ```
  15 2 * * * mysqldump --single-transaction -u <cpaneluser>_msp -p'<password>' <cpaneluser>_mspassist | gzip > /home/<cpaneluser>/backups/mspassist-$(date +\%F).sql.gz
  ```
  (Prefer a `~/.my.cnf` with `chmod 600` instead of the password on the command line.)
- **Files:** back up `~/mspassist/storage/app/private` (attachments) and `.env`.
- Keep at least 14 days, copy off-server regularly and test a restore.

## 13. Updating

```bash
cd ~/mspassist
php artisan down --retry=60
# upload the new release (or git pull) and then:
composer install --no-dev --optimize-autoloader
php artisan migrate --force
php artisan config:cache && php artisan route:cache && php artisan view:cache
php artisan up
```

Upload the new web build to `public/app/` at the same time. Keep production
credentials only on the server; development uses its own `.env` and database.

## 14. Troubleshooting

| Symptom | Check |
| --- | --- |
| 500 error on every request | `storage/` and `bootstrap/cache` writable? `APP_KEY` set? `storage/logs/laravel-*.log` |
| Web login returns 419 | `SESSION_DOMAIN` / `SANCTUM_STATEFUL_DOMAINS` must match the domain; HTTPS + `SESSION_SECURE_COOKIE=true` |
| Web app blank page | `--base-href /app/` used when building? Files uploaded to `public/app`? |
| No SLA e-mails | Cron entry and PHP path; `php artisan schedule:list`; mail settings |
| Uploads fail | `upload_max_filesize`/`post_max_size`; `MSPASSIST_ATTACHMENT_MAX_KB` |
