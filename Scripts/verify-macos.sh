#!/bin/bash
# Uses the release build through its temporary compile-only exit, then isolated task tests.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  printf '%s\n' '需要 macOS arm64 和 Xcode。GitHub Actions 可使用 macos-15。' >&2
  exit 1
fi
xcodebuild -version
/bin/zsh "$PROJECT_DIR/Scripts/build.sh" --verify-only
/bin/zsh "$PROJECT_DIR/Scripts/test.sh" --session-comparison
