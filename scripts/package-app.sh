#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="meeting"
BUNDLE_ID="com.parkjin.meeting"
DIST="dist/${APP_NAME}.app"
VERSION="$(tr -d '[:space:]' < VERSION)"

echo "▸ release 빌드"
swift build -c release

echo "▸ 번들 조립"
rm -rf "$DIST"
mkdir -p "$DIST/Contents/MacOS" "$DIST/Contents/Resources"
cp .build/release/MeetingApp "$DIST/Contents/MacOS/${APP_NAME}"
cp -R ".build/release/meeting_MeetingCore.bundle" "$DIST/Contents/Resources/"

if xcrun --find actool >/dev/null 2>&1; then
    echo "▸ 에셋 컴파일 (actool: AccentColor·AppIcon.icon → Assets.car + AppIcon.icns)"
    xcrun actool Resources/Assets.xcassets Resources/AppIcon.icon \
        --compile "$DIST/Contents/Resources" \
        --platform macosx --minimum-deployment-target 15.0 \
        --app-icon AppIcon \
        --output-partial-info-plist /dev/null > /dev/null
    ICON_KEYS='    <key>NSAccentColorName</key><string>AccentColor</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>'
else
    echo "▸ 에셋 (actool 없음 — 커밋된 AppIcon.icns 복사; 액센트는 코드의 .tint가 맡는다)"
    cp Resources/AppIcon.icns "$DIST/Contents/Resources/AppIcon.icns"
    ICON_KEYS='    <key>CFBundleIconFile</key><string>AppIcon</string>'
fi

cat > "$DIST/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
${ICON_KEYS}
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>미팅 녹음 시 마이크 음성을 함께 기록합니다. 녹음 파일과 전사는 이 기기 안에서만 처리합니다.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>회의 상대의 소리를 함께 녹음하기 위해 시스템 오디오를 캡처합니다. 녹음 파일과 전사는 이 기기 안에서만 처리합니다.</string>
</dict>
</plist>
PLIST

echo "▸ 코드 서명"
if security find-identity -v -p codesigning | grep -q '"meeting-dev"'; then
    codesign --force --deep --sign meeting-dev "$DIST"
else
    echo "  (meeting-dev 인증서 없음 — ad-hoc 서명. 재설치마다 권한을 다시 허용해야 합니다. scripts/make-signing-identity.sh)"
    codesign --force --deep --sign - "$DIST"
fi

echo "✓ 완료: $DIST"
echo "  실행: open $DIST   (반영은 scripts/deploy.sh — /Applications 사본 하나만 유지)"
echo "  녹음에는 마이크·시스템 오디오 권한이, 통화 창 제목에는 화면 기록 권한이 필요합니다 —"
echo "  시스템 설정 > 개인정보 보호 및 보안에서 허용해 주십시오."
