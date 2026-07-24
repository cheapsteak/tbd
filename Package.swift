// swift-tools-version: 6.0
import PackageDescription

// Swift 6.2's Sendable region analysis made WMO debug builds of the two big
// modules reach 6-9 GB RSS per swift-frontend (NIO + GRDB + many @Sendable
// closure captures), jetsam-killing CI's ~7 GB runner (surfaces as a bare
// `error: fatalError`, swiftlang/swift-package-manager#7086). Swift 6.3 fixes
// the blowup (measured peak: 1.35 GB), so the workaround only applies to
// older compilers — drop this entirely once no 6.2 toolchain builds the repo.
#if compiler(>=6.3)
let noWMODebugWorkaround: [SwiftSetting] = []
#else
let noWMODebugWorkaround: [SwiftSetting] = [
    .unsafeFlags(["-no-whole-module-optimization"], .when(configuration: .debug)),
]
#endif

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
        .package(url: "https://github.com/apple/swift-markdown", from: "0.4.0"),
        .package(url: "https://github.com/krzyzanowskim/STTextView", from: "2.3.8"),
        // Test-only: `TestClock` for tier-1 virtual-time tests. No `Sources/` target links it.
        .package(url: "https://github.com/pointfreeco/swift-clocks", from: "1.0.0"),
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
            // Swift 6.2 WMO-debug OOM workaround — see noWMODebugWorkaround above.
            swiftSettings: noWMODebugWorkaround
        ),
        .executableTarget(
            name: "TBDDaemon",
            dependencies: [
                "TBDDaemonLib",
            ],
            path: "Sources/TBDDaemon",
            exclude: ["Database", "Git", "Hooks", "Tmux", "Lifecycle", "Server", "SSH", "PR", "Keychain", "Claude", "Codex", "ModelProfile", "AskUserQuestion", "Diagnostics", "Process", "Mock", "Daemon.swift", "PIDFile.swift"],
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
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "STTextView", package: "STTextView"),
            ],
            path: "Sources/TBDApp",
            resources: [.copy("Resources/Icons")],
            // Swift 6.2 WMO-debug OOM workaround — see noWMODebugWorkaround
            // above. TBDApp is the larger of the two memory-heavy modules
            // (SwiftUI view bodies + MarkdownUI + SwiftTerm).
            swiftSettings: noWMODebugWorkaround
        ),
        .target(
            name: "TestSupport",
            dependencies: [
                "TBDDaemonLib",
                "TBDShared",
                .product(name: "Clocks", package: "swift-clocks"),
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
                .product(name: "Clocks", package: "swift-clocks"),
            ]
        ),
        // Tier 3 (docs/specs/2026-07-24-test-hardening-design.md §3): suites whose
        // runtime depends on an external process they do not fully control — a real
        // tmux server, a spawned child racing a deadline, the replay firehose. They
        // live in their own target so CI can run them serially on an otherwise idle
        // machine instead of contending with the parallel pass. Adding a suite here
        // slows every PR; the bar is the §3 criterion, not "it feels slow".
        .testTarget(
            name: "TBDDaemonLiveTests",
            dependencies: [
                "TBDDaemonLib",
                "TBDShared",
                "TestSupport",
                .product(name: "Clocks", package: "swift-clocks"),
            ]
        ),
        .testTarget(
            name: "TBDAppTests",
            dependencies: [
                "TBDApp",
                // For the replay-writer round-trip test (M4.2): the daemon
                // assembles replay bytes, the app's SwiftTerm consumes them,
                // and only this test target links the SwiftTerm product.
                "TBDDaemonLib",
                .product(name: "Clocks", package: "swift-clocks"),
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
