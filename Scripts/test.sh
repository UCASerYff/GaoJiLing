#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-}"
if (( $# > 1 )) || [[ -n "$MODE" && "$MODE" != --session-comparison && "$MODE" != --network-diagnostics ]]; then
  print -u2 '使用 test.sh、test.sh --session-comparison 或 test.sh --network-diagnostics'
  exit 1
fi
TEST_TEMP="$(python3 -c 'import tempfile; print(tempfile.mkdtemp(prefix="gaojiling-tests-", suffix=".noindex", dir="/private/tmp"))')"
trap 'rm -rf "$TEST_TEMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export CLANG_MODULE_CACHE_PATH="$TEST_TEMP/module-cache"
export PYTHONDONTWRITEBYTECODE=1
# A stale caller environment must never start applications or move real files.
# GUI/native acceptance is a separate, explicitly requested manual operation.
unset GJL_RUN_APP_EXIT_PROTOTYPE GJL_RUN_UNINSTALL_NATIVE GJL_REQUIRE_LIVE
SDK="$(xcrun --sdk macosx --show-sdk-path)"
cd "$PROJECT_DIR"
# Keep Swift assertions enabled; several regression executables use assert.
SWIFT=(swiftc -swift-version 5 -Onone -sdk "$SDK" -module-cache-path "$TEST_TEMP/module-cache")
NATIVE=(-import-objc-header Sources/NativeMetrics.h "$TEST_TEMP/NativeMetrics.o" -framework IOKit -framework CoreFoundation)
HEADER=(-import-objc-header Sources/NativeMetrics.h)
METRICS=(Sources/Models.swift Sources/MetricsCollector.swift Sources/Sensors.swift)
STORE=(Sources/Models.swift Sources/SessionComparison.swift Sources/Storage.swift)
STORAGE=(Sources/StorageAnalysis.swift Sources/StorageTree.swift)
UNINSTALL=(Sources/UninstallFileSafety.swift Sources/UninstallEngine.swift)
DUPLICATES=(Sources/DuplicateAnalysis.swift Sources/DuplicateRecovery.swift Sources/DuplicateAnalysisController.swift)
MAINTENANCE=(Sources/Models.swift Sources/AppExitRules.swift Sources/BatteryCapabilities.swift Sources/MaintenanceMetricsState.swift)
EXCHANGE_TEST=(Sources/GaoActionV1.swift Sources/GaoActionExchange.swift Tests/GaoActionFixtures.swift -framework AppKit -framework Security)
TEST_SUITES=0

run_swift_test() {
  local test_name="$1"
  shift
  "${SWIFT[@]}" "$@" "Tests/$test_name.swift" -o "$TEST_TEMP/$test_name"
  if [[ "$test_name" == MetricsTests ]]; then
    # Legacy read-only metrics checks print the local process names. Keep those
    # diagnostics in this private, trap-cleaned folder, not in shareable output.
    if "$TEST_TEMP/$test_name" > "$TEST_TEMP/metrics.log" 2>&1; then
      awk '/^(PASS:|SKIP:)/' "$TEST_TEMP/metrics.log"
    else
      awk '/^(FAIL:|Assertion failed:|Fatal error:)/' "$TEST_TEMP/metrics.log"
      print -u2 'FAIL: MetricsTests（本轮私有诊断将在退出时清理）'
      return 1
    fi
  else
    "$TEST_TEMP/$test_name"
  fi
  ((++TEST_SUITES))
}

run_store_test() {
  local test_name="$1"
  "${SWIFT[@]}" "${STORE[@]}" "Tests/$test_name.swift" -lsqlite3 -o "$TEST_TEMP/$test_name"
  "$TEST_TEMP/$test_name" "$TEST_TEMP/$test_name.databases"
  ((++TEST_SUITES))
}

run_network_test() {
  "${SWIFT[@]}" Sources/Models.swift Sources/NetworkDiagnostics.swift Tests/NetworkDiagnosticsTests.swift -o "$TEST_TEMP/NetworkDiagnosticsTests"
  python3 Tests/network-diagnostics-fixture.py "$TEST_TEMP/NetworkDiagnosticsTests"
  ((++TEST_SUITES))
}

if [[ "$MODE" == --network-diagnostics ]]; then
  run_network_test
  exit 0
fi

python3 Tests/VersionTests.py
((++TEST_SUITES))
if [[ "$MODE" == --session-comparison ]]; then
  run_store_test StoreTests
  run_store_test SessionComparisonTests
  run_swift_test FloatingGeometryTests Sources/FloatingGeometry.swift
  run_swift_test PanelInteractionTests Sources/PanelInteraction.swift
  run_swift_test SamplingDemandTests Sources/SamplingDemand.swift
  run_swift_test GaoActionExchangeTests "${EXCHANGE_TEST[@]}"
  print "定向测试完成：$TEST_SUITES 个套件，使用合成数据和私有临时目录。"
  exit 0
fi

python3 Tests/AutomaticBackupRemovalTests.py
python3 Tests/CapabilitiesTests.py
python3 Scripts/test-release-safety.py
((TEST_SUITES += 3))
xcrun clang -O2 -Wall -Wextra -isysroot "$SDK" -c Sources/NativeMetrics.c -o "$TEST_TEMP/NativeMetrics.o"
mkdir -m 700 "$TEST_TEMP/native-process.noindex"
xcrun clang -O2 -Wall -Wextra -isysroot "$SDK" Tests/NativeProcessStateTests.c \
  -framework IOKit -framework CoreFoundation -o "$TEST_TEMP/native-process.noindex/NativeProcessStateTests"
"$TEST_TEMP/native-process.noindex/NativeProcessStateTests"
((++TEST_SUITES))
mkdir -m 700 "$TEST_TEMP/native-moved.noindex"
xcrun clang -O2 -Wall -Wextra -isysroot "$SDK" Tests/NativeMovedApplicationTests.c \
  -framework IOKit -framework CoreFoundation -o "$TEST_TEMP/native-moved.noindex/NativeMovedApplicationTests"
"$TEST_TEMP/native-moved.noindex/NativeMovedApplicationTests" "$TEST_TEMP/native-moved.noindex"
((++TEST_SUITES))

run_swift_test CleanupEngineTests Sources/CleanupEngine.swift
run_swift_test StorageAnalysisTests "${STORAGE[@]}" -framework AppKit
run_swift_test StorageAnalysisControllerTests "${STORAGE[@]}" Sources/StorageAnalysisController.swift Sources/Models.swift Sources/DataExport.swift -framework AppKit
run_swift_test StorageTreeTests "${STORAGE[@]}" -framework AppKit
run_swift_test DiskImageCoreTests Sources/DiskImageAnalysis.swift Sources/DiskImageNTFS.swift
run_swift_test LocalVolumeMetadataTests Sources/LocalVolumeMetadata.swift
run_swift_test DiskImageReportWriterTests Sources/DiskImageReportWriter.swift
run_swift_test DiskStorageControllerTests Sources/LocalVolumeMetadata.swift Sources/DiskImageAnalysis.swift \
  Sources/DiskImageNTFS.swift Sources/DiskImageReportWriter.swift Sources/DiskStorageController.swift -framework AppKit
run_swift_test FloatingGeometryTests Sources/FloatingGeometry.swift
run_swift_test PanelInteractionTests Sources/PanelInteraction.swift
run_swift_test SamplingDemandTests Sources/SamplingDemand.swift
run_swift_test DuplicateAnalysisTests Sources/DuplicateAnalysis.swift
run_swift_test DuplicateRecoveryTests Sources/DuplicateAnalysis.swift Sources/DuplicateRecovery.swift Sources/UninstallFileSafety.swift -framework AppKit
run_swift_test DuplicateAnalysisControllerTests "${DUPLICATES[@]}" Sources/UninstallFileSafety.swift -framework AppKit
run_store_test StoreTests
run_store_test SessionComparisonTests
run_swift_test ExportTests Sources/Models.swift Sources/DataExport.swift
run_network_test

run_swift_test UninstallEngineTests "${UNINSTALL[@]}" -framework AppKit
# This test supplies its own native process symbol. Do not link NativeMetrics.o.
run_swift_test UninstallControllerTests "${HEADER[@]}" "${UNINSTALL[@]}" Sources/AppManagementController.swift -framework AppKit
# Controlled CLI children and fixture Trash only; stdin EOF ends each child.
# This never launches an App, opens UI, or uses the real system Trash.
xcrun clang -O2 -Wall -Wextra -isysroot "$SDK" Tests/UninstallProcessFixture.c -o "$TEST_TEMP/UninstallProcessFixture"
"${SWIFT[@]}" "${NATIVE[@]}" "${UNINSTALL[@]}" Tests/UninstallMovedProcessTests.swift \
  -framework AppKit -o "$TEST_TEMP/UninstallMovedProcessTests"
"$TEST_TEMP/UninstallMovedProcessTests" "$TEST_TEMP/uninstall-moved-run.noindex" "$TEST_TEMP/UninstallProcessFixture"
((++TEST_SUITES))
run_swift_test UninstallNativeTests "${UNINSTALL[@]}" -framework AppKit
"${SWIFT[@]}" Sources/GaoActionV1.swift Tests/GaoActionTests.swift -framework Security -o "$TEST_TEMP/GaoActionTests"
"$TEST_TEMP/GaoActionTests" "$TEST_TEMP/gaoaction-fixtures"
((++TEST_SUITES))
run_swift_test GaoActionPackageTests Sources/GaoActionV1.swift Tests/GaoActionFixtures.swift -framework Security
run_swift_test GaoActionExchangeTests "${EXCHANGE_TEST[@]}"
# All native entry points here are fail-fast test stubs. Engine operations use
# private fixture homes and an injected Trash; NativeMetrics.o is forbidden.
run_swift_test GaoActionBusinessTests "${HEADER[@]}" \
  Sources/GaoActionV1.swift Sources/GaoActionExchange.swift Sources/GaoActionBusiness.swift \
  Sources/CleanupEngine.swift Sources/CleanupController.swift "${UNINSTALL[@]}" Sources/AppManagementController.swift \
  "${STORAGE[@]}" Sources/StorageAnalysisController.swift Sources/MemoryMaintenance.swift Sources/Models.swift Sources/DataExport.swift \
  "${DUPLICATES[@]}" \
  Tests/GaoActionFixtures.swift -framework AppKit -framework Security

run_swift_test MemoryMaintenanceTests "${NATIVE[@]}" Sources/MemoryMaintenance.swift
run_swift_test MetricsTests "${NATIVE[@]}" "${METRICS[@]}"
run_swift_test MaintenanceTests "${NATIVE[@]}" "${METRICS[@]}" Sources/BatteryCapabilities.swift Sources/FanCapabilities.swift Sources/AppExitRules.swift Sources/MaintenanceMetricsState.swift
run_swift_test AppExitControllerTests "${NATIVE[@]}" "${MAINTENANCE[@]}" Sources/AppExitRuntime.swift Sources/MaintenanceMetricsController.swift -framework AppKit -framework ApplicationServices -framework UserNotifications
run_swift_test AppExitRuntimeTests "${NATIVE[@]}" Sources/Models.swift Sources/AppExitRules.swift Sources/AppExitRuntime.swift -framework AppKit -framework ApplicationServices
# Keep the live read-only probe and self-created App GUI prototype opt-in.
# GJL_REQUIRE_LIVE=1 enables the former; GJL_RUN_APP_EXIT_PROTOTYPE=1 requires
# a separately coordinated GUI window and must never be set by this script.
run_swift_test MaintenanceNativeTests "${NATIVE[@]}" "${METRICS[@]}"
run_swift_test AppExitLivePrototypeTests "${NATIVE[@]}" Sources/Models.swift Sources/AppExitRules.swift Sources/AppExitRuntime.swift -framework AppKit -framework ApplicationServices

print "测试入口完成：$TEST_SUITES 个套件；显式实机/GUI项目以各自 PASS / SKIP 为准。"
print '测试数据库、可执行文件、私有诊断和编译缓存将在退出时清理。'
