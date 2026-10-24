#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PYTHONDONTWRITEBYTECODE=1
SAFETY="$PROJECT_DIR/Scripts/release-safety.py"
APP_ONLY=''
if (( $# )); then
  [[ "${1:-}" == '--app-only' && $# == 2 ]] || { print -u2 '使用 build.sh 或 build.sh --app-only .noindex容器/搞机灵.app'; exit 1; }
  APP_ONLY="$2"
  python3 "$SAFETY" check-noindex "$APP_ONLY"
  [[ ! -e "$APP_ONLY" && ! -L "$APP_ONLY" ]] || { print -u2 '目标已存在，请先检查再移除'; exit 1; }
fi
APP_VERSION="$(tr -d '\n' < "$PROJECT_DIR/VERSION")"
if [[ ! "$APP_VERSION" =~ '^[0-9]+\.[0-9]{2}$' ]]; then print -u2 'VERSION 必须为 1.00 格式'; exit 1; fi
BUILD_NUMBER="${APP_VERSION//./}"
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
if [[ ! -f "$PROJECT_DIR/Assets/AppIcon.icns" || "$PROJECT_DIR/Assets/AppIcon.png" -nt "$PROJECT_DIR/Assets/AppIcon.icns" ]]; then
  swift -module-cache-path "$STAGING/cache" "$PROJECT_DIR/Scripts/MakeIcon.swift" "$PROJECT_DIR/Assets/AppIcon.png" "$PROJECT_DIR/Assets/AppIcon.icns"
fi
cp "$PROJECT_DIR/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$PROJECT_DIR/Assets/AppIcon.png" "$APP/Contents/Resources/AppIcon.png"
cp "$PROJECT_DIR/THIRD-PARTY-NOTICES.txt" "$APP/Contents/Resources/"
cp "$PROJECT_DIR/使用说明.txt" "$APP/Contents/Resources/"
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
</dict></plist>
PLIST
PYTHONDONTWRITEBYTECODE=1 python3 "$PROJECT_DIR/Scripts/make-capabilities.py" \
  --version-file "$PROJECT_DIR/VERSION" --info-plist "$APP/Contents/Info.plist" \
  --output "$APP/Contents/Resources/GaoCapabilities.json"
plutil -lint "$APP/Contents/Info.plist"
xattr -cr "$APP"
codesign --force --sign - --identifier com.gaoseries.GaoJiLing "$APP"
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
cp "$PROJECT_DIR/使用说明.txt" "$STAGING/disk/使用说明.txt"
hdiutil create -quiet -volname "搞机灵 V$APP_VERSION" -srcfolder "$STAGING/disk" -format UDZO "$STAGING/GaoJiLing-$APP_VERSION.dmg"
hdiutil verify -quiet "$STAGING/GaoJiLing-$APP_VERSION.dmg"
mv "$STAGING/GaoJiLing-$APP_VERSION.dmg" "$PROJECT_DIR/Release/GaoJiLing-$APP_VERSION.dmg"
(cd "$PROJECT_DIR/Release" && shasum -a 256 "GaoJiLing-$APP_VERSION.dmg" > "GaoJiLing-$APP_VERSION.dmg.sha256")
print "构建完成：$PROJECT_DIR/Release/GaoJiLing-$APP_VERSION.dmg"
print '旧安装包将在新版安装验证成功后由 install.sh 清理。'
