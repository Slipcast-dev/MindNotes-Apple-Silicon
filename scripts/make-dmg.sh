#!/bin/zsh
# Packs build/MindNotes.app into build/MindNotes-<version>.dmg (drag-to-Applications installer).
# Signing: uses the identity from $SIGN_IDENTITY (a "Developer ID Application: ..." certificate)
# if set, otherwise the app keeps its ad-hoc signature. Notarization runs only when a signed
# build and a notarytool keychain profile ($NOTARY_PROFILE) are both provided.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${OUT:-build}"
APP="$OUT/MindNotes.app"
[[ -d "$APP" ]] || ./scripts/build-app.sh

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="$OUT/MindNotes-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Как открыть первый раз.txt" <<'EOF'
Перетащите MindNotes в папку Applications.

Приложение не нотаризовано Apple, поэтому при первом запуске macOS его остановит.
Откройте «Системные настройки» → «Конфиденциальность и безопасность» и нажмите «Всё равно открыть»
рядом с сообщением о MindNotes. Это нужно сделать один раз.

Нужен Mac на Apple Silicon с macOS 15 или новее.

The app is not notarized by Apple. On first launch open System Settings → Privacy & Security
and click "Open Anyway" next to the MindNotes message. Requires Apple silicon and macOS 15 or later.
EOF

rm -f "$DMG"
hdiutil create -volname "MindNotes" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" "$DMG"
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
    fi
fi

echo "Built $DMG"
