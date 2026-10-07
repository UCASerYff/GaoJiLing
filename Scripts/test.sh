#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_TEMP="$(mktemp -d /private/tmp/gaojiling-tests.XXXXXX)"
trap 'rm -rf "$TEST_TEMP"' EXIT
export CLANG_MODULE_CACHE_PATH="$TEST_TEMP/module-cache"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -swift-version 5 -sdk "$SDK" -module-cache-path "$TEST_TEMP/module-cache" \
  "$PROJECT_DIR/Sources/Models.swift" "$PROJECT_DIR/Sources/Storage.swift" \
  "$PROJECT_DIR/Tests/StoreTests.swift" -lsqlite3 -o "$TEST_TEMP/StoreTests"
"$TEST_TEMP/StoreTests" "$TEST_TEMP/databases"
swiftc -swift-version 5 -sdk "$SDK" -module-cache-path "$TEST_TEMP/module-cache" \
  "$PROJECT_DIR/Sources/Models.swift" "$PROJECT_DIR/Sources/DataExport.swift" \
  "$PROJECT_DIR/Tests/ExportTests.swift" -o "$TEST_TEMP/ExportTests"
"$TEST_TEMP/ExportTests"
mkdir -p "$TEST_TEMP/version-fixture/Scripts"
cp "$PROJECT_DIR/Scripts/bump-version.py" "$TEST_TEMP/version-fixture/Scripts/bump-version.py"
for CASE in '1.00:1.01' '1.09:1.10' '1.99:2.00'; do
  BEFORE="${CASE%%:*}"
  EXPECTED="${CASE##*:}"
  print -r -- "$BEFORE" > "$TEST_TEMP/version-fixture/VERSION"
  python3 "$TEST_TEMP/version-fixture/Scripts/bump-version.py"
  ACTUAL="$(tr -d '\n' < "$TEST_TEMP/version-fixture/VERSION")"
  [[ "$ACTUAL" == "$EXPECTED" ]] || { print -u2 "FAIL: version $BEFORE expected $EXPECTED, received $ACTUAL"; exit 1; }
  print "PASS: version $BEFORE → $EXPECTED"
done
print -r -- '1.9' > "$TEST_TEMP/version-fixture/VERSION"
if python3 "$TEST_TEMP/version-fixture/Scripts/bump-version.py" >/dev/null 2>&1; then
  print -u2 'FAIL: invalid version 1.9 was accepted'; exit 1
fi
[[ "$(tr -d '\n' < "$TEST_TEMP/version-fixture/VERSION")" == '1.9' ]] || { print -u2 'FAIL: invalid version was modified'; exit 1; }
print 'PASS: invalid version is rejected without modifying the file'
xcrun clang -O2 -Wall -Wextra -isysroot "$SDK" \
  -c "$PROJECT_DIR/Sources/NativeMetrics.c" -o "$TEST_TEMP/NativeMetrics.o"
swiftc -O -swift-version 5 -sdk "$SDK" -module-cache-path "$TEST_TEMP/module-cache" \
  -import-objc-header "$PROJECT_DIR/Sources/NativeMetrics.h" \
  "$PROJECT_DIR/Sources/Models.swift" "$PROJECT_DIR/Sources/MetricsCollector.swift" \
  "$PROJECT_DIR/Sources/Sensors.swift" "$PROJECT_DIR/Tests/MetricsTests.swift" \
  "$TEST_TEMP/NativeMetrics.o" -framework IOKit -framework CoreFoundation \
  -o "$TEST_TEMP/MetricsTests"
# Inherit GJL_REQUIRE_LIVE only when the caller explicitly enables live assertions.
"$TEST_TEMP/MetricsTests"
print '全部测试通过；测试数据库、可执行文件和缓存将在退出时清理。'
