#!/bin/zsh
set -euo pipefail
umask 077
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PYTHONDONTWRITEBYTECODE=1
SAFETY="$PROJECT_DIR/Scripts/release-safety.py"
APP_VERSION="$(tr -d '\n' < "$PROJECT_DIR/VERSION")"
[[ "$APP_VERSION" =~ '^[0-9]+\.[0-9]{2}$' ]] || { print -u2 'VERSION 必须为 1.00 格式'; exit 1; }
PACKAGE="$PROJECT_DIR/Release/GaoJiLing-$APP_VERSION.dmg"
DESTINATION="/Applications/搞机灵.app"
IDENTIFIER='com.gaoseries.GaoJiLing'
NEW_IDENTITY=''
OLD_IDENTITY=''
STAGED_RECEIPT_SHA=''
STAGED_RETIRED=false
DEFER_CLEANUP=false
RUN_SMOKE=false
REPLACEMENT_STARTED=false
INSTALL_VERIFIED=false
while (( $# )); do
  case "$1" in
    --defer-cleanup) DEFER_CLEANUP=true ;;
    --smoke-test) RUN_SMOKE=true ;;
    --no-launch) RUN_SMOKE=false ;;
    *) print -u2 '参数仅支持 --no-launch、--defer-cleanup 或本人明确要求的 --smoke-test'; exit 1 ;;
  esac
  shift
done
LSREGISTER='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
[[ -x "$LSREGISTER" ]] || { print -u2 'LaunchServices 工具不可用，无法核验唯一入口；未安装'; exit 1; }
[[ -f "$PACKAGE" ]] || { print -u2 '缺少当前版本安装包，请先构建'; exit 1; }
(cd "$PROJECT_DIR/Release" && shasum -a 256 -c "GaoJiLing-$APP_VERSION.dmg.sha256")
WORK="$(python3 "$SAFETY" workdir --parent /Applications --prefix .GaoJiLing-install-)"
INSTALL_RECORD="$(python3 "$SAFETY" recorddir --parent "$WORK" --prefix "Install-V$APP_VERSION-")"
MOUNT="$WORK/Mount.noindex"
SOURCE="$MOUNT/搞机灵.app"
NEW_APP="$WORK/New.noindex/搞机灵.app"
OLD_APP="$WORK/Old.noindex/搞机灵.app"
STAGED_RECEIPT="$INSTALL_RECORD/staged-new.json"
MOUNT_ATTACHED=false
SOURCE_VALIDATED=false
KEEP_WORK=false

validate() {
  [[ ! -L "$1" ]] || { print -u2 "拒绝替换符号链接：$1"; return 1; }
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist")" == "$IDENTIFIER" ]] || { print -u2 "应用标识不符：$1"; return 1; }
  codesign --verify --strict "$1"
}
unregister_exact() {
  validate "$1" || return 1
  python3 "$SAFETY" unregister-exact --app "$1" --baseline "$INSTALL_RECORD/before.json" \
    --record "$INSTALL_RECORD/unregistration.jsonl" >> "$INSTALL_RECORD/registration.log" 2>&1
}
retire_old_program() {
  if [[ -e "$OLD_APP" || -L "$OLD_APP" ]]; then
    [[ -n "$OLD_IDENTITY" ]] || return 1
    python3 "$SAFETY" identity --app "$OLD_APP" --expected "$OLD_IDENTITY" || return 1
    python3 "$SAFETY" unregister-exact --app "$OLD_APP" --baseline "$INSTALL_RECORD/before.json" \
      --record "$INSTALL_RECORD/unregistration.jsonl" --expected-identity "$OLD_IDENTITY" >> "$INSTALL_RECORD/registration.log" 2>&1 || return 1
    rm -rf "$OLD_APP" || return 1
  fi
}
retire_staged_program() {
  $STAGED_RETIRED && return 0
  if [[ -e "$NEW_APP" || -L "$NEW_APP" ]]; then
    [[ -n "$NEW_IDENTITY" ]] || return 1
    python3 "$SAFETY" unregister-exact --app "$NEW_APP" --baseline "$INSTALL_RECORD/before.json" \
      --record "$INSTALL_RECORD/unregistration.jsonl" --expected-identity "$NEW_IDENTITY" >> "$INSTALL_RECORD/registration.log" 2>&1 || return 1
    python3 "$SAFETY" identity --app "$NEW_APP" --expected "$NEW_IDENTITY" || return 1
    rm -rf "$NEW_APP" || return 1
  elif [[ -n "$STAGED_RECEIPT_SHA" ]]; then
    python3 "$SAFETY" unregister-staged-source --receipt "$STAGED_RECEIPT" --receipt-sha256 "$STAGED_RECEIPT_SHA" \
      --moved-to "$DESTINATION" --expected-identity "$NEW_IDENTITY" --baseline "$INSTALL_RECORD/before.json" \
      --record "$INSTALL_RECORD/unregistration.jsonl" >> "$INSTALL_RECORD/registration.log" 2>&1 || return 1
  fi
  STAGED_RETIRED=true
}
register_destination() {
  validate "$DESTINATION" || return 1
  "$LSREGISTER" -f "$DESTINATION" >> "$INSTALL_RECORD/registration.log" 2>&1
}
stop_product() {
  python3 "$SAFETY" stop-program
}
detach_source() {
  if $MOUNT_ATTACHED; then
    local unregister_result=0
    if $SOURCE_VALIDATED; then unregister_exact "$SOURCE" || unregister_result=1; fi
    if ! hdiutil detach -quiet "$MOUNT"; then
      print -u2 "安装镜像未能卸载，唯一入口收尾未完成；保留 .noindex 工作目录：$WORK"
      KEEP_WORK=true
      return 1
    fi
    MOUNT_ATTACHED=false
    (( unregister_result == 0 )) || KEEP_WORK=true
    return "$unregister_result"
  fi
}
finish() {
  local result=$?
  trap '' INT TERM HUP
  trap - EXIT
  detach_source || result=1
  if $INSTALL_VERIFIED && ! $KEEP_WORK; then
    retire_staged_program || { KEEP_WORK=true; result=1; }
    retire_old_program || { KEEP_WORK=true; result=1; }
  fi
  if $KEEP_WORK || { $REPLACEMENT_STARTED && ! $INSTALL_VERIFIED; }; then
    print -u2 "安装未完成，已停止且未自动回滚；现场保留在：$WORK"
  else
    rm -rf "$WORK" || { result=1; print -u2 "工作目录未能清理，仍需精确收尾：$WORK"; }
  fi
  exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

mkdir -p "$MOUNT" "${NEW_APP:h}" "${OLD_APP:h}"
python3 "$SAFETY" audit --project "$PROJECT_DIR" --output "$INSTALL_RECORD/before.json"
MOUNT_ATTACHED=true
hdiutil attach -quiet -nobrowse -mountpoint "$MOUNT" "$PACKAGE"
validate "$SOURCE" || exit 1
SOURCE_VALIDATED=true
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE/Contents/Info.plist")" == "$APP_VERSION" ]] || exit 1
if [[ -e "$DESTINATION" ]]; then validate "$DESTINATION" || exit 1; fi
ditto "$SOURCE" "$NEW_APP"
validate "$NEW_APP" || exit 1
NEW_IDENTITY="$(python3 "$SAFETY" identity --app "$NEW_APP")"
STAGED_RECEIPT_SHA="$(python3 "$SAFETY" record-staged --app "$NEW_APP" --work "$WORK" \
  --install-record "$INSTALL_RECORD" --expected-identity "$NEW_IDENTITY")"
