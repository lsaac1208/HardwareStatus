#!/bin/bash
# Logic & crash-guard tests for 超温风扇加速: real hw_smc.c + FanBoost.swift against fake AppleSMC.
# Runs cleanly on both macOS and Linux.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$DIR/../.."
OUT="$ROOT/build/test-fanboost"
mkdir -p "$OUT"

CC="${CC:-$(command -v clang || command -v gcc)}"
CFLAGS=(-std=c11 -Wall -Wextra -I"$DIR")
SWIFT_FLAGS=(-import-objc-header "$DIR/bridge.h")

if [[ "$(uname -s)" == "Darwin" ]]; then
  SDK="$(xcrun --show-sdk-path)"
  CFLAGS+=(-isysroot "$SDK")
  SWIFT_FLAGS+=(-sdk "$SDK")
else
  CFLAGS+=(-D_DEFAULT_SOURCE)
fi

"$CC" "${CFLAGS[@]}" -c "$ROOT/Sources/Native/hw_smc.c" -o "$OUT/hw_smc.o"
"$CC" "${CFLAGS[@]}" -c "$ROOT/Tests/fanboost/fake_smc.c" -o "$OUT/fake_smc.o"

swiftc "${SWIFT_FLAGS[@]}" \
  "$DIR/main.swift" "$ROOT/Sources/App/FanBoost.swift" \
  "$OUT/hw_smc.o" "$OUT/fake_smc.o" \
  -o "$OUT/fanboost-tests" -lm

"$OUT/fanboost-tests"

echo "Crash guard (child process raises SIGSEGV while boosted)"
LOG="$OUT/crash.log"
: > "$LOG"
set +e
SWIFT_BACKTRACE=enable=no FAKE_SMC_LOG="$LOG" "$OUT/fanboost-tests" crash 2>/dev/null
rc=$?
set -e
if [ "$rc" -ne 139 ] && [ "$rc" -ne $((128 + 11)) ]; then
  echo "  FAIL child exit $rc (want SIGSEGV)"
  exit 1
fi
for want in "F0Md=0" "F1Md=0" "Ftst=0"; do
  grep -qx "$want" "$LOG" && echo "  ok   handler wrote $want" || { echo "  FAIL handler did not write $want"; exit 1; }
done
echo "CRASH GUARD PASSED"
