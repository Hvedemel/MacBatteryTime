// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BatteryTime",
    platforms: [.macOS(.v13)],
    products: [.library(name: "BatteryCore", targets: ["BatteryCore"])],
    targets: [
        .target(name: "BatteryCore"),
        .testTarget(name: "BatteryCoreTests", dependencies: ["BatteryCore"])
    ]
)
