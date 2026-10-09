#!/usr/bin/env bash
# Builds the Flutter web dashboard and copies it into the Laravel public dir.
# Usage: scripts/build_web.sh [API_BASE_URL]
# By default the app calls the API on its own origin (/api/v1/).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/apps/flutter_app"
ARGS=(--release --base-href /app/)
if [[ $# -ge 1 ]]; then ARGS+=(--dart-define=API_BASE_URL="$1"); fi
flutter build web "${ARGS[@]}" --no-web-resources-cdn
rm -rf "$ROOT/backend/public/app"
cp -r build/web "$ROOT/backend/public/app"
echo "Web app copied to backend/public/app"
