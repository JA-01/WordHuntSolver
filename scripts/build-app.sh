#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# Reuse SDK modules across debug/tests and release; duplicate caches can exceed
# the free space on small Macs. This changes no compiler optimization settings.
MODULE_CACHE="$(swift build --show-bin-path)/ModuleCache"
mkdir -p "$MODULE_CACHE"
swift build -c release -Xswiftc -module-cache-path -Xswiftc "$MODULE_CACHE"
BIN="$(swift build -c release --show-bin-path)"
APP="$ROOT/dist/Word Hunt Solver.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ditto "$BIN/WordHuntSolver" "$APP/Contents/MacOS/WordHuntSolver"
ditto "$BIN/WordHuntSolver_WordHuntCore.bundle" "$APP/Contents/Resources/WordHuntSolver_WordHuntCore.bundle"
ditto "$BIN/WordHuntSolver_WordHuntMac.bundle" "$APP/Contents/Resources/WordHuntSolver_WordHuntMac.bundle"
ditto "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
ditto "$ROOT/packaging/Info.plist" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
printf '\nBuilt %s\nLaunch: open "%s"\n' "$APP" "$APP"
