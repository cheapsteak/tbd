// swift-tools-version: 5.9
// THROWAWAY proof of concept: a Metal terminal window over stock libghostty-vt 1.0.0.
// See ../README.md. Adapted from tkzmux (MIT); see ../third_party/tkzmux/.
//
// `GhosttyVt.xcframework` is a symlink to the official vt-1.0.0 build in ../vendor.
import PackageDescription

let package = Package(
    name: "ghosttyview",
    platforms: [.macOS("15.0")],
    targets: [
        .binaryTarget(name: "GhosttyVt", path: "GhosttyVt.xcframework"),
        .target(name: "TkzPtyShim", path: "Sources/TkzPtyShim", publicHeadersPath: "include"),
        .target(name: "TkzShaderTypes", path: "Sources/TkzShaderTypes", publicHeadersPath: "include"),
        .executableTarget(
            name: "ghosttyview",
            dependencies: ["GhosttyVt", "TkzPtyShim", "TkzShaderTypes"],
            path: "Sources/ghosttyview",
            linkerSettings: [.linkedLibrary("c++")]),
    ]
)
