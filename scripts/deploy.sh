#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="meeting"
TARGET="/Applications/${APP_NAME}.app"

./scripts/package-app.sh

echo "▸ 실행 중인 앱 종료"
osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
sleep 1
pkill -f "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" 2>/dev/null || true

echo "▸ $TARGET 교체"
rm -rf "$TARGET"
ditto "dist/${APP_NAME}.app" "$TARGET"
rm -rf "dist/${APP_NAME}.app"

open "$TARGET"
echo "✓ 반영 완료: $TARGET"
