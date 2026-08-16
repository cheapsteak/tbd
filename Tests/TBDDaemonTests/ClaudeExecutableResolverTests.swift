import Foundation
import Testing
@testable import TBDDaemonLib

// Tier 1: pure over injected values — never stats the real filesystem.
@Suite("ClaudeExecutableResolver")
struct ClaudeExecutableResolverTests {
    @Test func aConfiguredAbsoluteOverrideWins() throws {
        let path = try ClaudeExecutableResolver.resolve(
            configuredOverride: "/opt/acme/claude",
            searchPath: "/usr/bin:/bin",
            isExecutable: { $0 == "/opt/acme/claude" || $0 == "/usr/bin/claude" })
        #expect(path == "/opt/acme/claude")
    }

    @Test func absolutePathEntriesAreSearchedInOrder() throws {
        let path = try ClaudeExecutableResolver.resolve(
            configuredOverride: nil,
            searchPath: "/first:/second",
            isExecutable: { $0 == "/first/claude" || $0 == "/second/claude" })
        #expect(path == "/first/claude")
    }

    /// Relative and empty entries are ignored outright: resolving them
    /// against the daemon's current directory could execute an untrusted
    /// worktree-local `claude`.
    @Test func relativeAndEmptyPathEntriesAreIgnored() throws {
        let path = try ClaudeExecutableResolver.resolve(
            configuredOverride: nil,
            searchPath: "::.:node_modules/.bin:/real",
            isExecutable: { $0.hasSuffix("/claude") })
        #expect(path == "/real/claude")
    }

    /// Distinct from `relativeAndEmptyPathEntriesAreIgnored`: here both PATH
    /// entries are valid absolute directories, but only the second one
    /// actually has an executable `claude` in it.
    @Test func aLaterAbsoluteEntryWinsWhenAnEarlierOneLacksTheExecutable() throws {
        let path = try ClaudeExecutableResolver.resolve(
            configuredOverride: nil,
            searchPath: "/first:/second",
            isExecutable: { $0 == "/second/claude" })
        #expect(path == "/second/claude")
    }

    /// `isExecutable` also matches the relative spelling, so this
    /// discriminates the `hasPrefix("/")` guard itself: an implementation
    /// that dropped the guard and called `isExecutable("bin/claude")` would
    /// get `true` here (not a coincidental `false`) and resolve to the wrong
    /// path, so the test would fail rather than passing for the wrong
    /// reason.
    @Test func aRelativeOverrideIsIgnoredRatherThanResolved() throws {
        let path = try ClaudeExecutableResolver.resolve(
            configuredOverride: "bin/claude",
            searchPath: "/real",
            isExecutable: { $0 == "/real/claude" || $0 == "bin/claude" })
        #expect(path == "/real/claude")
    }

    /// An absolute override that fails the executable check is a hard
    /// failure, not a silent fallback to PATH search: someone who set an
    /// explicit override did so because the wrong binary was being picked
    /// up, so resolving to a different `claude` on a typo would defeat the
    /// override's purpose with no diagnostic. `/real/claude` is a valid PATH
    /// candidate in this same fixture, so a resolver that incorrectly fell
    /// through would succeed silently instead of throwing — that's the
    /// discriminating half of this test, not just "it throws something".
    @Test func anAbsoluteOverrideThatIsNotExecutableThrowsRatherThanFallingThroughToPATH() {
        #expect(throws: ClaudeExecutableResolver.ResolveError.invalidOverride(
            environmentKey: ClaudeExecutableResolver.executableOverrideEnvironmentKey,
            value: "/opt/acme/claude")) {
            try ClaudeExecutableResolver.resolve(
                configuredOverride: "/opt/acme/claude",
                searchPath: "/real",
                isExecutable: { $0 == "/real/claude" })
        }
    }

    @Test func nothingExecutableAnywhereThrowsNotFound() {
        #expect(throws: ClaudeExecutableResolver.ResolveError.notFound(searchPath: "/a:/b")) {
            try ClaudeExecutableResolver.resolve(
                configuredOverride: nil, searchPath: "/a:/b", isExecutable: { _ in false })
        }
    }
}
