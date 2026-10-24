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
UPGRADE_BACKUP=''
PROGRAM_RECEIPT=''
NEW_IDENTITY=''
DEFER_CLEANUP=false
RUN_SMOKE=false
BACKUP_EXTRA=()
while (( $# )); do
  case "$1" in
    --defer-cleanup) DEFER_CLEANUP=true ;;
    --smoke-test) RUN_SMOKE=true ;;
    --no-launch) RUN_SMOKE=false; DEFER_CLEANUP=true ;;
    --confirmed-missing-cleanup)
      (( $# >= 2 )) || { print -u2 '缺少本人确认的旧清理记录清单路径'; exit 1; }
      BACKUP_EXTRA=(--confirmed-missing-cleanup "$2"); shift ;;
    *) print -u2 '参数仅支持 --no-launch、--defer-cleanup、--confirmed-missing-cleanup 路径或本人明确要求的 --smoke-test'; exit 1 ;;
  esac
  shift
done
LSREGISTER='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
[[ -x "$LSREGISTER" ]] || { print -u2 'LaunchServices 工具不可用，无法核验唯一入口；未安装'; exit 1; }
[[ -f "$PACKAGE" ]] || { print -u2 '缺少当前版本安装包，请先构建'; exit 1; }
(cd "$PROJECT_DIR/Release" && shasum -a 256 -c "GaoJiLing-$APP_VERSION.dmg.sha256")
INSTALL_RECORD="$(python3 "$SAFETY" recorddir --parent "$HOME/Library/Application Support/GaoSeries/GaoJiLing-Backups" --prefix "Install-V$APP_VERSION-")"
WORK="$(python3 "$SAFETY" workdir --parent /Applications --prefix .GaoJiLing-install-)"
MOUNT="$WORK/Mount.noindex"
SOURCE="$MOUNT/搞机灵.app"
NEW_APP="$WORK/New.noindex/搞机灵.app"
OLD_APP="$WORK/Old.noindex/搞机灵.app"
FAILED_APP="$WORK/Failed.noindex/搞机灵.app"
MOUNT_ATTACHED=false
SOURCE_VALIDATED=false
TRANSACTION_ACTIVE=false
INSTALL_VERIFIED=false
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
    [[ -n "$PROGRAM_RECEIPT" ]] || return 1
    python3 "$SAFETY" verify --receipt "$PROGRAM_RECEIPT" --app "$OLD_APP" || return 1
    # LS may follow the old inode to this path after the official path was
    # unregistered. Remove that moved-path record while its program still exists.
    unregister_exact "$OLD_APP" || return 1
    rm -rf "$OLD_APP" || return 1
  fi
}
retire_failed_program() {
  if [[ -e "$FAILED_APP" || -L "$FAILED_APP" ]]; then
    [[ -n "$NEW_IDENTITY" ]] || return 1
    # This is the already pinned new inode, which may have damaged Info/signing.
    # Restore/register the old official program before checking the LS anchors.
    python3 "$SAFETY" unregister-exact --app "$FAILED_APP" --baseline "$INSTALL_RECORD/before.json" \
      --record "$INSTALL_RECORD/unregistration.jsonl" --expected-identity "$NEW_IDENTITY" >> "$INSTALL_RECORD/registration.log" 2>&1 || return 1
    rm -rf "$FAILED_APP" || return 1
  fi
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
rollback() {
  stop_product || { KEEP_WORK=true; return 1; }
  # The transaction starts before the first rename. If that rename never
  # happened, the verified original is still official: do not move it away.
  if [[ -n "$PROGRAM_RECEIPT" && ! -e "$OLD_APP" && -e "$DESTINATION" && -e "$NEW_APP" ]]; then
    python3 "$SAFETY" verify --receipt "$PROGRAM_RECEIPT" --app "$DESTINATION" || { KEEP_WORK=true; return 1; }
    register_destination || { KEEP_WORK=true; return 1; }
    TRANSACTION_ACTIVE=false
    print -r -- 'Original program remained installed; exact registration restored. No user data/Keychain changes.' > "$INSTALL_RECORD/ROLLBACK"
    return 0
  fi
  # Verify the recovery source before moving the currently installed program.
  if [[ -n "$PROGRAM_RECEIPT" ]]; then
    if [[ ! -e "$OLD_APP" ]]; then
      python3 "$SAFETY" extract --receipt "$PROGRAM_RECEIPT" --output "$OLD_APP" || { KEEP_WORK=true; return 1; }
    fi
    python3 "$SAFETY" verify --receipt "$PROGRAM_RECEIPT" --app "$OLD_APP" || { KEEP_WORK=true; return 1; }
    validate "$OLD_APP" || { KEEP_WORK=true; return 1; }
  fi
  if [[ -e "$DESTINATION" || -L "$DESTINATION" ]]; then
    # A damaged new signature is a reason to roll back. The pinned identity,
    # captured after staging validation, prevents moving an unrelated program.
    python3 "$SAFETY" identity --app "$DESTINATION" --expected "$NEW_IDENTITY" || { KEEP_WORK=true; return 1; }
    python3 "$SAFETY" unregister-exact --app "$DESTINATION" --baseline "$INSTALL_RECORD/before.json" \
      --record "$INSTALL_RECORD/unregistration.jsonl" --expected-identity "$NEW_IDENTITY" >> "$INSTALL_RECORD/registration.log" 2>&1 || print -u2 '新版精确注销失败，恢复后须核对登记证据。'
    mkdir -p "$WORK/Failed.noindex"
    mv "$DESTINATION" "$FAILED_APP" || { KEEP_WORK=true; return 1; }
  fi
  if [[ -n "$PROGRAM_RECEIPT" ]]; then
    mv "$OLD_APP" "$DESTINATION" || { KEEP_WORK=true; return 1; }
    TRANSACTION_ACTIVE=false
    print -r -- 'Previous program restored; user data and Keychain were not restored or changed.' > "$INSTALL_RECORD/ROLLBACK"
    register_destination || { KEEP_WORK=true; print -u2 '旧程序已恢复，系统登记仍未完成；请按私有记录精确核对。'; return 1; }
    if $RUN_SMOKE && [[ "${1:-}" != '--keep-stopped' ]]; then open "$DESTINATION" || return 1; fi
  fi
  TRANSACTION_ACTIVE=false
  print -r -- 'Program rollback completed; user data and Keychain were not restored or changed.' > "$INSTALL_RECORD/ROLLBACK"
}
finish() {
  local result=$?
  # A second ordinary termination request must not interrupt restoration after
  # the official path has been moved. SIGKILL/power loss still require receipt
  # based manual recovery; they cannot be trapped by an installer.
  trap '' INT TERM HUP
  trap - EXIT
  if $TRANSACTION_ACTIVE && ! $INSTALL_VERIFIED; then
    rollback --keep-stopped || result=1
  fi
  detach_source || result=1
  if ! $KEEP_WORK && [[ -e "$OLD_APP" || -L "$OLD_APP" ]]; then
    if $INSTALL_VERIFIED; then
      retire_old_program || { KEEP_WORK=true; result=1; }
    else
      KEEP_WORK=true
      result=1
    fi
  fi
  if ! $KEEP_WORK; then
    retire_failed_program || { KEEP_WORK=true; result=1; }
  fi
  if $KEEP_WORK; then
    print -u2 "未完成步骤保存在 .noindex 中：$WORK；回滚包与安全备份没有删除。"
  else
    rm -rf "$WORK" || { KEEP_WORK=true; result=1; print -u2 "工作目录未能清理，仍需精确收尾：$WORK"; }
  fi
  if [[ ! -e "$INSTALL_RECORD/after.json" ]]; then
    local audit_extra=()
    [[ ! -e "$DESTINATION" ]] || audit_extra=(--final)
    python3 "$SAFETY" audit --project "$PROJECT_DIR" --output "$INSTALL_RECORD/finish.json" "${audit_extra[@]}" || result=1
  fi
  print "私有安装/唯一入口记录：$INSTALL_RECORD"
  exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Unknown historical copies and stale registrations are evidence to resolve,
# never permission to delete a backup or reset the global registry.
python3 "$SAFETY" audit --project "$PROJECT_DIR" --output "$INSTALL_RECORD/before.json"
mkdir -p "$MOUNT" "${NEW_APP:h}" "${OLD_APP:h}"
MOUNT_ATTACHED=true
hdiutil attach -quiet -nobrowse -mountpoint "$MOUNT" "$PACKAGE"
validate "$SOURCE" || exit 1
SOURCE_VALIDATED=true
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE/Contents/Info.plist")" == "$APP_VERSION" ]] || exit 1
if [[ -e "$DESTINATION" ]]; then validate "$DESTINATION" || exit 1; fi
ditto "$SOURCE" "$NEW_APP"
validate "$NEW_APP" || exit 1
NEW_IDENTITY="$(python3 "$SAFETY" identity --app "$NEW_APP")"
detach_source || exit 1
stop_product || exit 1
if [[ -e "$DESTINATION" || -d "$HOME/Library/Application Support/GaoSeries/GaoJiLing" ]]; then
  PREVIOUS_VERSION="$APP_VERSION"
  [[ ! -e "$DESTINATION" ]] || PREVIOUS_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DESTINATION/Contents/Info.plist")"
  UPGRADE_BACKUP="$(python3 "$PROJECT_DIR/Scripts/backup-data.py" --from-version "$PREVIOUS_VERSION" --to-version "$APP_VERSION" "${BACKUP_EXTRA[@]}")"
  [[ -f "$UPGRADE_BACKUP/VERIFIED" ]] || { print -u2 '安全备份未通过核验，未替换旧程序'; exit 1; }
  print -r -- "$UPGRADE_BACKUP" > "$INSTALL_RECORD/user-data-backup.path"
  print "已核验并保留更新前安全备份：$UPGRADE_BACKUP"
