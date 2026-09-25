// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "echopad",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Local checkouts while the packages are unpublished; switched to the
        // GitHub URLs (tagged releases) when they go public.
        .package(path: "../ScribeKit"),
        .package(path: "../SystemAudioKit"),
    ],
    targets: [
        .target(
            name: "EchoPadKit",
            dependencies: [
                .product(name: "ScribeKit", package: "ScribeKit"),
                .product(name: "SystemAudioKit", package: "SystemAudioKit"),
            ],
            path: "Sources/EchoPadKit",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Carbon"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .executableTarget(
            name: "echopad",
            dependencies: ["EchoPadKit"],
            path: "Sources/EchoPad",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "EchoPadKitTests",
            dependencies: ["EchoPadKit"],
            path: "Tests/EchoPadKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
