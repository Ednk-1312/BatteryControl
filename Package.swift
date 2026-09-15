// swift-tools-version: 6.0
// BatteryControl — shared core: models, policy engine, validation, backend
// contracts, the XPC protocol, and the shared daemon client. Used by the
// app, the privileged helper, the `batterycontrol` CLI, and the unit tests
// so that all of them agree on the same control logic.
import PackageDescription

let package = Package(
    name: "BatteryCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "BatteryCore", targets: ["BatteryCore"]),
        .executable(name: "batterycontrol", targets: ["batterycontrol"]),
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
        .executableTarget(
            name: "batterycontrol",
            dependencies: ["BatteryCore"],
            path: "cli/batterycontrol",
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