fi
if [[ -e "$DESTINATION" ]]; then
  PROGRAM_RECEIPT="$(python3 "$SAFETY" archive --app "$DESTINATION" --directory "$UPGRADE_BACKUP/ProgramRollback")"
  [[ -f "${PROGRAM_RECEIPT:h}/VERIFIED" ]] || { print -u2 '程序回滚包尚未解包核验，未替换旧程序'; exit 1; }
  print -r -- "$PROGRAM_RECEIPT" > "$INSTALL_RECORD/program-rollback-receipt.path"
  TRANSACTION_ACTIVE=true
  unregister_exact "$DESTINATION" || exit 1
  mv "$DESTINATION" "$OLD_APP"
fi
TRANSACTION_ACTIVE=true
mv "$NEW_APP" "$DESTINATION"
validate "$DESTINATION" || exit 1
if $RUN_SMOKE; then
  if ! open "$DESTINATION"; then print -u2 '新版启动请求失败，恢复上一版。'; exit 1; fi
  sleep 2
  if ! python3 "$SAFETY" running-program; then print -u2 '正式路径的新版未正常启动，恢复上一版。'; exit 1; fi
fi
if [[ -n "$UPGRADE_BACKUP" ]] && ! python3 "$PROJECT_DIR/Scripts/backup-data.py" --verify "$UPGRADE_BACKUP" "${BACKUP_EXTRA[@]}"; then
  print -u2 '升级后资料核验失败，将恢复旧程序；原资料与安全备份保留。'
  exit 1
