#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="$ROOT/build/BatteryTime.app"
CACHE="${BATTERYTIME_BUILD_CACHE:-$ROOT/.build}"
ARCH="universal"
OPEN_APP=1
while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-open) OPEN_APP=0; shift ;;
        --arch|--output)
            [ "$#" -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }
            if [ "$1" = --arch ]; then ARCH="$2"; else OUTPUT="$2"; fi
            shift 2 ;;
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
[ ! -L "$OUTPUT" ] || { echo 'Refusing a symlink output path.' >&2; exit 1; }
[ "$(uname -s)" = Darwin ] || { echo 'BatteryTime must be built on macOS.' >&2; exit 1; }
if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo 'Apple developer tools are missing. Run: xcode-select --install' >&2; exit 1
fi
SDK="$(xcrun --sdk macosx --show-sdk-path)" || { echo 'No macOS SDK. Select installed developer tools with xcode-select.' >&2; exit 1; }
mkdir -p "$CACHE/ModuleCache" "$(dirname "$OUTPUT")"
CACHE="$(cd "$CACHE" && pwd)"
OUTPUT="$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"
LOG="$CACHE/build.log"
LOCK="$OUTPUT.build-lock"
if ! mkdir -m 700 "$LOCK" 2>/dev/null; then
    echo "Another build owns $LOCK. If a build was killed, verify it has stopped before removing that lock directory." >&2
    exit 1
fi
STAGING=""
PUBLISHED=0
cleanup() {
    if [ -n "$STAGING" ] && [ "$PUBLISHED" -eq 0 ]; then
        if [ -d "$STAGING/Previous.app" ]; then
            if [ -e "$OUTPUT" ]; then mv "$OUTPUT" "$STAGING/Failed.app" 2>/dev/null || true; fi
            if ! mv "$STAGING/Previous.app" "$OUTPUT"; then
                echo "Previous complete app preserved at $STAGING/Previous.app; automatic rollback failed." >&2
                STAGING=""
            fi
        fi
    fi
    if [ -n "$STAGING" ]; then rm -rf "$STAGING"; fi
    rmdir "$LOCK" 2>/dev/null || true
}
trap 'RESULT=$?; cleanup; exit "$RESULT"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
: > "$LOG"
fail() { echo "Build failed: $1" >&2; echo "Full log: $LOG" >&2; cat "$LOG" >&2; exit 1; }
[ -f "$ROOT/Resources/Info.plist" ] && [ -s "$ROOT/Resources/AppIcon.icns" ] || fail 'Source plist or application icon is missing.'
/usr/bin/plutil -lint "$ROOT/Resources/Info.plist" >>"$LOG" 2>&1 || fail 'Source Info.plist is invalid.'
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$ROOT/Resources/Info.plist")" = BatteryTime ] || fail 'Source CFBundleExecutable does not match BatteryTime.'
[ -x "$ROOT/scripts/validate-bundle.sh" ] || fail 'The bundle validation script is missing or not executable.'
STAGING="$(mktemp -d "$(dirname "$OUTPUT")/.batterytime-build.XXXXXX")"
BUNDLE="$STAGING/BatteryTime.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
SOURCES=("$ROOT"/Sources/BatteryCore/*.swift "$ROOT"/Sources/BatteryTime/*.swift)
for TARGET_ARCH in "${ARCHES[@]}"; do
    echo "Compiling BatteryTime for $TARGET_ARCH (macOS 13+)…"
    if ! xcrun swiftc -sdk "$SDK" -module-cache-path "$CACHE/ModuleCache" \
        -swift-version 6 -strict-concurrency=complete -warnings-as-errors -O -parse-as-library \
        -target "$TARGET_ARCH-apple-macos13.0" -module-name BatteryTime \
        -framework AppKit -framework SwiftUI -framework Charts -framework IOKit \
        -framework ServiceManagement -framework UserNotifications \
        "${SOURCES[@]}" -o "$STAGING/BatteryTime-$TARGET_ARCH" >>"$LOG" 2>&1; then
        fail 'Swift compilation failed. Swift 6 tools are required. Any previous app was preserved.'
    fi
 done
BIN="$BUNDLE/Contents/MacOS/BatteryTime"
if [ "${#ARCHES[@]}" -eq 2 ]; then
    xcrun lipo -create "$STAGING/BatteryTime-arm64" "$STAGING/BatteryTime-x86_64" -output "$BIN" >>"$LOG" 2>&1 || fail 'Universal executable creation failed.'
else
    cp "$STAGING/BatteryTime-${ARCHES[0]}" "$BIN"
fi
cp "$ROOT/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"
# Do not inherit a restrictive umask into a bundle intended for Finder/Launch Services.
chmod 755 "$BUNDLE" "$BUNDLE/Contents" "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources" "$BIN"
chmod 644 "$BUNDLE/Contents/Info.plist" "$BUNDLE/Contents/PkgInfo" "$BUNDLE/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --force --sign - --options runtime --timestamp=none "$BUNDLE" >>"$LOG" 2>&1 || fail 'Local ad-hoc signing failed.'
chmod 755 "$BUNDLE/Contents/_CodeSignature"
chmod 644 "$BUNDLE/Contents/_CodeSignature/CodeResources"
"$ROOT/scripts/validate-bundle.sh" "$BUNDLE" "${ARCHES[@]}" >>"$LOG" 2>&1 || fail 'The completed bundle failed validation.'
for TARGET_ARCH in "${ARCHES[@]}"; do
    if [ "$TARGET_ARCH" = "$(uname -m)" ]; then
        "$BIN" --diagnostics > "$STAGING/diagnostics.json" 2>>"$LOG" || fail 'The native executable failed its diagnostic run.'
        [ -s "$STAGING/diagnostics.json" ] || fail 'The native executable produced no diagnostics.'
        echo 'Native executable diagnostic run passed.'
    fi
 done
if [ -e "$OUTPUT" ]; then
    [ -d "$OUTPUT/Contents" ] && [ ! -L "$OUTPUT" ] || fail 'Refusing to replace a path that is not an app bundle.'
    mv "$OUTPUT" "$STAGING/Previous.app" || fail 'Could not preserve the previous app.'
fi
mv "$BUNDLE" "$OUTPUT" || fail 'Could not publish the completed bundle.'
"$ROOT/scripts/validate-bundle.sh" "$OUTPUT" "${ARCHES[@]}" >>"$LOG" 2>&1 || fail 'Published bundle validation failed; restoring previous app.'
PUBLISHED=1
echo "Compiled, signed, and verified: $OUTPUT"
/usr/bin/file "$OUTPUT/Contents/MacOS/BatteryTime"
if [ "$OPEN_APP" -eq 1 ]; then
    /usr/bin/open "$OUTPUT" || { echo "The verified app could not be opened in this environment: $OUTPUT" >&2; exit 1; }
fi
