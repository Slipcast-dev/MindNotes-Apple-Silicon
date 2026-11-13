#!/bin/zsh
# Builds a release binary and wraps it in MindNotes.app (ad-hoc signed, for local use).
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/target.sh
# swiftc напрямую: для сборки хватает Command Line Tools. OUT меняет каталог результата (по умолчанию build/).
APP="${OUT:-build}/MindNotes.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Модуль один, поэтому оптимизация всего модуля разом. SWIFT_OPT=-Onone: быстрая отладочная сборка.
swiftc ${=SWIFT_OPT:--O -wmo} -parse-as-library -target "$TARGET" \
    -o "$APP/Contents/MacOS/MindNotes" $(find Sources -name '*.swift')

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
  <key>CFBundleName</key><string>MindNotes</string>
  <key>CFBundleDisplayName</key><string>MindNotes</string>
  <key>CFBundleIdentifier</key><string>local.personal.MindNotes</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSMultipleInstancesProhibited</key><true/>
  <key>CFBundleLocalizations</key><array><string>ru</string><string>en</string></array>
  <key>CFBundleExecutable</key><string>MindNotes</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$(tr -d "[:space:]" < VERSION)</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Slipcast-dev. All rights reserved.</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCalendarsFullAccessUsageDescription</key><string>MindNotes synchronizes database records with Calendar.</string>
  <key>NSRemindersFullAccessUsageDescription</key><string>MindNotes synchronizes database records with Reminders.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Text document</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key>
      <array>$EXTS</array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>MindNotes Plugin</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSTypeIsPackage</key><true/>
      <key>LSItemContentTypes</key><array><string>local.personal.mindnotes.plugin</string></array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>local.personal.mindnotes.plugin</string>
      <key>UTTypeDescription</key><string>MindNotes Plugin</string>
      <key>UTTypeConformsTo</key><array><string>com.apple.package</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>mnplugin</string></array></dict>
    </dict>
  </array>
</dict>
</plist>
EOF

# Ad-hoc подпись с требованием «по идентификатору»: разрешения macOS (Календарь, Напоминания, уведомления)
# привязываются к bundle id, а не к хешу сборки, и не теряются после пересборки.
codesign --force --sign - --requirements '=designated => identifier "local.personal.MindNotes"' "$APP" >/dev/null
# A fresh mtime makes Finder drop its cached (generic) icon for a rebuilt bundle.
touch "$APP"
echo "Built $APP"