fi
register_destination || exit 1
INSTALL_VERIFIED=true
retire_old_program || { KEEP_WORK=true; print -u2 '移动后的旧程序登记尚未清除，保留 .noindex 现场与回滚包；唯一入口收尾未完成。'; exit 3; }
# Finish temporary cleanup before the final observation, including static or
# deferred GUI acceptance. The rollback ZIP and receipts remain private.
rm -rf "$WORK"
if ! python3 "$SAFETY" audit --project "$PROJECT_DIR" --output "$INSTALL_RECORD/after.json" --final; then
  print -u2 '新版程序与原资料已核验保留；Spotlight/LaunchServices 唯一入口收尾未完成，未清理旧安装包。压缩回滚包与完整安全备份保留。'
  exit 3
fi
if $RUN_SMOKE && ! $DEFER_CLEANUP; then
  find "$PROJECT_DIR/Release" -maxdepth 1 -type f \( -name 'GaoJiLing-*.dmg' -o -name 'GaoJiLing-*.dmg.sha256' \) ! -name "GaoJiLing-$APP_VERSION.dmg" ! -name "GaoJiLing-$APP_VERSION.dmg.sha256" -delete
  print "已安装搞机灵 V$APP_VERSION；唯一入口核验通过，旧安装包已精确清理，压缩回滚包与资料备份保留。"
else
  print "搞机灵 V$APP_VERSION 已安装，签名、资料保留与唯一入口核验通过；程序回滚包已压缩保存，未遗留展开旧程序。"
  if ! $RUN_SMOKE; then print '未自动启动或运行冒烟；主要业务待本人验收，旧安装包暂留。'; fi
fi
