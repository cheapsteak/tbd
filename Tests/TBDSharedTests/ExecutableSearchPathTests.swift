import Foundation
import Testing
@testable import TBDShared

/// Tier 1. The `PATH` floor a GUI-launched process needs when LaunchServices
/// hands it launchd's bare `/usr/bin:/bin:/usr/sbin:/sbin`.
@Suite struct ExecutableSearchPathTests {

    private let home = "/Users/test"

    @Test func bareLaunchdPATHGainsTheFallbacksAfterWhatItAlreadyHad() {
        let augmented = ExecutableSearchPath.augmented(
            "/usr/bin:/bin:/usr/sbin:/sbin", homeDirectory: home
        )

        #expect(augmented == [
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            "/Users/test/.local/bin",
            "/Users/test/.volta/bin",
            "/Users/test/.cargo/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
        ].joined(separator: ":"))
    }

    /// The failure that motivated this: git could not find `git-lfs`, which
    /// Homebrew installs into `/opt/homebrew/bin`.
    @Test func homebrewIsReachableFromABareLaunchdPATH() {
        let directories = ExecutableSearchPath
            .augmented("/usr/bin:/bin:/usr/sbin:/sbin", homeDirectory: home)
            .split(separator: ":").map(String.init)
        #expect(directories.contains("/opt/homebrew/bin"))
    }

    /// The other branch: a `PATH` that already covers every fallback is
    /// returned unchanged, so a real login shell's ordering is never disturbed.
    @Test func aPATHThatAlreadyCoversTheFallbacksIsUnchanged() {
        let full = (["/Users/test/bin"]
            + ExecutableSearchPath.fallbackDirectories(homeDirectory: home))
            .joined(separator: ":")

        #expect(ExecutableSearchPath.augmented(full, homeDirectory: home) == full)
    }

    /// Fallbacks are appended, never promoted: a developer's shim directory
    /// keeps its precedence over the system copy of the same tool.
    @Test func existingEntriesKeepTheirOrderAndPrecedence() {
        let augmented = ExecutableSearchPath
            .augmented("/opt/homebrew/bin:/Users/test/shims:/usr/bin", homeDirectory: home)
            .split(separator: ":").map(String.init)

        #expect(Array(augmented.prefix(3)) == ["/opt/homebrew/bin", "/Users/test/shims", "/usr/bin"])
        // The fallback list also names /opt/homebrew/bin and /usr/bin; neither
        // is re-appended, so neither loses its position to a later duplicate.
        #expect(augmented.firstIndex(of: "/opt/homebrew/bin") == 0)
        #expect(augmented.firstIndex(of: "/usr/bin") == 2)
    }

    @Test func repeatedDirectoriesAppearOnceAndAugmentingIsIdempotent() {
        let once = ExecutableSearchPath.augmented("/usr/bin:/usr/bin:/bin", homeDirectory: home)
        let twice = ExecutableSearchPath.augmented(once, homeDirectory: home)

        #expect(once == twice)
        let directories = once.split(separator: ":").map(String.init)
        #expect(directories.count == Set(directories).count)
    }

    @Test func homeRelativeDirectoriesExpandAgainstTheGivenHome() {
        let augmented = ExecutableSearchPath.augmented(nil, homeDirectory: "/Users/x")

        #expect(augmented.hasPrefix("/Users/x/.local/bin:/Users/x/.volta/bin:/Users/x/.cargo/bin:"))
        #expect(!augmented.contains("/Users/test"))
    }

    @Test func anEmptyOrMissingPATHYieldsTheFallbacksAlone() {
        let expected = ExecutableSearchPath
            .fallbackDirectories(homeDirectory: home)
            .joined(separator: ":")

        #expect(ExecutableSearchPath.augmented(nil, homeDirectory: home) == expected)
        #expect(ExecutableSearchPath.augmented("", homeDirectory: home) == expected)
        // Empty segments (a stray leading or doubled colon) are dropped rather
        // than becoming an entry meaning "the current directory".
        #expect(ExecutableSearchPath.augmented("::", homeDirectory: home) == expected)
    }
}
