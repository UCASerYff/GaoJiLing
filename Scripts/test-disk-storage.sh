#!/bin/zsh
# Targeted logic only. In the shared integration workspace acquire Master build_lease.py first.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PYTHONDONTWRITEBYTECODE=1
TEST_TEMP="$(python3 -c 'import tempfile; print(tempfile.mkdtemp(prefix="gaojiling-disk-tests-", suffix=".noindex", dir="/private/tmp"))')"
trap 'rm -rf "$TEST_TEMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export CLANG_MODULE_CACHE_PATH="$TEST_TEMP/cache"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
cd "$PROJECT_DIR"
SWIFT=(swiftc -swift-version 5 -Onone -sdk "$SDK" -module-cache-path "$TEST_TEMP/cache")
"${SWIFT[@]}" Sources/DiskImageAnalysis.swift Sources/DiskImageNTFS.swift Tests/DiskImageCoreTests.swift -o "$TEST_TEMP/image-core"
"$TEST_TEMP/image-core"
"${SWIFT[@]}" Sources/LocalVolumeMetadata.swift Tests/LocalVolumeMetadataTests.swift -o "$TEST_TEMP/volume-metadata"
"$TEST_TEMP/volume-metadata"
"${SWIFT[@]}" Sources/DiskImageReportWriter.swift Tests/DiskImageReportWriterTests.swift -o "$TEST_TEMP/report-writer"
"$TEST_TEMP/report-writer"
"${SWIFT[@]}" Sources/LocalVolumeMetadata.swift Sources/DiskImageAnalysis.swift Sources/DiskImageNTFS.swift \
  Sources/DiskImageReportWriter.swift Sources/DiskStorageController.swift Tests/DiskStorageControllerTests.swift \
  -framework AppKit -o "$TEST_TEMP/controller"
"$TEST_TEMP/controller"
