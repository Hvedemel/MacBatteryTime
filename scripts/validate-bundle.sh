#!/bin/bash
set -euo pipefail
fail() { echo "Bundle validation failed: $*" >&2; exit 1; }
[ "$#" -ge 1 ] || fail 'Usage: validate-bundle.sh /path/BatteryTime.app [architectures…]'
BUNDLE="$1"; shift
PLIST="$BUNDLE/Contents/Info.plist"
[ -d "$BUNDLE" ] && [ ! -L "$BUNDLE" ] || fail 'Bundle directory is missing or is a symlink.'
[ -f "$PLIST" ] || fail 'Contents/Info.plist is missing.'
/usr/bin/plutil -lint "$PLIST" >/dev/null || fail 'Info.plist syntax is invalid.'
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null; }
[ "$(plist CFBundleExecutable)" = BatteryTime ] || fail 'CFBundleExecutable must match the BatteryTime executable.'
[ "$(plist CFBundleIdentifier)" = dk.batterytime.menubar ] || fail 'Unexpected or missing bundle identifier.'
[ "$(plist CFBundlePackageType)" = APPL ] || fail 'CFBundlePackageType must be APPL.'
[ "$(plist LSMinimumSystemVersion)" = 13.0 ] || fail 'Deployment metadata must match macOS 13.0.'
[ "$(plist LSUIElement)" = true ] || fail 'LSUIElement must enable menu bar operation.'
[ -n "$(plist CFBundleVersion)" ] && [ -n "$(plist CFBundleShortVersionString)" ] || fail 'Application version is missing.'
BIN="$BUNDLE/Contents/MacOS/BatteryTime"
[ -f "$BIN" ] && [ -x "$BIN" ] && [ -s "$BIN" ] && [ ! -L "$BIN" ] || fail 'The executable is missing, empty, non-executable, or a symlink.'
ICON="$(plist CFBundleIconFile)"
case "$ICON" in ''|*/*|..|.) fail 'Invalid CFBundleIconFile.' ;; esac
ICON="${ICON%.icns}.icns"
[ -s "$BUNDLE/Contents/Resources/$ICON" ] || fail 'The application icon is missing.'
[ "$(/usr/bin/head -c 4 "$BUNDLE/Contents/Resources/$ICON")" = icns ] || fail 'Icon is not an ICNS resource.'
if [ "$#" -eq 0 ]; then read -r -a ARCHES <<< "$(xcrun lipo "$BIN" -archs)"; else ARCHES=("$@"); fi
[ "${#ARCHES[@]}" -gt 0 ] || fail 'No executable architectures were found.'
for ARCH in "${ARCHES[@]}"; do
    xcrun lipo "$BIN" -verify_arch "$ARCH" || fail "Missing $ARCH executable slice."
    HEADER="$(xcrun otool -arch "$ARCH" -hv "$BIN")"
    case "$HEADER" in *EXECUTE*) ;; *) fail "$ARCH slice is not a Mach-O executable." ;; esac
    MINIMUM="$(xcrun vtool -arch "$ARCH" -show-build "$BIN" | awk '/minos/ {print $2}')"
    case "$MINIMUM" in 13.0|13.0.0) ;; *) fail "$ARCH deployment target is $MINIMUM, expected 13.0." ;; esac
 done
/usr/bin/codesign --verify --all-architectures --strict --verbose=2 "$BUNDLE" || fail 'The bundle signature or sealed resources are invalid.'
echo "Validated bundle: $BUNDLE"
