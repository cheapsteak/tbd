// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TBD",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.65.0"),
        // Pinned to a main-branch revision because the `fontSmoothing` public
        // property (PR #531) hasn't shipped in a tagged release yet. Switch back
        // to `from: "1.14.0"` (or whichever) once SwiftTerm cuts a release that
        // includes commit dae32cc.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", revision: "dae32cc8f9bcda15713f4091bb2ea7e11f6dd57c"),
        .package(url: "https://github.com/raspu/Highlightr", from: "2.2.1"),
        .package(url: "https://github.com/siteline/swiftui-introspect", from: "1.0.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
        .package(url: "https://github.com/LebJe/TOMLKit", from: "0.6.0"),
    ],
    targets: [
        .target(
            name: "TBDShared",
            path: "Sources/TBDShared"
        ),
        // Per-worktree icon generation (AppKit + CoreGraphics + CoreText).
        // Extracted from TBDApp so the IconBaker executable can reuse the
        // same drawing code to produce Resources/AppIcon.icns without pulling
        // in the entire TBDApp dependency graph.
        .target(
            name: "TBDAppIcon",
            path: "Sources/TBDAppIcon"
        ),
        // One-shot CLI that renders the default (no-ribbon) icon and writes
        // a multi-rep .icns file. Run `swift run IconBaker Resources/AppIcon.icns`
        // after changing TBDAppIcon/AppIcon.swift, then commit the result.
        .executableTarget(
            name: "IconBaker",
            dependencies: ["TBDAppIcon"],
            path: "Sources/IconBaker"
        ),
        .target(
            name: "TBDDaemonLib",
            dependencies: [
                "TBDShared",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Sources/TBDDaemon",
            exclude: ["main.swift"],
            // Disable whole-module optimization in debug builds. WMO compiles
            // all files in the module as a single swift-frontend process,
            // which on this module reaches 6-9 GB RSS during Swift 6.2's
            // Sendable region analysis (NIO + GRDB + many @Sendable closure
            // captures of ChannelHandlerContext). The macos-15 GHA runner
            // caps at ~7 GB; jetsam SIGKILLs the frontend and SPM reports
            // a bare `error: fatalError` (Diagnostics.fatalError sentinel —
            // see swiftlang/swift-package-manager#7086). Per-file compilation
            // keeps each frontend at ~150-300 MB. Release builds keep WMO.
            swiftSettings: [
                .unsafeFlags(["-no-whole-module-optimization"], .when(configuration: .debug)),
            ]
        ),
        .executableTarget(
            name: "TBDDaemon",
            dependencies: [
                "TBDDaemonLib",
            ],
            path: "Sources/TBDDaemon",
            exclude: ["Database", "Git", "Hooks", "Tmux", "Lifecycle", "Server", "SSH", "PR", "Keychain", "Claude", "ModelProfile", "AskUserQuestion", "Daemon.swift", "PIDFile.swift"],
            sources: ["main.swift"]
        ),
        .executableTarget(
            name: "TBDCLI",
            dependencies: [
                "TBDShared",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            path: "Sources/TBDCLI"
        ),
        .executableTarget(
            name: "TBDApp",
            dependencies: [
                "TBDShared",
                "TBDAppIcon",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Highlightr", package: "Highlightr"),
                .product(name: "SwiftUIIntrospect", package: "swiftui-introspect"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "TOMLKit", package: "TOMLKit"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            path: "Sources/TBDApp",
            resources: [.copy("Resources/Icons")],
            // See TBDDaemonLib above. TBDApp is the larger of the two
            // memory-heavy modules (SwiftUI view bodies + MarkdownUI +
            // SwiftTerm); same WMO-OOM symptom on the macos-15 runner.
            swiftSettings: [
                .unsafeFlags(["-no-whole-module-optimization"], .when(configuration: .debug)),
            ]
        ),
        .target(
            name: "TestSupport",
            dependencies: [
                "TBDDaemonLib",
                "TBDShared",
            ],
            path: "Tests/TestSupport"
        ),
        .testTarget(
            name: "TBDSharedTests",
            dependencies: ["TBDShared"]
        ),
        .testTarget(
            name: "TBDDaemonTests",
            dependencies: [
                "TBDDaemonLib",
                "TBDShared",
                "TestSupport",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "TBDAppTests",
            dependencies: [
                "TBDApp",
            ],
            resources: [
                .copy("Fixtures")
            ]
        ),
        .testTarget(
            name: "TBDCLITests",
            dependencies: [
                "TBDCLI",
                "TBDShared",
            ]
        ),
    ]
)
