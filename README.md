# MSPAssist — CyberCraft IT Support System

MSPAssist (working name) is CyberCraft's system for managing IT support across
many client organizations and their sites: tickets, client–support chat,
technician work logs and onsite visits, SLA tracking with escalation,
dashboards and reports.

| Part | Technology | Path |
| --- | --- | --- |
| API | Laravel 13 / PHP 8.3, Sanctum, MySQL | [`backend/`](backend) |
| Apps | Flutter 3.47 — Android, iOS, Windows, macOS and the web dashboard | [`apps/flutter_app/`](apps/flutter_app) |
| Docs | Architecture, schema, API, setup, offline sync, permissions, cPanel deployment | [`docs/`](docs) |

## Quick start (local)

```bash
# API
cd backend
composer install
cp .env.example .env && php artisan key:generate     # set DB_* (MySQL) or DB_CONNECTION=sqlite
php artisan migrate --seed
php artisan db:seed --class=DemoSeeder               # fictional demo accounts, see docs/setup.md
php artisan serve                                     # http://127.0.0.1:8000

# Web dashboard served by the API at /app
cd .. && scripts/build_web.sh                          # needs Flutter; then open http://127.0.0.1:8000/app/

# Desktop / mobile
cd apps/flutter_app
flutter run -d windows --dart-define=API_BASE_URL=http://127.0.0.1:8000/api/v1
```

Demo login: `manager@cybercraft.example` / `Demo-Password-2026` (development only).

## Documentation

- [Architecture](docs/architecture.md) (includes known limitations)
- [Database schema](docs/database-schema.md)
- [REST API](docs/api.md)
- [Roles & permissions](docs/permissions.md)
- [Offline sync](docs/offline-sync.md)
- [Local setup & builds](docs/setup.md)
- [cPanel deployment](docs/deployment-cpanel.md)
- [Contributor/agent guidance](AGENTS.md)

## Checks

```bash
cd backend && php artisan test && vendor/bin/pint --test
cd apps/flutter_app && flutter analyze && flutter test
```

GitHub Actions (`.github/workflows/ci.yml`) runs the backend tests on SQLite
and MySQL 8, Flutter analyze/tests, the web build and an Android APK build.
Windows, macOS and iOS builds run on demand (`platform-builds.yml`).
Nothing is deployed automatically.
