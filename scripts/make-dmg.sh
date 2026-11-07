#!/bin/zsh
# Packs build/Minerva Noema.app into build/MinervaNoema-<version>.dmg (drag-to-Applications installer).
# Signing: uses the identity from $SIGN_IDENTITY (a "Developer ID Application: ..." certificate)
# if set, otherwise the app keeps its ad-hoc signature. Notarization runs only when a signed
# build and a notarytool keychain profile ($NOTARY_PROFILE) are both provided.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${OUT:-build}"
APP="$OUT/Minerva Noema.app"
[[ -d "$APP" ]] || ./scripts/build-app.sh

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="$OUT/MinervaNoema-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Как открыть первый раз.txt" <<'EOF'
Перетащите Minerva Noema в папку Applications.

Приложение не нотаризовано Apple, поэтому при первом запуске macOS может его заблокировать.
Откройте его так: правый клик по Minerva Noema → «Открыть» → «Открыть».
Или выполните в Терминале:  xattr -dr com.apple.quarantine "/Applications/Minerva Noema.app"

The app is not notarized by Apple. On first launch: right-click Minerva Noema → Open → Open,
or run:  xattr -dr com.apple.quarantine "/Applications/Minerva Noema.app"
EOF

rm -f "$DMG"
hdiutil create -volname "Minerva Noema" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" "$DMG"
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
    fi
fi

echo "Built $DMG"
