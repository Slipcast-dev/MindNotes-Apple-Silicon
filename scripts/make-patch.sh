#!/bin/zsh
# Builds the update patch from the previous release to the current build: only the files that changed, binaries as deltas.
#   ./scripts/make-patch.sh <previous Grizzly-X.Y.Z-ARCH.dmg> [ARCH]
# Needs build/Grizzly.app of the same architecture (ARCH=arm64 | x86_64, default: this machine). Writes
# build/Grizzly-patch-<from>-to-<to>-<arch>.zip and prints the line with its SHA-256 for the release notes.
# Upload the zip next to the .dmg files; the app downloads it instead of the whole image when it is on <from>.
set -euo pipefail
cd "$(dirname "$0")/.."

OLD_DMG="${1:?previous release .dmg}"
ARCH="${2:-${ARCH:-$(uname -m)}}"
NEW_APP="${OUT:-build}/Grizzly.app"
[[ -d "$NEW_APP" ]] || { echo "build $NEW_APP first (./scripts/build-app.sh)"; exit 1; }

WORK=$(mktemp -d)
trap 'hdiutil detach -quiet "$WORK/mount" 2>/dev/null || true; rm -rf "$WORK"' EXIT
mkdir "$WORK/mount"
hdiutil attach -nobrowse -readonly -noverify -mountpoint "$WORK/mount" "$OLD_DMG" >/dev/null
ditto "$WORK/mount/Grizzly.app" "$WORK/old.app"

swiftc -O -o "$WORK/make-patch" scripts/make-patch/main.swift \
    Sources/Grizzly/Core/AppPatch.swift Sources/Grizzly/Core/BinaryDelta.swift Sources/Grizzly/Core/Updater.swift

FROM=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$WORK/old.app/Contents/Info.plist")
TO=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$NEW_APP/Contents/Info.plist")
TAG=$([[ "$ARCH" == "x86_64" ]] && echo x64 || echo "$ARCH")
OUT_ZIP="${OUT:-build}/Grizzly-patch-$FROM-to-$TO-$TAG.zip"
"$WORK/make-patch" "$WORK/old.app" "$NEW_APP" "$OUT_ZIP"
echo "Built $OUT_ZIP ($(du -h "$OUT_ZIP" | cut -f1))"
echo "$(shasum -a 256 "$OUT_ZIP" | cut -d' ' -f1)  $(basename "$OUT_ZIP")"
