import Foundation
import Testing
@testable import TBDApp

/// Tier 1. Whether the app should overwrite its own `PATH` with the one
/// `scripts/restart.sh` recorded in the bundle's `LSEnvironment`.
@Suite struct LaunchEnvironmentTests {

    private let bundlePATH = "/Users/test/.local/bin:/opt/homebrew/bin:/usr/bin:/bin"

    @Test func noBundlePATHMeansNothingToAdopt() {
        #expect(LaunchEnvironment.pathToAdopt(currentPATH: "/usr/bin:/bin", bundlePATH: nil) == nil)
        #expect(LaunchEnvironment.pathToAdopt(currentPATH: "/usr/bin:/bin", bundlePATH: "") == nil)
    }

    /// The terminal launch: the inherited `PATH` is a superset, so adopting the
    /// plist's would discard entries it never knew about.
    @Test func aCurrentPATHThatAlreadyCoversTheBundlePATHIsKept() {
        #expect(LaunchEnvironment.pathToAdopt(
            currentPATH: "/Users/me/shims:" + bundlePATH,
            bundlePATH: bundlePATH
        ) == nil)
        #expect(LaunchEnvironment.pathToAdopt(
            currentPATH: bundlePATH, bundlePATH: bundlePATH
        ) == nil)
        // Order is not what "covers" means — the same directories reshuffled
        // still cover, and reshuffling them back would fight the user's shell.
        #expect(LaunchEnvironment.pathToAdopt(
            currentPATH: "/bin:/usr/bin:/opt/homebrew/bin:/Users/test/.local/bin",
            bundlePATH: bundlePATH
        ) == nil)
    }

    /// The login relaunch: launchd's bare `PATH` is missing Homebrew, so the
    /// bundle's contract wins.
    @Test func aBarePATHAdoptsTheBundlePATH() {
        #expect(LaunchEnvironment.pathToAdopt(
            currentPATH: "/usr/bin:/bin:/usr/sbin:/sbin", bundlePATH: bundlePATH
        ) == bundlePATH)
        #expect(LaunchEnvironment.pathToAdopt(
            currentPATH: nil, bundlePATH: bundlePATH
        ) == bundlePATH)
        #expect(LaunchEnvironment.pathToAdopt(
            currentPATH: "", bundlePATH: bundlePATH
        ) == bundlePATH)
    }

    /// One missing directory is enough — that is the whole failure, since
    /// `git-lfs` lives in exactly one of them.
    @Test func oneMissingDirectoryIsEnoughToAdopt() {
        #expect(LaunchEnvironment.pathToAdopt(
            currentPATH: "/Users/test/.local/bin:/usr/bin:/bin",
            bundlePATH: bundlePATH
        ) == bundlePATH)
    }

    @Test func adoptInstallsThePlistPATHWhenTheLaunchPATHIsBare() {
        var installed: [String] = []
        let adopted = LaunchEnvironment.adoptBundlePATHIfNeeded(
            infoDictionary: ["LSEnvironment": ["PATH": bundlePATH]],
            currentPATH: "/usr/bin:/bin:/usr/sbin:/sbin",
            install: { installed.append($0) }
        )

        #expect(adopted == bundlePATH)
        #expect(installed == [bundlePATH])
    }

    @Test func adoptInstallsNothingWhenThereIsNothingToAdopt() {
        var installed: [String] = []
        func adopt(_ info: [String: Any]?, current: String?) -> String? {
            LaunchEnvironment.adoptBundlePATHIfNeeded(
                infoDictionary: info, currentPATH: current, install: { installed.append($0) }
            )
        }

        // Unbundled execution — no Info.plist at all.
        #expect(adopt(nil, current: "/usr/bin:/bin") == nil)
        // A bundle built without the key.
        #expect(adopt(["CFBundleIdentifier": "com.example.test"], current: "/usr/bin:/bin") == nil)
        // The key present but not a string.
        #expect(adopt(["LSEnvironment": ["PATH": 42]], current: "/usr/bin:/bin") == nil)
        // Already covered.
        #expect(adopt(["LSEnvironment": ["PATH": bundlePATH]], current: bundlePATH) == nil)

        #expect(installed.isEmpty)
    }

    // MARK: - Cross-source consistency

    /// The adoption only works because of where it sits in `TBDAppMain`.
    ///
    /// Swift evaluates a struct's stored-property default expressions in source
    /// order, `setenv` reaches only children born after it, and `appState`'s
    /// initializer is what spawns the daemon. So `adoptedLaunchPATH` must be
    /// declared above `appState` — and nothing in the compiler says so. Moving the
    /// property down, or adding a new subprocess-spawning property above it, would
    /// leave a daemon on launchd's bare `PATH` again with every test still green.
    /// This is the tie: it reads the source file and fails on the wrong order.
    @Test func adoptedLaunchPATHIsDeclaredBeforeTheAppStateThatSpawnsTheDaemon() throws {
        // Walk up from this source file to the repo root (the dir holding `Sources/`).
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let relativeSourcePath = "Sources/TBDApp/TBDApp.swift"
        while !FileManager.default.fileExists(atPath: dir.appendingPathComponent(relativeSourcePath).path) {
            let parent = dir.deletingLastPathComponent()
            // Reached the filesystem root without finding it — skip rather than
            // fail, so a packaged/sandboxed test run doesn't red for the wrong reason.
            guard parent.path != dir.path else { return }
            dir = parent
        }
        let source = try String(
            contentsOf: dir.appendingPathComponent(relativeSourcePath), encoding: .utf8
        )

        let adoptionDeclaration = "private let adoptedLaunchPATH"
        let appStateDeclaration = "private var appState"

        // Both must be found, and found once: a renamed property would otherwise
        // make this check pass by matching nothing.
        #expect(source.components(separatedBy: adoptionDeclaration).count == 2, """
        expected exactly one `\(adoptionDeclaration)` declaration in \
        \(relativeSourcePath) — was the property renamed or removed?
        """)
        #expect(source.components(separatedBy: appStateDeclaration).count == 2, """
        expected exactly one `\(appStateDeclaration)` declaration in \
        \(relativeSourcePath) — was the property renamed or removed?
        """)

        let adoption = try #require(source.range(of: adoptionDeclaration))
        let appState = try #require(source.range(of: appStateDeclaration))

        #expect(adoption.lowerBound < appState.lowerBound, """
        `\(adoptionDeclaration)` must be declared BEFORE `\(appStateDeclaration)` in \
        \(relativeSourcePath). Stored-property defaults are evaluated in source \
        order, and AppState's initializer spawns the daemon, which inherits this \
        process's PATH. Declared after it, the setenv lands too late and a daemon \
        started by a LaunchServices relaunch keeps launchd's bare PATH — the bug \
        this property exists to fix.
        """)
    }
}
