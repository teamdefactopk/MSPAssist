# MSPAssist API (Laravel)

See the repository [README](../README.md), [docs/setup.md](../docs/setup.md),
[docs/api.md](../docs/api.md) and [docs/deployment-cpanel.md](../docs/deployment-cpanel.md).

```bash
composer install && cp .env.example .env && php artisan key:generate
php artisan migrate --seed && php artisan serve
php artisan test
```
