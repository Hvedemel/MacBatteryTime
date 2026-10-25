#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/.build/ModuleCache" "$ROOT/.build/regression"
cd "$ROOT"
# The identical assertions also run through XCTest via Package.swift in full Xcode.
# This Foundation-only runner works with Command Line Tools, which may omit XCTest.
xcrun swiftc -swift-version 6 -warnings-as-errors -module-cache-path "$ROOT/.build/ModuleCache" \
    -enable-testing -module-name BatteryCore -emit-module -emit-library \
    Sources/BatteryCore/*.swift -emit-module-path "$ROOT/.build/regression/BatteryCore.swiftmodule" \
    -o "$ROOT/.build/regression/libBatteryCore.dylib"
xcrun swiftc -swift-version 6 -warnings-as-errors -module-cache-path "$ROOT/.build/ModuleCache" \
    -D BATTERYTIME_STANDALONE_TESTS -parse-as-library -I "$ROOT/.build/regression" \
    -L "$ROOT/.build/regression" -lBatteryCore -Xlinker -rpath -Xlinker @executable_path \
    Tests/BatteryCoreTests/*.swift Tests/StandaloneRunner.swift -o "$ROOT/.build/regression/BatteryCoreTests"
exec "$ROOT/.build/regression/BatteryCoreTests"
