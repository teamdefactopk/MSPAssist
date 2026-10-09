# MSPAssist Flutter app

One codebase for Android, iOS, Windows, macOS and the web dashboard.
See [docs/architecture.md](../../docs/architecture.md),
[docs/offline-sync.md](../../docs/offline-sync.md) and
[docs/setup.md](../../docs/setup.md).

```bash
flutter pub get
flutter analyze && flutter test
flutter run -d <device> --dart-define=API_BASE_URL=http://127.0.0.1:8000/api/v1
flutter build web --release --base-href /app/ --no-web-resources-cdn
```
