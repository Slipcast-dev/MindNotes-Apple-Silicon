#!/bin/zsh
# Builds a release binary and wraps it in Grizzly Notes.app (ad-hoc signed, for local use).
set -euo pipefail
cd "$(dirname "$0")/.."

# swiftc is used directly because `swift build` needs a full Xcode install (PlatformPath lookup fails with Command Line Tools only).
# ARCH (arm64 | x86_64) and OUT override the defaults: the host architecture and build/.
ARCH="${ARCH:-$(uname -m)}"
APP="${OUT:-build}/Grizzly Notes.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# SWIFT_OPT=-Onone: быстрая отладочная сборка главного бинарника.
swiftc "${SWIFT_OPT:--O}" -parse-as-library -target "$ARCH-apple-macos13.0" \
    -o "$APP/Contents/MacOS/GrizzlyNotes" $(find Sources -name '*.swift')

# Icon and translations (resources/en.lproj, resources/ru.lproj).
cp resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R resources/en.lproj resources/ru.lproj "$APP/Contents/Resources/"

EXTS=$(cat <<'EOF'
<string>md</string><string>markdown</string><string>txt</string><string>csv</string>
EOF
)

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Grizzly Notes</string>
  <key>CFBundleDisplayName</key><string>Grizzly Notes</string>
  <key>CFBundleIdentifier</key><string>local.personal.GrizzlyNotes</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSMultipleInstancesProhibited</key><true/>
  <key>CFBundleLocalizations</key><array><string>ru</string><string>en</string></array>
  <key>CFBundleExecutable</key><string>GrizzlyNotes</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$(tr -d "[:space:]" < VERSION)</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Slipcast-dev. All rights reserved.</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Text document</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key>
      <array>$EXTS</array>
    </dict>
  </array>
</dict>
</plist>
EOF

codesign --force --sign - "$APP" >/dev/null
# A fresh mtime makes Finder drop its cached (generic) icon for a rebuilt bundle.
touch "$APP"
echo "Built $APP"
