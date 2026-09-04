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
}
