#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="${BATTERYTIME_BUILD_CACHE:-$ROOT/.build}"
mkdir -p "$CACHE/ModuleCache" "$CACHE/regression"
cd "$ROOT"
xcrun swiftc -swift-version 6 -warnings-as-errors -module-cache-path "$CACHE/ModuleCache" \
    -enable-testing -module-name BatteryCore -emit-module -emit-library \
    Sources/BatteryCore/*.swift -emit-module-path "$CACHE/regression/BatteryCore.swiftmodule" \
    -o "$CACHE/regression/libBatteryCore.dylib"
# Discover method names from the same XCTest source: adding a test cannot silently omit it.
RUNNER="$CACHE/regression/Runner.swift"
cat > "$RUNNER" <<'SWIFT'
import Foundation
@main enum RegressionRunner {
    static func main() {
        let suite = BatteryCoreTests()
        let tests: [(String, () throws -> Void)] = [
SWIFT
awk '/^[[:space:]]*func test[A-Za-z0-9_]+\(/ { name=$2; sub(/\(.*/, "", name); print "            (\"" name "\", suite." name ")," }' Tests/BatteryCoreTests/*.swift >> "$RUNNER"
cat >> "$RUNNER" <<'SWIFT'
        ]
        for (name, test) in tests {
            let before = failures
            do { try test() } catch { print("FAIL \(name): \(error)"); failures += 1 }
            print("\(failures == before ? "PASS" : "FAIL") \(name)")
        }
        print("\(tests.count) core regression tests completed; \(failures) failures.")
        if failures > 0 { exit(1) }
    }
}
SWIFT
xcrun swiftc -swift-version 6 -warnings-as-errors -module-cache-path "$CACHE/ModuleCache" \
    -D BATTERYTIME_STANDALONE_TESTS -parse-as-library -I "$CACHE/regression" \
    -L "$CACHE/regression" -lBatteryCore -Xlinker -rpath -Xlinker @executable_path \
    Tests/BatteryCoreTests/*.swift Tests/StandaloneAssertions.swift "$RUNNER" -o "$CACHE/regression/BatteryCoreTests"
"$CACHE/regression/BatteryCoreTests"
if [ -f Tests/AppTests.swift ]; then
    xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
        -module-cache-path "$CACHE/ModuleCache" -target "$(uname -m)-apple-macos13.0" \
        Sources/BatteryCore/*.swift Sources/BatteryTime/BatteryReader.swift Sources/BatteryTime/BatteryMonitor.swift \
        Tests/AppTests.swift -o "$CACHE/regression/BatteryAppTests"
    "$CACHE/regression/BatteryAppTests"
fi
