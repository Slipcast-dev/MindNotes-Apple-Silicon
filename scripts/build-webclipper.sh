#!/bin/zsh
# Собирает установщик Web Clipper (ADR-0019): build/MindNotes Web Clipper.app.
# Пользователь просто открывает его: программа сама ставит плагин в MindNotes и расширение во все найденные браузеры,
# а подключение к MindNotes настраивается без его участия.
#   Contents/Resources/WebClipper.mnplugin   — плагин для MindNotes и расширение для браузеров на Chromium
#   Contents/PlugIns/…Extension.appex        — расширение Safari (нужен Xcode; SKIP_SAFARI=1 — без него)
# Подпись ad-hoc, для своего Mac.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/target.sh

SRC=Plugins/WebClipper
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# Safari показывает расширение из каждой зарегистрированной копии программы. Сборки (и промежуточная копия Xcode)
# снимаются с регистрации, чтобы в Safari оставалось только установленное расширение.
unregister() {
    local app=$1
    for x in "$app"/Contents/PlugIns/*.appex(N); do pluginkit -r "$x" 2>/dev/null || true; done
    "$LSREGISTER" -u "$app" 2>/dev/null || true
}
OUT_DIR="${OUT:-build}"
APP_NAME="MindNotes Web Clipper"
APP="$OUT_DIR/$APP_NAME.app"
BUNDLE_ID=local.personal.MindNotes.WebClipper

version=$(/usr/bin/plutil -extract version raw -o - "$SRC/manifest.json")
browser_version=$(/usr/bin/plutil -extract version raw -o - "$SRC/browser/manifest.json")
[[ "$version" == "$browser_version" ]] || { echo "Версии плагина ($version) и расширения ($browser_version) расходятся"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 1. Пакет плагина: описание и расширение для Chromium со значками.
PKG="$WORK/WebClipper.mnplugin"
mkdir -p "$PKG/browser"
cp "$SRC/manifest.json" "$PKG/manifest.json"
CHROME="$PKG/browser/chrome"
cp -R "$SRC/browser" "$CHROME"
find "$CHROME" -name '.DS_Store' -delete
# Отметка сборки (видна в подсказке над «MindNotes» в окне расширения): по ней понятно, свежая ли копия открыта.
stamp="$version ($(date '+%Y-%m-%d %H:%M'))"
/usr/bin/python3 -c 'import json,sys; p=sys.argv[1]; m=json.load(open(p)); m["version_name"]=sys.argv[2]; json.dump(m,open(p,"w"),ensure_ascii=False,indent=2)' "$CHROME/manifest.json" "$stamp"
mkdir -p "$CHROME/icons"
for size in 16 32 48 128; do
    sips -z $size $size resources/AppIcon-source.png --out "$CHROME/icons/icon-$size.png" >/dev/null
done

# 2. Программа-установщик.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/PlugIns"
swiftc ${=SWIFT_OPT:--O} -parse-as-library -target "$TARGET" -o "$APP/Contents/MacOS/WebClipperInstaller" "$SRC"/Installer/*.swift
cp resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
ditto "$PKG" "$APP/Contents/Resources/WebClipper.mnplugin"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>WebClipperInstaller</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>ru</string><string>en</string></array>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSMultipleInstancesProhibited</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 3. Расширение Safari: Xcode собирает .appex из того же расширения, установщик становится его программой-контейнером.
if [[ "${SKIP_SAFARI:-0}" != 1 ]] && xcodebuild -version >/dev/null 2>&1; then
    xcrun safari-web-extension-converter "$CHROME" --project-location "$WORK/safari" --app-name "$APP_NAME" \
        --bundle-identifier "$BUNDLE_ID" --macos-only --swift --copy-resources --no-open --no-prompt --force >/dev/null
    PROJECT=$(find "$WORK/safari" -maxdepth 3 -name '*.xcodeproj' | head -1)
    [[ -n "$PROJECT" ]] || { echo "Проект Safari не создан"; exit 1; }
    # Конвертер даёт программе id из её имени; id расширения должен начинаться с id программы.
    for f in "$PROJECT"/project.pbxproj(N) "$PROJECT"/project.xcproj(N); do
        sed -i '' 's/local\.personal\.MindNotes\.MindNotes-Web-Clipper/local.personal.MindNotes.WebClipper/g' "$f"
    done
    xcodebuild -project "$PROJECT" -scheme "$APP_NAME" -configuration Release -derivedDataPath "$WORK/dd" \
        MARKETING_VERSION="$version" CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
        ENABLE_USER_SCRIPT_SANDBOXING=NO -quiet build 2>&1 | grep -vE 'IDERunDestination|Using the first of multiple|platform:macOS|^\}?$|^\{' || true
    APPEX=$(find "$WORK/dd/Build/Products/Release/$APP_NAME.app/Contents/PlugIns" -maxdepth 1 -name '*.appex' | head -1)
    [[ -n "$APPEX" ]] || { echo "Расширение Safari не собрано"; exit 1; }
    ditto "$APPEX" "$APP/Contents/PlugIns/$(basename "$APPEX")"
    unregister "$WORK/dd/Build/Products/Release/$APP_NAME.app"
    # Расширение Safari обязано быть в песочнице: права берутся из его же сборки.
    codesign -d --entitlements :- "$APPEX" > "$WORK/appex.entitlements" 2>/dev/null
    /usr/libexec/PlistBuddy -c "Delete :com.apple.security.get-task-allow" "$WORK/appex.entitlements" 2>/dev/null || true
    codesign --force --sign - --entitlements "$WORK/appex.entitlements" "$APP/Contents/PlugIns/$(basename "$APPEX")" 2>/dev/null
elif [[ "${SKIP_SAFARI:-0}" != 1 ]]; then
    echo "Xcode не найден: установщик без Safari (SKIP_SAFARI=1, чтобы не видеть это сообщение)"
fi

codesign --force --sign - "$APP" 2>/dev/null
touch "$APP"
unregister "$APP"
echo "Built $APP"
