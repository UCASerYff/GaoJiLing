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
PROGRAM_FORMAT=''
OLD_IDENTITY=''
NEW_IDENTITY=''
STAGED_RECEIPT_SHA=''
STAGED_RETIRED=false
AUDIT_KNOWN=()
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
STAGED_RECEIPT="$INSTALL_RECORD/staged-new.json"
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
  if [[ "$PROGRAM_FORMAT" == 2 ]]; then
    # Absence or replacement of the authority is a failure, never a no-op.
    [[ -n "$PROGRAM_RECEIPT" ]] || return 1
    local authority
    authority="$(python3 "$SAFETY" original-path --receipt "$PROGRAM_RECEIPT")" || return 1
    [[ "$OLD_APP" == "$authority" ]] || return 1
    python3 "$SAFETY" verify --receipt "$PROGRAM_RECEIPT" --app "$OLD_APP" || return 1
    unregister_exact "$OLD_APP" || return 1
    return 0
  fi
  if [[ -e "$OLD_APP" || -L "$OLD_APP" ]]; then
    [[ -n "$PROGRAM_RECEIPT" ]] || return 1
    python3 "$SAFETY" verify --receipt "$PROGRAM_RECEIPT" --app "$OLD_APP" || return 1
    # LS may follow the old inode to this path after the official path was
    # unregistered. Remove that moved-path record while its program still exists.
    unregister_exact "$OLD_APP" || return 1
    # Format 2 retains the same original inode as the authoritative backup.
    # Only a full round-trip ZIP (format 1) permits deleting this WORK copy.
    if [[ "$PROGRAM_FORMAT" != 2 ]]; then rm -rf "$OLD_APP" || return 1; fi
  fi
}
retire_failed_program() {
  if [[ -e "$FAILED_APP" || -L "$FAILED_APP" ]]; then
    [[ -n "$NEW_IDENTITY" ]] || return 1
    # This is the already pinned new inode, which may have damaged Info/signing.
    # Restore/register the old official program before checking the LS anchors.
    python3 "$SAFETY" unregister-exact --app "$FAILED_APP" --baseline "$INSTALL_RECORD/before.json" \
      --record "$INSTALL_RECORD/unregistration.jsonl" --expected-identity "$NEW_IDENTITY" >> "$INSTALL_RECORD/registration.log" 2>&1 || return 1
    python3 "$SAFETY" identity --app "$FAILED_APP" --expected "$NEW_IDENTITY" || return 1
    rm -rf "$FAILED_APP" || return 1
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
    local current_new="$DESTINATION"
    if [[ -e "$FAILED_APP" || -L "$FAILED_APP" ]]; then current_new="$FAILED_APP"; fi
    # The source is absent, but LS can retain its original path. Only the
    # durable run-bound proof and the same new inode at an approved location
    # allow exact removal of that single historical staging registration.
    python3 "$SAFETY" unregister-staged-source --receipt "$STAGED_RECEIPT" --receipt-sha256 "$STAGED_RECEIPT_SHA" \
      --moved-to "$current_new" --expected-identity "$NEW_IDENTITY" --baseline "$INSTALL_RECORD/before.json" \
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
rollback() {
  stop_product || { KEEP_WORK=true; return 1; }
  # The transaction starts before the first rename. If that rename never
  # happened, the verified original is still official: do not move it away.
  if [[ -n "$PROGRAM_RECEIPT" && ! -e "$OLD_APP" && ! -L "$OLD_APP" && -e "$DESTINATION" && -e "$NEW_APP" ]]; then
    python3 "$SAFETY" verify --receipt "$PROGRAM_RECEIPT" --app "$DESTINATION" || { KEEP_WORK=true; return 1; }
    if [[ "$PROGRAM_FORMAT" == 2 ]]; then
      python3 "$SAFETY" restore-original --receipt "$PROGRAM_RECEIPT" || { KEEP_WORK=true; return 1; }
    fi
    TRANSACTION_ACTIVE=false
    print -r -- 'Original program remained installed and was fully reverified. No user data/Keychain changes.' > "$INSTALL_RECORD/ROLLBACK"
    register_destination || { KEEP_WORK=true; return 1; }
    return 0
  fi
  # Verify the recovery source before moving the currently installed program.
  if [[ -n "$PROGRAM_RECEIPT" ]]; then
    if [[ ! -e "$OLD_APP" && ! -L "$OLD_APP" ]]; then
      if [[ "$PROGRAM_FORMAT" == 2 ]]; then
        print -u2 '权威原件不在已记录位置，禁止从辅助 ZIP 降级恢复；保留现场。'
        KEEP_WORK=true
        return 1
      fi
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
    python3 "$SAFETY" move-app --app "$DESTINATION" --output "$FAILED_APP" --expected-identity "$NEW_IDENTITY" || { KEEP_WORK=true; return 1; }
  fi
  if [[ -n "$PROGRAM_RECEIPT" ]]; then
    # A registry error cannot prevent the verified original returning to its
    # official path. Preserve the registration evidence for precise follow-up.
    unregister_exact "$OLD_APP" || print -u2 '原件备份路径注销失败，继续恢复文件并保留登记证据。'
    if [[ "$PROGRAM_FORMAT" == 2 ]]; then
      python3 "$SAFETY" restore-original --receipt "$PROGRAM_RECEIPT" || { KEEP_WORK=true; return 1; }
    else
      local recovery_identity
      recovery_identity="$(python3 "$SAFETY" identity --app "$OLD_APP")" || { KEEP_WORK=true; return 1; }
      python3 "$SAFETY" move-app --app "$OLD_APP" --output "$DESTINATION" --expected-identity "$recovery_identity" || { KEEP_WORK=true; return 1; }
    fi
    python3 "$SAFETY" verify --receipt "$PROGRAM_RECEIPT" --app "$DESTINATION" || { KEEP_WORK=true; return 1; }
    validate "$DESTINATION" || { KEEP_WORK=true; return 1; }
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
  if ! $KEEP_WORK && { [[ -e "$OLD_APP" || -L "$OLD_APP" ]] || { $INSTALL_VERIFIED && [[ "$PROGRAM_FORMAT" == 2 ]]; }; }; then
    if $INSTALL_VERIFIED; then
      retire_old_program || { KEEP_WORK=true; result=1; }
    else
      KEEP_WORK=true
      result=1
    fi
  fi
  if ! $KEEP_WORK; then
    retire_staged_program || { KEEP_WORK=true; result=1; }
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
    python3 "$SAFETY" audit --project "$PROJECT_DIR" --output "$INSTALL_RECORD/finish.json" "${audit_extra[@]}" "${AUDIT_KNOWN[@]}" || result=1
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
STAGED_RECEIPT_SHA="$(python3 "$SAFETY" record-staged --app "$NEW_APP" --work "$WORK" \
  --install-record "$INSTALL_RECORD" --expected-identity "$NEW_IDENTITY")"
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
  PROGRAM_FORMAT="$(python3 "$SAFETY" receipt-format --receipt "$PROGRAM_RECEIPT")"
  if [[ "$PROGRAM_FORMAT" == 2 ]]; then
    [[ -f "${PROGRAM_RECEIPT:h}/PREPARED.json" ]] || { print -u2 '原件回滚计划未持久准备，未替换旧程序'; exit 1; }
    OLD_APP="$(python3 "$SAFETY" original-path --receipt "$PROGRAM_RECEIPT")"
    [[ "$OLD_APP" != "$WORK/"* ]] || { print -u2 '权威原件不能位于临时工作目录'; exit 1; }
    AUDIT_KNOWN=(--known-path "$OLD_APP")
  elif [[ "$PROGRAM_FORMAT" == 1 ]]; then
    [[ -f "${PROGRAM_RECEIPT:h}/VERIFIED" ]] || { print -u2 '程序回滚包尚未完整解包核验，未替换旧程序'; exit 1; }
  else
    print -u2 '不支持的程序回滚格式，未替换旧程序'; exit 1
  fi
  OLD_IDENTITY="$(python3 "$SAFETY" identity --app "$DESTINATION")"
  print -r -- "$PROGRAM_RECEIPT" > "$INSTALL_RECORD/program-rollback-receipt.path"
  # Persist an exact recovery pointer before enabling the transaction and any
  # command that can rename the original. The archive command never moves it.
  python3 "$SAFETY" record-plan --receipt "$PROGRAM_RECEIPT" --original-path "$OLD_APP" --record "$INSTALL_RECORD/program-rollback-plan.json"
  TRANSACTION_ACTIVE=true
  # The existing official registration is valid while the original is still
  # there and may be rediscovered. Preserve the original inode first; after
  # new registration, retire only its exact moved backup location.
  if [[ "$PROGRAM_FORMAT" == 2 ]]; then
    python3 "$SAFETY" preserve-original --receipt "$PROGRAM_RECEIPT" --app "$DESTINATION"
    [[ -f "${PROGRAM_RECEIPT:h}/VERIFIED" ]] || exit 1
    python3 "$SAFETY" verify --receipt "$PROGRAM_RECEIPT" --app "$OLD_APP"
  else
    python3 "$SAFETY" move-app --app "$DESTINATION" --output "$OLD_APP" --expected-identity "$OLD_IDENTITY"
  fi
fi
TRANSACTION_ACTIVE=true
python3 "$SAFETY" move-app --app "$NEW_APP" --output "$DESTINATION" --expected-identity "$NEW_IDENTITY"
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
retire_staged_program || { KEEP_WORK=true; print -u2 '新版历史暂存路径登记尚未清除，保留现场；未删除工作目录或权威回滚原件。'; exit 3; }
retire_old_program || { KEEP_WORK=true; print -u2 '移动后的旧程序登记尚未清除，保留 .noindex 现场与回滚包；唯一入口收尾未完成。'; exit 3; }
# Finish temporary cleanup before the final observation, including static or
# deferred GUI acceptance. Rollback authority and receipts remain private.
rm -rf "$WORK"
if ! python3 "$SAFETY" audit --project "$PROJECT_DIR" --output "$INSTALL_RECORD/after.json" --final "${AUDIT_KNOWN[@]}"; then
  print -u2 '新版程序与原资料已核验保留；Spotlight/LaunchServices 唯一入口收尾未完成，未清理旧安装包。权威程序回滚备份与完整安全备份保留。'
  exit 3
fi
if $RUN_SMOKE && ! $DEFER_CLEANUP; then
  find "$PROJECT_DIR/Release" -maxdepth 1 -type f \( -name 'GaoJiLing-*.dmg' -o -name 'GaoJiLing-*.dmg.sha256' \) ! -name "GaoJiLing-$APP_VERSION.dmg" ! -name "GaoJiLing-$APP_VERSION.dmg.sha256" -delete
  print "已安装搞机灵 V$APP_VERSION；唯一入口核验通过，旧安装包已精确清理，权威程序回滚备份与资料备份保留。"
else
  print "搞机灵 V$APP_VERSION 已安装，签名、资料保留与唯一入口核验通过；程序回滚方式 $PROGRAM_FORMAT 的权威备份保留于私有容器。"
  if ! $RUN_SMOKE; then print '未自动启动或运行冒烟；主要业务待本人验收，旧安装包暂留。'; fi
fi
