#!/bin/zsh
# Builds a release binary and wraps it in Grizzly.app (ad-hoc signed, for local use).
set -euo pipefail
cd "$(dirname "$0")/.."

# swiftc is used directly because `swift build` needs a full Xcode install (PlatformPath lookup fails with Command Line Tools only).
# ARCH (arm64 | x86_64) and OUT override the defaults: the host architecture and build/.
ARCH="${ARCH:-$(uname -m)}"
APP="${OUT:-build}/Grizzly.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library -target "$ARCH-apple-macos13.0" \
    -o "$APP/Contents/MacOS/Grizzly" $(find Sources -name '*.swift')

# Icon and translations (resources/en.lproj, resources/ru.lproj).
cp resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R resources/en.lproj resources/ru.lproj "$APP/Contents/Resources/"
# Fonts that come with the app (SIL Open Font License; every family folder carries its OFL.txt).
cp -R resources/fonts "$APP/Contents/Resources/Fonts"

EXTS=$(cat <<'EOF'
<string>md</string><string>markdown</string><string>mdown</string><string>txt</string><string>text</string>
<string>log</string><string>json</string><string>yaml</string><string>yml</string><string>csv</string>
<string>tsv</string><string>xml</string><string>html</string><string>htm</string><string>ini</string>
<string>conf</string><string>toml</string><string>tex</string><string>rtf</string>
EOF
)

# Source code: offered under "Open With" but never claimed as the default (Xcode, VS Code and friends keep those).
CODE_EXTS=$(cat <<'EOF'
<string>py</string><string>pyw</string><string>swift</string><string>c</string><string>h</string><string>cpp</string>
<string>cc</string><string>cxx</string><string>hpp</string><string>hh</string><string>hxx</string><string>cs</string>
<string>js</string><string>mjs</string><string>cjs</string><string>jsx</string><string>ts</string><string>tsx</string>
<string>css</string><string>scss</string><string>php</string>
EOF
)

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Grizzly</string>
  <key>CFBundleDisplayName</key><string>Grizzly</string>
  <key>CFBundleIdentifier</key><string>app.grizzly.Grizzly</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSMultipleInstancesProhibited</key><true/>
  <key>CFBundleLocalizations</key><array><string>ru</string><string>en</string></array>
  <key>CFBundleExecutable</key><string>Grizzly</string>
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
      <key>LSHandlerRank</key><string>Default</string>
      <key>CFBundleTypeExtensions</key>
      <array>$EXTS</array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Source code</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key>
      <array>$CODE_EXTS</array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Text and source files</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array><string>public.text</string><string>public.plain-text</string><string>public.source-code</string><string>public.data</string></array>
    </dict>
  </array>
</dict>
</plist>
EOF

# Quick Look extension (Space in Finder). Sandboxed, as the system requires for app extensions.
APPEX="$APP/Contents/PlugIns/GrizzlyQuickLook.appex"
mkdir -p "$APPEX/Contents/MacOS"
swiftc -O -parse-as-library -application-extension -target "$ARCH-apple-macos13.0" \
    -module-name GrizzlyQuickLook -Xlinker -e -Xlinker _NSExtensionMain \
    -framework QuickLookUI \
    -o "$APPEX/Contents/MacOS/GrizzlyQuickLook" \
    QuickLook/*.swift Sources/Grizzly/Core/FileLoader.swift Sources/Grizzly/Core/FileType.swift \
    Sources/Grizzly/Core/CSVTable.swift Sources/Grizzly/Core/MarkdownParser.swift
VERSION=$(sed -n 's|.*<key>CFBundleShortVersionString</key><string>\(.*\)</string>.*|\1|p' "$APP/Contents/Info.plist")
sed "s|__VERSION__|$VERSION|" QuickLook/Info.plist > "$APPEX/Contents/Info.plist"
codesign --force --sign - --entitlements QuickLook/QuickLook.entitlements "$APPEX" >/dev/null

codesign --force --sign - "$APP" >/dev/null
# A fresh mtime makes Finder drop its cached (generic) icon for a rebuilt bundle.
touch "$APP"
echo "Built $APP"
