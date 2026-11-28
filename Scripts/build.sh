#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PYTHONDONTWRITEBYTECODE=1
SAFETY="$PROJECT_DIR/Scripts/release-safety.py"
VERSION_TOOL="$PROJECT_DIR/Scripts/macos_version.py"
APP_ONLY=''
VERIFY_ONLY=false
case "$#:${1:-}" in
  0:) ;;
  1:--verify-only) VERIFY_ONLY=true ;;
  2:--app-only)
    APP_ONLY="$2"
    python3 "$SAFETY" check-noindex "$APP_ONLY"
    [[ ! -e "$APP_ONLY" && ! -L "$APP_ONLY" ]] || { print -u2 '目标已存在，请先检查再移除'; exit 1; } ;;
  *) print -u2 '使用 build.sh、build.sh --verify-only 或 build.sh --app-only .noindex容器/搞机灵.app'; exit 1 ;;
esac
RELEASE_VERSION="$(python3 "$VERSION_TOOL")"
APP_VERSION="${RELEASE_VERSION% *}"
BUILD_NUMBER="${RELEASE_VERSION##* }"
if ! $VERIFY_ONLY; then python3 "$PROJECT_DIR/Scripts/sign-app.py" --check-identity; fi
STAGING="$(python3 "$SAFETY" workdir --parent /private/tmp --prefix gaojiling-build-)"
OUTPUT_CREATED=false
OUTPUT_COMPLETE=false
cleanup() {
  local result=$?
  if $OUTPUT_CREATED && ! $OUTPUT_COMPLETE; then rm -rf "$APP_ONLY"; fi
  rm -rf "$STAGING"
  return "$result"
}
trap cleanup EXIT
APP="$STAGING/搞机灵.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
export CLANG_MODULE_CACHE_PATH="$STAGING/cache"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
clang -O2 -arch arm64 -mmacosx-version-min=14.0 -isysroot "$SDK" -c "$PROJECT_DIR/Sources/NativeMetrics.c" -o "$STAGING/NativeMetrics.o"
swiftc -swift-version 5 -O -target arm64-apple-macos14.0 -sdk "$SDK" -module-cache-path "$STAGING/cache" \
  -import-objc-header "$PROJECT_DIR/Sources/NativeMetrics.h" \
  "$PROJECT_DIR"/Sources/*.swift "$STAGING/NativeMetrics.o" \
  -framework AppKit -framework SwiftUI -framework IOKit -framework CoreFoundation -framework Carbon -framework ServiceManagement -framework UserNotifications -framework Network -framework ApplicationServices -framework Security -framework UniformTypeIdentifiers -lsqlite3 \
  -o "$APP/Contents/MacOS/GaoJiLing"
ICON="$PROJECT_DIR/Assets/AppIcon.icns"
if [[ ! -f "$ICON" || "$PROJECT_DIR/Assets/AppIcon.png" -nt "$ICON" ]]; then
  if $VERIFY_ONLY; then ICON="$STAGING/AppIcon.icns"; fi
  swift -module-cache-path "$STAGING/cache" "$PROJECT_DIR/Scripts/MakeIcon.swift" "$PROJECT_DIR/Assets/AppIcon.png" "$ICON"
fi
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
cp "$PROJECT_DIR/Assets/AppIcon.png" "$APP/Contents/Resources/AppIcon.png"
cp "$PROJECT_DIR/THIRD-PARTY-NOTICES.txt" "$APP/Contents/Resources/"
cp "$PROJECT_DIR/README.md" "$APP/Contents/Resources/使用说明.txt"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.gaoseries.GaoJiLing</string>
<key>CFBundleName</key><string>搞机灵</string>
<key>CFBundleDisplayName</key><string>搞机灵</string>
<key>CFBundleExecutable</key><string>GaoJiLing</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>搞系列 · 搞机灵</string>
<key>NSSupportsAutomaticTermination</key><false/>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>普通 NTFS 卷镜像（确认后只读）</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>CFBundleTypeExtensions</key><array><string>ntfs</string><string>img</string><string>raw</string><string>dd</string></array>
</dict></array>
</dict></plist>
PLIST
PYTHONDONTWRITEBYTECODE=1 python3 "$PROJECT_DIR/Scripts/make-capabilities.py" \
  --version-file "$PROJECT_DIR/VERSION" --info-plist "$APP/Contents/Info.plist" \
  --output "$APP/Contents/Resources/GaoCapabilities.json"
plutil -lint "$APP/Contents/Info.plist"
python3 "$VERSION_TOOL" --info-plist "$APP/Contents/Info.plist" >/dev/null
if $VERIFY_ONLY; then
  xcrun lipo "$APP/Contents/MacOS/GaoJiLing" -verify_arch arm64
  print "macOS ARM64 编译和宿主 Info.plist 核验通过：V$APP_VERSION 构建 $BUILD_NUMBER"
  exit 0
fi
xattr -cr "$APP"
python3 "$PROJECT_DIR/Scripts/sign-app.py" --app "$APP" --new-build
codesign --verify --strict "$APP"
if [[ -n "$APP_ONLY" ]]; then
  mkdir "$APP_ONLY"
  OUTPUT_CREATED=true
  ditto "$APP" "$APP_ONLY"
  codesign --verify --strict "$APP_ONLY"
  OUTPUT_COMPLETE=true
  print "APP=$APP_ONLY"
  print '展开程序仅供当前步骤使用；使用结束后须精确注销可能的本应用登记并删除此 .noindex 副本。'
  exit 0
fi
mkdir -p "$STAGING/disk" "$PROJECT_DIR/Release"
ditto "$APP" "$STAGING/disk/搞机灵.app"
ln -s /Applications "$STAGING/disk/Applications"
cp "$APP/Contents/Resources/使用说明.txt" "$STAGING/disk/使用说明.txt"
hdiutil create -quiet -volname "搞机灵 V$APP_VERSION" -srcfolder "$STAGING/disk" -format UDZO "$STAGING/GaoJiLing-$APP_VERSION.dmg"
hdiutil verify -quiet "$STAGING/GaoJiLing-$APP_VERSION.dmg"
mv "$STAGING/GaoJiLing-$APP_VERSION.dmg" "$PROJECT_DIR/Release/GaoJiLing-$APP_VERSION.dmg"
(cd "$PROJECT_DIR/Release" && shasum -a 256 "GaoJiLing-$APP_VERSION.dmg" > "GaoJiLing-$APP_VERSION.dmg.sha256")
print "构建完成：$PROJECT_DIR/Release/GaoJiLing-$APP_VERSION.dmg"
print '旧安装包将在新版安装验证成功后由 install.sh 清理。'
