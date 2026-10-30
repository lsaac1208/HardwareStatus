#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/HardwareStatus.app"
BIN="$APP/Contents/MacOS/HardwareStatus"
mkdir -p "$APP/Contents/MacOS"
clang -c "$DIR/hw_proc.c" -o /tmp/hw_proc_hs.o -O2
# Every Swift source in the repo root (entry point: @main in HardwareStatus.swift)
SOURCES=(
  "$DIR/HardwareStatus.swift"
  "$DIR/DesignSystem.swift"
  "$DIR/PanelComponents.swift"
  "$DIR/MonitorPanelController.swift"
  "$DIR/StatusTitle.swift"
)
for f in "$DIR"/*.swift; do
  case " ${SOURCES[*]} " in *" $f "*) ;; *) echo "build.sh: $f is not in SOURCES" >&2; exit 1 ;; esac
done
swiftc -O -whole-module-optimization -parse-as-library \
  -module-name HardwareStatus \
  -target arm64-apple-macosx26.0 \
  -sdk "$(xcrun --show-sdk-path)" \
  -import-objc-header "$DIR/hw_proc.h" \
  "${SOURCES[@]}" /tmp/hw_proc_hs.o \
  -o "$BIN" \
  -framework Cocoa -framework QuartzCore
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.9.1" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 14" "$APP/Contents/Info.plist" 2>/dev/null || true
echo "BUILT $BIN"
ls -la "$BIN"
file "$BIN"
plutil -p "$APP/Contents/Info.plist" | grep -E 'ShortVersion|Version'
