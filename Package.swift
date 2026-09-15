// swift-tools-version: 6.0
// BatteryControl — shared core: models, policy engine, validation, backend
// contracts, and the XPC protocol. Used by the app, the privileged helper,
// and the unit tests so that all three agree on the same control logic.
import PackageDescription

let package = Package(
    name: "BatteryCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "BatteryCore", targets: ["BatteryCore"]),
    ],
    targets: [
        .target(
            name: "BatteryCore",
            path: "BatteryCore",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        .testTarget(
            name: "BatteryCoreTests",
            dependencies: ["BatteryCore"],
            path: "Tests/BatteryCoreTests"
        ),
    ]
)
