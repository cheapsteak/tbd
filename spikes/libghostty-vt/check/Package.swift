// swift-tools-version: 5.9
// THROWAWAY engine check for the libghostty-vt spike. See ../README.md.
//
// `Sources/TBDTerminalSerialization` holds symlinks to TBD's real handover code,
// so this package exercises those exact files and not a copy that could drift.
// `GhosttyVt.xcframework` is a symlink to the official vt-1.0.0 build in ../vendor.
import PackageDescription

let package = Package(
    name: "vtcheck",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/cheapsteak/SwiftTerm", revision: "c6b544f84bf36fd81cd88bac356b27897fc6a2ab"),
    ],
    targets: [
        .binaryTarget(name: "GhosttyVt", path: "GhosttyVt.xcframework"),
        .target(
            name: "TBDTerminalSerialization",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/TBDTerminalSerialization"),
        .executableTarget(
            name: "vtcheck",
            dependencies: [
                "GhosttyVt", "TBDTerminalSerialization",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/vtcheck",
            linkerSettings: [.linkedLibrary("c++")]),
    ]
)
