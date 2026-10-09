# Local development setup

## Prerequisites

| Tool | Version used in development/CI |
| --- | --- |
| PHP | 8.3+ with `pdo_mysql`, `pdo_sqlite`, `mbstring`, `fileinfo`, `gd`, `zip`, `intl`, `openssl` |
| Composer | 2.x |
| MySQL / MariaDB | MySQL 8.0 or MariaDB 10.6+ (SQLite works for quick local runs and tests) |
| Flutter | 3.47.x stable (Dart 3.13) |
| Android | Android Studio / SDK + JDK 17 for Android builds |
| Xcode | macOS + Xcode for iOS/macOS builds |
| Visual Studio 2022 | "Desktop development with C++" for Windows builds |

## 1. Backend

```bash
cd backend
composer install
cp .env.example .env
php artisan key:generate
```

Create a database and user, then put the credentials in `.env`:

```sql
CREATE DATABASE mspassist CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'mspassist'@'localhost' IDENTIFIED BY 'choose-a-local-password';
GRANT ALL PRIVILEGES ON mspassist.* TO 'mspassist'@'localhost';
```

(For a throwaway setup use `DB_CONNECTION=sqlite` and `touch database/database.sqlite`.)

```bash
php artisan migrate --seed                 # schema + categories + default SLA policies
php artisan db:seed --class=DemoSeeder     # optional fictional demo data (refuses to run in production)
php artisan serve                          # http://127.0.0.1:8000
```

Demo accounts created by `DemoSeeder` (password = `DEMO_PASSWORD` from `.env`,
default `Demo-Password-2026`):

| Email | Role |
| --- | --- |
| admin@cybercraft.example | CyberCraft Administrator |
| manager@cybercraft.example | Support Manager |
| tech1@cybercraft.example, tech2@cybercraft.example | Technician |
| admin@acme.example | Client Administrator (Acme Logistics) |
| user@acme.example | Client User (Acme, Warehouse site only) |
| admin@globex.example | Client Administrator (Globex Clinics) |

Mail is written to `storage/logs/laravel.log` with `MAIL_MAILER=log`, which is
where invitation and password-reset links appear during development.

To exercise SLA escalation locally run `php artisan sla:check` (or
`php artisan schedule:work` to emulate cron).

### Tests

```bash
php artisan test                      # SQLite in-memory
DB_CONNECTION=mysql DB_DATABASE=mspassist_test DB_USERNAME=... DB_PASSWORD=... php artisan test
vendor/bin/pint --test
```

## 2. Flutter app

```bash
cd apps/flutter_app
flutter pub get
flutter analyze
flutter test
```

The API base URL is a compile-time setting:

```bash
# Desktop / iOS simulator talking to a local backend
flutter run -d macos   --dart-define=API_BASE_URL=http://127.0.0.1:8000/api/v1
flutter run -d windows --dart-define=API_BASE_URL=http://127.0.0.1:8000/api/v1
# Android emulator (10.0.2.2 is the host machine; cleartext allowed in debug builds only)
flutter run -d emulator-5554 --dart-define=API_BASE_URL=http://10.0.2.2:8000/api/v1
```

Without `API_BASE_URL` native builds default to `http://127.0.0.1:8000/api/v1`
(`10.0.2.2` on Android) and the web build uses its own origin (`/api/v1/`).

### Web dashboard during development

Option A — same origin (closest to production):

```bash
scripts/build_web.sh          # builds with --base-href /app/ into backend/public/app
cd backend && php artisan serve
open http://127.0.0.1:8000/app/
```

Option B — hot reload on a separate port:

```bash
# backend/.env
CORS_ALLOWED_ORIGINS=http://localhost:5173
SANCTUM_STATEFUL_DOMAINS=localhost:5173,localhost:8000,localhost
SESSION_DOMAIN=localhost

cd apps/flutter_app
flutter run -d chrome --web-port 5173 --dart-define=API_BASE_URL=http://localhost:8000/api/v1
```

Use `localhost` (not `127.0.0.1`) for both so the session and XSRF cookies are
shared.

## 3. Release builds

```bash
cd apps/flutter_app
flutter build web --release --base-href /app/ --no-web-resources-cdn   # or scripts/build_web.sh
flutter build apk --release --dart-define=API_BASE_URL=https://support.example.com/api/v1
flutter build appbundle --release --dart-define=API_BASE_URL=https://support.example.com/api/v1
flutter build ios --release --dart-define=API_BASE_URL=https://support.example.com/api/v1
flutter build macos --release --dart-define=API_BASE_URL=https://support.example.com/api/v1
flutter build windows --release --dart-define=API_BASE_URL=https://support.example.com/api/v1
```

`--no-web-resources-cdn` makes the web build self-contained (CanvasKit is
served from your host instead of Google's CDN).

Release signing (Android keystore, Apple certificates, Windows code signing)
is intentionally not committed; configure it locally or with CI secrets.
