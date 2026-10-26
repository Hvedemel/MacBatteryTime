#!/bin/bash
# Destructive fault injection is confined to this script's private temporary directory.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/../BatteryTime.app}"
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp/}BatteryTimeBuildTests.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
COUNT=0
pass() { COUNT=$((COUNT + 1)); echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; cat "$SCRATCH/result.log" >&2; exit 1; }
reject() {
    local NAME="$1"; shift
    if "$@" > "$SCRATCH/result.log" 2>&1; then fail "$NAME unexpectedly succeeded"; fi
    pass "$NAME"
}
copy_app() { rm -rf "$SCRATCH/Bad.app"; cp -R "$APP" "$SCRATCH/Bad.app"; }
"$ROOT/scripts/validate-bundle.sh" "$APP" > "$SCRATCH/result.log" 2>&1 || fail 'real bundle validation'
pass 'real universal application bundle validates'
copy_app; rm "$SCRATCH/Bad.app/Contents/MacOS/BatteryTime"
reject 'missing executable rejected' "$ROOT/scripts/validate-bundle.sh" "$SCRATCH/Bad.app"
copy_app; chmod 644 "$SCRATCH/Bad.app/Contents/MacOS/BatteryTime"
reject 'non-executable permissions rejected' "$ROOT/scripts/validate-bundle.sh" "$SCRATCH/Bad.app"
copy_app; /usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable WrongName' "$SCRATCH/Bad.app/Contents/Info.plist"
reject 'mismatched executable metadata rejected' "$ROOT/scripts/validate-bundle.sh" "$SCRATCH/Bad.app"
copy_app; /usr/libexec/PlistBuddy -c 'Set :LSMinimumSystemVersion 14.0' "$SCRATCH/Bad.app/Contents/Info.plist"
reject 'inconsistent deployment metadata rejected' "$ROOT/scripts/validate-bundle.sh" "$SCRATCH/Bad.app"
copy_app; rm "$SCRATCH/Bad.app/Contents/Resources/AppIcon.icns"
reject 'missing icon rejected' "$ROOT/scripts/validate-bundle.sh" "$SCRATCH/Bad.app"
copy_app; /usr/libexec/PlistBuddy -c 'Set :CFBundleName Edited' "$SCRATCH/Bad.app/Contents/Info.plist"
reject 'invalid sealed resources rejected' "$ROOT/scripts/validate-bundle.sh" "$SCRATCH/Bad.app"
copy_app; printf 'not a Mach-O executable' > "$SCRATCH/Bad.app/Contents/MacOS/BatteryTime"
reject 'corrupt executable rejected' "$ROOT/scripts/validate-bundle.sh" "$SCRATCH/Bad.app" arm64

# Small real Swift program tests packaging/failure mechanics without recompiling the
# complete GUI for every injected error. The delivered GUI is built separately.
FIXTURE="$SCRATCH/Source"
mkdir -p "$FIXTURE/Sources/BatteryCore" "$FIXTURE/Sources/BatteryTime" "$FIXTURE/Resources" "$FIXTURE/scripts"
cp "$ROOT/build.sh" "$FIXTURE/build.sh"
cp "$ROOT/scripts/validate-bundle.sh" "$FIXTURE/scripts/validate-bundle.sh"
cp "$ROOT/Resources/Info.plist" "$FIXTURE/Resources/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$FIXTURE/Resources/AppIcon.icns"
printf 'import Foundation\n' > "$FIXTURE/Sources/BatteryCore/Placeholder.swift"
cat > "$FIXTURE/Sources/BatteryTime/Main.swift" <<'SWIFT'
import Foundation
@main enum PackagingFixture {
    static func main() { print("{\"availability\":\"noBattery\",\"message\":\"Packaging test fixture\"}") }
}
SWIFT
OUT="$SCRATCH/Result.app"
mkdir -p "$OUT/Contents"
printf 'preserve this previous app' > "$OUT/Contents/previous-marker"
export BATTERYTIME_BUILD_CACHE="${BATTERYTIME_BUILD_CACHE:-$FIXTURE/.build}"
reject 'missing argument rejected' "$FIXTURE/build.sh" --output
reject 'unsupported architecture rejected' "$FIXTURE/build.sh" --arch invalid
ln -s "$OUT" "$SCRATCH/Link.app"
reject 'symlink destination rejected' "$FIXTURE/build.sh" --no-open --output "$SCRATCH/Link.app"
mkdir "$OUT.build-lock"
reject 'concurrent build lock respected' "$FIXTURE/build.sh" --no-open --output "$OUT"
rmdir "$OUT.build-lock"
printf 'intentional Swift compiler failure\n' > "$FIXTURE/Sources/BatteryCore/Placeholder.swift"
reject 'actual compiler failure reported' "$FIXTURE/build.sh" --arch native --no-open --output "$OUT"
[ -f "$OUT/Contents/previous-marker" ] || fail 'compiler error removed previous app'
[ ! -e "$OUT.build-lock" ] || fail 'failed build retained lock'
pass 'compiler error preserves previous app and clears lock'
reject 'compiler error without previous app' "$FIXTURE/build.sh" --arch native --no-open --output "$SCRATCH/Absent.app"
[ ! -e "$SCRATCH/Absent.app" ] || fail 'incomplete new bundle was published'
pass 'failed compilation publishes no incomplete bundle'
printf 'import Foundation\n' > "$FIXTURE/Sources/BatteryCore/Placeholder.swift"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable WrongName' "$FIXTURE/Resources/Info.plist"
reject 'invalid source metadata rejected' "$FIXTURE/build.sh" --no-open --output "$OUT"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable BatteryTime' "$FIXTURE/Resources/Info.plist"

