#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$DIR/.."
OUT="$ROOT/build/test-core"
mkdir -p "$OUT"

if [[ "$(uname -s)" == "Darwin" ]]; then
  ARCH="$(uname -m)"
  TARGET="${ARCH}-apple-macosx14.0"
  SDK="$(xcrun --show-sdk-path)"

  echo "=== [1/2] Core & Native Telemetry Tests ==="
  for cfile in hw_proc hw_smc hw_ioreport; do
    clang -std=c11 -O2 -Wall -Wextra -Werror \
      -target "$TARGET" -isysroot "$SDK" \
      -c "$ROOT/Sources/Native/${cfile}.c" -o "$OUT/${cfile}.o"
  done

  swiftc -O -parse-as-library \
    -target "$TARGET" -sdk "$SDK" \
    -import-objc-header "$ROOT/Sources/Native/hw_bridge.h" \
    "$ROOT/Sources/App/MetricsModels.swift" \
    "$ROOT/Sources/App/DesignSystem.swift" \
    "$ROOT/Sources/App/StatusTitle.swift" \
    "$DIR/CoreTests.swift" \
    "$OUT/hw_proc.o" "$OUT/hw_smc.o" "$OUT/hw_ioreport.o" \
    -o "$OUT/core-tests" \
    -framework Cocoa -framework QuartzCore -framework IOKit -framework CoreFoundation

  "$OUT/core-tests"
fi

echo "=== [2/2] FanBoost & SMC Crash-Guard Tests ==="
"$DIR/fanboost/run.sh"
