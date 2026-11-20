#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="2.1.0"
BUILD_NUM="21"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macosx14.0"
SDK="$(xcrun --show-sdk-path)"

DO_TEST=0
INSTALL_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --test)
      DO_TEST=1
      shift
      ;;
    --install)
      if [[ $# -ge 2 && "$2" != --* ]]; then
        INSTALL_DIR="$2"
        shift 2
      else
        INSTALL_DIR="$HOME/Applications"
        shift
      fi
      ;;
    --target)
      TARGET="$2"
      shift 2
      ;;
    -h|--help)
      cat <<EOF
Usage: ./build.sh [--test] [--install [DIR]] [--target TRIPLE]
  --test           Run native & Swift unit tests after building
  --install [DIR]  Copy HardwareStatus.app to DIR (default: ~/Applications)
  --target TRIPLE  Override swiftc/clang target (default: ${ARCH}-apple-macosx14.0)
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

APP="$DIR/HardwareStatus.app"
BIN="$APP/Contents/MacOS/HardwareStatus"
OBJ_DIR="$DIR/build/obj"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OBJ_DIR"

C_SOURCES=(
  "$DIR/Sources/Native/hw_proc.c"
  "$DIR/Sources/Native/hw_smc.c"
  "$DIR/Sources/Native/hw_ioreport.c"
)

SWIFT_SOURCES=(
  "$DIR/Sources/App/MetricsModels.swift"
  "$DIR/Sources/App/DesignSystem.swift"
  "$DIR/Sources/App/StatusTitle.swift"
  "$DIR/Sources/App/PanelComponents.swift"
  "$DIR/Sources/App/SettingsView.swift"
  "$DIR/Sources/App/MonitorPanelController.swift"
  "$DIR/Sources/App/FanBoost.swift"
  "$DIR/Sources/App/SystemSampler.swift"
  "$DIR/Sources/App/AppDelegate.swift"
)

for f in "$DIR/Sources/Native"/*.c; do
  case " ${C_SOURCES[*]} " in *" $f "*) ;; *) echo "build.sh: $f is not in C_SOURCES" >&2; exit 1 ;; esac
done
for f in "$DIR/Sources/App"/*.swift; do
  case " ${SWIFT_SOURCES[*]} " in *" $f "*) ;; *) echo "build.sh: $f is not in SWIFT_SOURCES" >&2; exit 1 ;; esac
done

C_OBJS=()
for cfile in "${C_SOURCES[@]}"; do
  base="$(basename "$cfile" .c)"
  obj="$OBJ_DIR/${base}.o"
  clang -std=c11 -O2 -Wall -Wextra -Werror \
    -target "$TARGET" -isysroot "$SDK" \
    -c "$cfile" -o "$obj"
  C_OBJS+=("$obj")
done

swiftc -O -whole-module-optimization -parse-as-library \
  -module-name HardwareStatus \
  -target "$TARGET" \
  -sdk "$SDK" \
  -import-objc-header "$DIR/Sources/Native/hw_bridge.h" \
  "${SWIFT_SOURCES[@]}" "${C_OBJS[@]}" \
  -o "$BIN" \
  -framework Cocoa -framework QuartzCore -framework IOKit -framework CoreFoundation

cp "$DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUM" "$APP/Contents/Info.plist" 2>/dev/null || true

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "BUILT $BIN"
ls -la "$BIN"
file "$BIN"
plutil -p "$APP/Contents/Info.plist" | grep -E 'ShortVersion|Version'

if [[ "$DO_TEST" -eq 1 ]]; then
  echo "--- Running Tests ---"
  "$DIR/Tests/run_tests.sh"
fi

if [[ -n "$INSTALL_DIR" ]]; then
  mkdir -p "$INSTALL_DIR"
  ditto "$APP" "$INSTALL_DIR/HardwareStatus.app"
  echo "INSTALLED $INSTALL_DIR/HardwareStatus.app"
fi
