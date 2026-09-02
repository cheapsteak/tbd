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

// Thinking about splitting this package (core vs app)? Read
// docs/research/2026-08-19-cold-build-split/findings.md first: a measured cold
// build is ~70% core / ~30% app, and the split was judged low-ROI on that evidence.
let package = Package(
    name: "TBD",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.65.0"),
        // Pinned to a TBD fork of an upstream main-branch revision. Main
        // branch, because no tagged release contains upstream's display-link
        // frame scheduler: through v1.20.0, SwiftTerm repaints via
        // `queuePendingDisplay()`, which coalesces damage behind a fixed
        // `DispatchQueue.main.asyncAfter(+16.67ms)` — a floor on key-to-paint
        // latency rather than a rate limit, and one TBD measured in the
        // field. Upstream `main` deletes that mechanism outright
        // (`queuePendingDisplay`, `pendingDisplay`, `displayImmediately`,
        // `scheduleDisplay(immediate:)` are all gone) in favour of a
        // `FrameDriver` on `CADisplayLink`/`CVDisplayLink`
        // (`Sources/SwiftTerm/Apple/FrameDriver.swift`), and moves the macOS
        // Metal layer's rendering off the main thread. TBD runs many
        // streaming TUI terminals at once — the load upstream issue #658
        // describes — so the main-thread cost of the old scheduler is ours to
        // carry. A fork, because SwiftTerm 2.0 removed `getTerminal()` from
        // the public surface without giving view embedders any public route
        // to the `Terminal` — `TerminalView.withTerminal(_:caller:)`, the
        // self-locking accessor TBD needs for OSC state reads and mouse
        // encoding, is internal upstream. The pinned revision is upstream
        // `9c2518e` plus one commit (branch `tbd/public-with-terminal`)
        // making `withTerminal` public. Once upstream merges an equivalent
        // accessor, re-pin to upstream and delete the fork; once a tagged
        // release contains both, switch back to `from:`.
        //
        // A frame loop that does not run on the main thread may never call
        // `viewWillDraw()`, which TBD's terminal diagnostics hook. Diagnostics
        // going quiet is expected on this revision, not a regression.
        //
        // RE-VERIFIED for 9c2518e (2026-08-28): ChildReaper STAYS, unchanged.
        // `LocalProcess` was substantially rewritten on this revision (locked
        // session state, a `TerminalIOPipeline` read path), but `waitpid` is
        // still called from exactly one place in the whole package —
        // `processTerminated()` at `LocalProcess.swift:384`, reachable only
        // from the `DispatchSourceProcess` `.exit` handler
        // (`LocalProcess.swift:589`). Neither teardown path TBD uses reaps:
        // `deinit` (`:356`) and `terminate()` (`:604`) both take the session
        // resources and cancel the monitor (`:358`, `:620`) with no `waitpid`,
        // and `terminate()` now cancels *before* it sends `SIGTERM` (`:624`),
        // so the exit event is even less likely to fire than it was.
        //
        // Re-verify again on the next bump, because the reason ChildReaper
        // exists is a property of the pinned revision: upstream reaps only
        // from its `DispatchSourceProcess` (`.exit`) handler, and both
        // `deinit` and `terminate()` cancel that source before the child
        // actually exits — so TBD must reap the PTY child itself. If a later
        // revision reaps its own children, `ChildReaper` becomes a competing
        // waiter on a pid the OS may have recycled, which is worse than the
        // leak it fixes. Its doc comment names the exact lines to re-read.
        .package(url: "https://github.com/cheapsteak/SwiftTerm", revision: "62d0be6d4c9641a4b27f311c55e1489b024271c3"),
        .package(url: "https://github.com/raspu/Highlightr", from: "2.2.1"),
        .package(url: "https://github.com/siteline/swiftui-introspect", from: "1.0.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
        .package(url: "https://github.com/LebJe/TOMLKit", from: "0.6.0"),
        .package(url: "https://github.com/apple/swift-markdown", from: "0.4.0"),
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
                // The daemon is the default reader for a holder-backed session:
                // it drains that session's pty master into a headless SwiftTerm
                // `Terminal` so an unattended job never wedges behind a full tty
                // queue (Sources/TBDDaemon/Holder/HolderReader.swift).
                //
                // This pulls an AppKit-importing target into the daemon binary.
                // SwiftTerm ships one target with no core/views split, so there
                // is no headless-only product to depend on instead; the daemon
                // simply never touches the view types.
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/TBDDaemon",
            exclude: ["main.swift"],
            resources: [.copy("Database/Migrations")],
            // Swift 6.2 WMO-debug OOM workaround — see noWMODebugWorkaround above.
            swiftSettings: noWMODebugWorkaround
        ),
        .executableTarget(
            name: "TBDDaemon",
            dependencies: [
                "TBDDaemonLib",
            ],
            path: "Sources/TBDDaemon",
            exclude: ["Actuation", "Database", "Git", "Hooks", "Tmux", "Lifecycle", "Server", "SSH", "PR", "Keychain", "Claude", "Codex", "ModelProfile", "AskUserQuestion", "Diagnostics", "Process", "Mock", "Daemon.swift", "PIDFile.swift"],
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
        // One process per shadow peer (docs/specs/2026-08-29-remote-peer-messaging-design.md
        // § "Shadow peer lifecycle"). Spawned by the daemon, one per remote
        // session it mirrors: it binds that shadow's socket, publishes and
        // rewrites that shadow's registry record, and exits when its stdin
        // closes. A separate executable rather than a thread in the daemon
        // because the record's pid is parsed from its *filename*, so one process
        // can publish exactly one valid record — and because stdin EOF is then a
        // cleanup signal the kernel delivers even to a SIGKILLed daemon's
        // children.
        //
        // Deliberately NOT linked against TBDDaemonLib: the helper needs the
        // record shape and the frame codec, both of which live in TBDShared, and
        // nothing else. Its output is os.Logger, not stdout — stdout is the
        // frame channel back to the daemon.
        .executableTarget(
            name: "TBDPeerHelper",
            dependencies: [
                "TBDShared",
            ],
            path: "Sources/TBDPeerHelper"
        ),
        // One process per holder-transport session
        // (docs/specs/2026-08-30-pty-holder-session-transport-design.md). It
        // `forkpty()`s the job, owns the pty master for the session's life, and
        // hands a `dup` of it to whoever asks over SCM_RIGHTS — so the session
        // outlives the daemon that started it.
        //
        // A separate executable rather than a thread in the daemon for the
        // whole point of the design: the pty master must survive a daemon
        // restart, and a descriptor cannot outlive the process that holds it.
        //
        // Deliberately NOT linked against TBDDaemonLib. It needs the rendezvous
        // paths, the creation lock and the wire protocol, all of which live in
        // TBDShared, and nothing else.
        .executableTarget(
            name: "TBDHolder",
            dependencies: [
                "TBDShared",
            ],
            path: "Sources/TBDHolder"
        ),
        .systemLibrary(
            name: "CComrakFFI",
            path: "Sources/CComrakFFI"
        ),
        .executableTarget(
            name: "TBDApp",
            dependencies: [
                "TBDShared",
                "TBDAppIcon",
                "CComrakFFI",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Highlightr", package: "Highlightr"),
                .product(name: "SwiftUIIntrospect", package: "swiftui-introspect"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "TOMLKit", package: "TOMLKit"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            path: "Sources/TBDApp",
            resources: [
                .copy("Resources/Icons"),
                .copy("Resources/markdown-default.css"),
                .copy("Resources/markdown-stylesheets.md"),
            ],
            // Swift 6.2 WMO-debug OOM workaround — see noWMODebugWorkaround
            // above. TBDApp is the larger of the two memory-heavy modules
            // (SwiftUI view bodies + MarkdownUI + SwiftTerm).
            swiftSettings: noWMODebugWorkaround,
            linkerSettings: [
                // The archive is a committed build input at a package-relative path.
                // Regenerate with scripts/build-rust.sh.
                .unsafeFlags(["-Lrust/comrak-ffi/lib", "-lcomrak_ffi"])
            ]
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
            dependencies: ["TBDShared"],
            // `.process`, not `.copy`: process flattens the directory's files
            // into the bundle root, which is where
            // `Bundle.module.url(forResource:withExtension:)` looks. `.copy`
            // would preserve the `Fixtures/` subdirectory and every lookup
            // would return nil.
            resources: [.process("Fixtures")]
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
                // TmuxBridge (app side) drives a real tmux server in
                // TmuxBridgeViewSessionLiveTests, which makes it tier 3.
                "TBDApp",
                // Load-bearing for the same reason `TBDPeerHelperTests` depends
                // on `TBDPeerHelper` below: the suites under `Holder/` spawn the
                // real `TBDHolder` binary through the real `HolderSpawner`, so
                // the product has to be built and sit in the same products
                // directory as the test bundle. Nothing here imports it.
                "TBDHolder",
                .product(name: "GRDB", package: "GRDB.swift"),
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
                "TestSupport",
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
        // The shadow peer helper's own suite. It depends on the EXECUTABLE
        // target for two reasons: `@testable import` reaches the parsing and
        // attribution-stripping helpers, and — the load-bearing one — the
        // integration tests spawn the real `TBDPeerHelper` binary, bind its
        // real socket and read its real record, so the product has to be built
        // and sit in the same products directory as the test bundle.
        //
        // Left in the fast PARALLEL pass deliberately, though it spawns a
        // child: `Tests/CLAUDE.md` § "Test tiers" makes the failure asymmetry
        // the tie-breaker — leaving a heavy suite in the parallel pass is the
        // status quo, while moving a suite into the serial pass taxes every PR
        // forever. The suite is `.serialized`, each helper lives for
        // milliseconds, and every wait is a bounded poll.
        .testTarget(
            name: "TBDPeerHelperTests",
            dependencies: [
                "TBDPeerHelper",
                "TBDShared",
            ]
        ),
        // The holder's own suite. Like `TBDPeerHelperTests` above, its
        // dependency on the EXECUTABLE target is load-bearing rather than
        // cosmetic: the tests spawn the real `TBDHolder` binary, so the product
        // has to be built and sit in the same products directory as the test
        // bundle. `@testable import` reaching the holder's internals is the
        // lesser half.
        .testTarget(
            name: "TBDHolderTests",
            dependencies: [
                "TBDHolder",
                "TBDShared",
            ]
        ),
    ]
)
