#!/bin/bash
# Linux-only logic tests for 超温风扇加速: real hw_smc.c + FanBoost.swift against a fake
# AppleSMC (fake_smc.c). Needs a Swift toolchain (swiftc) and gcc/clang. Not part of build.sh.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$DIR/../.."
OUT="$(mktemp -d)"
CC="${CC:-$(command -v clang || command -v gcc)}"
"$CC" -std=c11 -D_DEFAULT_SOURCE -Wall -Wextra -c "$ROOT/hw_smc.c" -I"$DIR" -o "$OUT/hw_smc.o"
"$CC" -std=c11 -D_DEFAULT_SOURCE -Wall -Wextra -c "$DIR/fake_smc.c" -I"$DIR" -o "$OUT/fake_smc.o"
swiftc -import-objc-header "$DIR/bridge.h" "$DIR/main.swift" "$ROOT/FanBoost.swift" \
  "$OUT/hw_smc.o" "$OUT/fake_smc.o" -o "$OUT/fanboost-tests" -lm
"$OUT/fanboost-tests"

echo "Crash guard (child process raises SIGSEGV while boosted)"
LOG="$OUT/crash.log"
# Linux Swift runtime installs its own backtracer; turn it off so the default action runs
set +e; SWIFT_BACKTRACE=enable=no FAKE_SMC_LOG="$LOG" "$OUT/fanboost-tests" crash 2>/dev/null; rc=$?; set -e
if [ "$rc" -ne 139 ] && [ "$rc" -ne $((128 + 11)) ]; then echo "  FAIL child exit $rc (want SIGSEGV)"; exit 1; fi
for want in "F0Md=0" "F1Md=0" "Ftst=0"; do
  grep -qx "$want" "$LOG" && echo "  ok   handler wrote $want" || { echo "  FAIL handler did not write $want"; exit 1; }
done
echo "CRASH GUARD PASSED"
