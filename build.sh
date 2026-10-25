#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="$ROOT/build/BatteryTime.app"
ARCH="universal"
OPEN_APP=1
while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-open) OPEN_APP=0; shift ;;
        --arch) ARCH="${2:?Missing architecture}"; shift 2 ;;
        --output) OUTPUT="${2:?Missing output path}"; shift 2 ;;
        --help) echo 'Usage: ./build.sh [--no-open] [--arch universal|native|arm64|x86_64] [--output /path/BatteryTime.app]'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done
case "$ARCH" in
    universal) ARCHES=(arm64 x86_64) ;;
    native) ARCHES=("$(uname -m)") ;;
    arm64|x86_64) ARCHES=("$ARCH") ;;
    *) echo "Unsupported architecture: $ARCH" >&2; exit 2 ;;
esac
case "$OUTPUT" in *.app) ;; *) echo 'Output must end in .app' >&2; exit 2 ;; esac
if [ "$(uname -s)" != Darwin ]; then echo 'BatteryTime must be built on macOS.' >&2; exit 1; fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo 'Apple developer tools are missing. Run: xcode-select --install' >&2
    exit 1
fi
if ! SDK="$(xcrun --sdk macosx --show-sdk-path)"; then
    echo 'No macOS SDK found. Select an installed Xcode or Command Line Tools using xcode-select.' >&2
    exit 1
fi
mkdir -p "$ROOT/.build/ModuleCache" "$(dirname "$OUTPUT")"
OUTPUT="$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"
LOG="$ROOT/.build/build.log"
: > "$LOG"
STAGING="$(mktemp -d "$(dirname "$OUTPUT")/.batterytime-build.XXXXXX")"
cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT
fail() {
    echo "Build failed: $1" >&2
    echo "Compiler and validation log: $LOG" >&2
    cat "$LOG" >&2
    exit 1
}
BUNDLE="$STAGING/BatteryTime.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
SOURCES=("$ROOT"/Sources/BatteryCore/*.swift "$ROOT"/Sources/BatteryTime/*.swift)
for TARGET_ARCH in "${ARCHES[@]}"; do
    echo "Compiling BatteryTime for $TARGET_ARCH (macOS 13+)…"
    if ! xcrun swiftc -sdk "$SDK" -module-cache-path "$ROOT/.build/ModuleCache" \
        -swift-version 6 -strict-concurrency=complete -warnings-as-errors -O -parse-as-library \
        -target "$TARGET_ARCH-apple-macos13.0" -module-name BatteryTime \
        -framework AppKit -framework SwiftUI -framework Charts -framework IOKit \
        -framework ServiceManagement -framework UserNotifications \
        "${SOURCES[@]}" -o "$STAGING/BatteryTime-$TARGET_ARCH" >>"$LOG" 2>&1; then
        fail 'Swift compilation failed. Swift 6 / Xcode 16 or newer is required. Any existing app was preserved.'
    fi
done
BIN="$BUNDLE/Contents/MacOS/BatteryTime"
if [ "${#ARCHES[@]}" -eq 2 ]; then
    xcrun lipo -create "$STAGING/BatteryTime-arm64" "$STAGING/BatteryTime-x86_64" -output "$BIN" >>"$LOG" 2>&1 || fail 'Could not create universal executable.'
else
    cp "$STAGING/BatteryTime-${ARCHES[0]}" "$BIN"
fi
chmod 755 "$BIN"
cp "$ROOT/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"
[ -s "$BIN" ] && [ -x "$BIN" ] || fail 'Executable was not created.'
for TARGET_ARCH in "${ARCHES[@]}"; do
    xcrun lipo "$BIN" -verify_arch "$TARGET_ARCH" >>"$LOG" 2>&1 || fail "Executable architecture verification failed for $TARGET_ARCH."
done
/usr/bin/plutil -lint "$BUNDLE/Contents/Info.plist" >>"$LOG" 2>&1 || fail 'Invalid Info.plist.'
[ -s "$BUNDLE/Contents/Resources/AppIcon.icns" ] || fail 'Application icon is missing.'
/usr/bin/codesign --force --sign - --timestamp=none "$BUNDLE" >>"$LOG" 2>&1 || fail 'Local ad-hoc signing failed.'
/usr/bin/codesign --verify --deep --strict --verbose=2 "$BUNDLE" >>"$LOG" 2>&1 || fail 'Signature verification failed.'
# Move on the same volume only after all compilation, resources, and validation succeed.
# Roll back the previous complete bundle if the final move fails.
if [ -e "$OUTPUT" ]; then
    [ -d "$OUTPUT/Contents" ] && [ ! -L "$OUTPUT" ] || fail 'Refusing to replace a path that is not an application bundle.'
    mv "$OUTPUT" "$STAGING/Previous.app" || fail 'Could not move the previous app. Quit it and retry.'
fi
if ! mv "$BUNDLE" "$OUTPUT"; then
    if [ -d "$STAGING/Previous.app" ]; then mv "$STAGING/Previous.app" "$OUTPUT"; fi
    fail 'Could not install the completed bundle.'
fi
echo "Built and verified: $OUTPUT"
/usr/bin/file "$OUTPUT/Contents/MacOS/BatteryTime"
if [ "$OPEN_APP" -eq 1 ]; then
    /usr/bin/open "$OUTPUT" || { echo "Launch failed. Open the app in Finder: $OUTPUT" >&2; exit 1; }
fi
