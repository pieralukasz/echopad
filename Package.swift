// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EchoPad",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            revision: "300165b240c45375add402265f62410b6df33cf1"
        )
    ],
    targets: [
        .executableTarget(
            name: "EchoPad",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "macos",
            exclude: ["Info.plist", "PkgInfo"]
        )
    ]
)