mkdir "$SCRATCH/shims"
cat > "$SCRATCH/shims/mv" <<'MV'
#!/bin/bash
case "$1" in */BatteryTime.app)
    if [ "$2" = "$TEST_BUILD_DESTINATION" ]; then echo 'Injected final move failure' >&2; exit 1; fi ;;
esac
exec /bin/mv "$@"
MV
chmod +x "$SCRATCH/shims/mv"
export TEST_BUILD_DESTINATION="$OUT"
reject 'publication move failure reported' env PATH="$SCRATCH/shims:$PATH" "$FIXTURE/build.sh" --arch native --no-open --output "$OUT"
[ -f "$OUT/Contents/previous-marker" ] || fail 'failed move did not restore previous app'
pass 'publication move failure restores previous app'
cp "$FIXTURE/scripts/validate-bundle.sh" "$FIXTURE/scripts/validate-bundle.real.sh"
cat > "$FIXTURE/scripts/validate-bundle.sh" <<'VALIDATE'
#!/bin/bash
if [ "$1" = "$TEST_BUILD_DESTINATION" ]; then echo 'Injected post-publication validation failure' >&2; exit 1; fi
exec "$(dirname "$0")/validate-bundle.real.sh" "$@"
VALIDATE
chmod +x "$FIXTURE/scripts/validate-bundle.sh"
reject 'post-publication validation failure reported' "$FIXTURE/build.sh" --arch native --no-open --output "$OUT"
[ -f "$OUT/Contents/previous-marker" ] || fail 'post-validation failure did not restore previous app'
pass 'post-publication validation failure restores previous app'
cp "$ROOT/scripts/validate-bundle.sh" "$FIXTURE/scripts/validate-bundle.sh"
if ! (umask 077; "$FIXTURE/build.sh" --arch native --no-open --output "$OUT") > "$SCRATCH/result.log" 2>&1; then fail 'restrictive-umask fixture build'; fi
[ "$(stat -f %Lp "$OUT")" = 755 ] && [ "$(stat -f %Lp "$OUT/Contents/MacOS/BatteryTime")" = 755 ] || fail 'bundle/executable permissions depend on umask'
[ "$(stat -f %Lp "$OUT/Contents/Info.plist")" = 644 ] || fail 'plist permissions depend on umask'
pass 'real fixture compiles, signs, runs diagnostics, and normalizes restrictive umask'
[ "$(stat -f %Lp "$OUT/Contents/_CodeSignature")" = 755 ] && [ "$(stat -f %Lp "$OUT/Contents/_CodeSignature/CodeResources")" = 644 ] || fail 'signature permissions depend on umask'
pass 'code-signature resources remain readable under restrictive umask'
[ ! -e "$OUT.build-lock" ] || fail 'successful build retained lock'
if find "$SCRATCH" -maxdepth 1 -name '.batterytime-build.*' | /usr/bin/grep -q .; then fail 'temporary incomplete bundles were retained'; fi
pass 'success/failure staging directories and locks cleaned'
echo "$COUNT build/bundle checks completed; 0 failures."
