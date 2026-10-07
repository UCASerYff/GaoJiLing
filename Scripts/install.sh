#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_VERSION="$(tr -d '\n' < "$PROJECT_DIR/VERSION")"
PACKAGE="$PROJECT_DIR/Release/GaoJiLing-$APP_VERSION.dmg"
DESTINATION="/Applications/搞机灵.app"
NEW_APP="/Applications/.GaoJiLing-install.app"
OLD_APP="/Applications/.GaoJiLing-previous.app"
IDENTIFIER='com.gaoseries.GaoJiLing'
MOUNT="$(mktemp -d /private/tmp/gaojiling-install.XXXXXX)"
trap 'hdiutil detach -quiet "$MOUNT" 2>/dev/null || true; rmdir "$MOUNT" 2>/dev/null || true' EXIT
[[ -f "$PACKAGE" ]] || { print -u2 '缺少当前版本安装包，请先构建'; exit 1; }
(cd "$PROJECT_DIR/Release" && shasum -a 256 -c "GaoJiLing-$APP_VERSION.dmg.sha256")
hdiutil attach -quiet -nobrowse -mountpoint "$MOUNT" "$PACKAGE"
SOURCE="$MOUNT/搞机灵.app"
validate() {
  [[ ! -L "$1" ]] || { print -u2 "拒绝替换符号链接：$1"; exit 1; }
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist")" == "$IDENTIFIER" ]] || { print -u2 "应用标识不符：$1"; exit 1; }
  codesign --verify --strict "$1"
}
validate "$SOURCE"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE/Contents/Info.plist")" == "$APP_VERSION" ]] || exit 1
for ITEM in "$DESTINATION" "$NEW_APP" "$OLD_APP"; do if [[ -e "$ITEM" || -L "$ITEM" ]]; then validate "$ITEM"; fi; done
[[ ! -e "$NEW_APP" ]] || rm -rf "$NEW_APP"
ditto "$SOURCE" "$NEW_APP"
validate "$NEW_APP"
# Only stop this product's executable, and retain all user history and settings.
pkill -TERM -x GaoJiLing 2>/dev/null || true
for ATTEMPT in {1..20}; do pgrep -x GaoJiLing >/dev/null || break; sleep 0.2; done
if pgrep -x GaoJiLing >/dev/null; then print -u2 '旧程序仍在退出，请稍后重试；未替换旧程序'; exit 1; fi
[[ ! -e "$OLD_APP" ]] || rm -rf "$OLD_APP"
if [[ -e "$DESTINATION" ]]; then mv "$DESTINATION" "$OLD_APP"; fi
if ! mv "$NEW_APP" "$DESTINATION"; then [[ ! -e "$OLD_APP" ]] || mv "$OLD_APP" "$DESTINATION"; exit 1; fi
if ! validate "$DESTINATION"; then exit 1; fi
open "$DESTINATION"
sleep 2
if ! pgrep -x GaoJiLing >/dev/null; then
  print -u2 '新版未正常启动，恢复上一版。'
  rm -rf "$DESTINATION"
  if [[ -e "$OLD_APP" ]]; then mv "$OLD_APP" "$DESTINATION"; open "$DESTINATION"; fi
  exit 1
fi
[[ ! -e "$OLD_APP" ]] || rm -rf "$OLD_APP"
find "$PROJECT_DIR/Release" -maxdepth 1 -type f \( -name 'GaoJiLing-*.dmg' -o -name 'GaoJiLing-*.dmg.sha256' \) ! -name "GaoJiLing-$APP_VERSION.dmg" ! -name "GaoJiLing-$APP_VERSION.dmg.sha256" -delete
print "已安装搞机灵 V$APP_VERSION；已清理旧程序与旧安装包，监控历史和设置保留。"