detach_source || exit 1
stop_product || exit 1
python3 "$SAFETY" record-user-data --output "$INSTALL_RECORD/user-data-before.json"
if [[ -e "$DESTINATION" ]]; then
  OLD_IDENTITY="$(python3 "$SAFETY" identity --app "$DESTINATION")"
  REPLACEMENT_STARTED=true
  python3 "$SAFETY" move-app --app "$DESTINATION" --output "$OLD_APP" --expected-identity "$OLD_IDENTITY"
else
  REPLACEMENT_STARTED=true
fi
python3 "$SAFETY" move-app --app "$NEW_APP" --output "$DESTINATION" --expected-identity "$NEW_IDENTITY"
validate "$DESTINATION" || exit 1
if $RUN_SMOKE; then
  open "$DESTINATION" || exit 1
  sleep 2
  python3 "$SAFETY" running-program || exit 1
fi
python3 "$SAFETY" verify-user-data --baseline "$INSTALL_RECORD/user-data-before.json"
register_destination || exit 1
INSTALL_VERIFIED=true
retire_staged_program || { KEEP_WORK=true; print -u2 '新版历史暂存路径登记尚未清除，保留现场。'; exit 3; }
retire_old_program || { KEEP_WORK=true; print -u2 '旧程序登记或清理尚未完成，保留现场。'; exit 3; }
python3 "$SAFETY" audit --project "$PROJECT_DIR" --output "$INSTALL_RECORD/after.json" --final || {
  KEEP_WORK=true
  print -u2 '新版程序与资料已核验，唯一入口收尾未完成；未清理旧安装包。'
  exit 3
}
if ! $DEFER_CLEANUP; then
  find "$PROJECT_DIR/Release" -maxdepth 1 -type f \( -name 'GaoJiLing-*.dmg' -o -name 'GaoJiLing-*.dmg.sha256' -o -name 'GaoJiLing-*-source.zip' -o -name 'GaoJiLing-*-source.zip.sha256' \) \
    ! -name "GaoJiLing-$APP_VERSION.dmg" ! -name "GaoJiLing-$APP_VERSION.dmg.sha256" \
    ! -name "GaoJiLing-$APP_VERSION-source.zip" ! -name "GaoJiLing-$APP_VERSION-source.zip.sha256" -delete
fi
print "搞机灵 V$APP_VERSION 已安装；资料与偏好保持不变，唯一入口核验通过，未创建任何自动备份。"
if ! $RUN_SMOKE; then print '未自动启动或运行通用冒烟；主要业务由定向测试与静态安装核验覆盖。'; fi
