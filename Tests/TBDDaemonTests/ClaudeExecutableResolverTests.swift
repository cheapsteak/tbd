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

    @Test func aRelativeOverrideIsIgnoredRatherThanResolved() throws {
        let path = try ClaudeExecutableResolver.resolve(
            configuredOverride: "bin/claude",
            searchPath: "/real",
            isExecutable: { $0 == "/real/claude" })
        #expect(path == "/real/claude")
    }

    @Test func nothingExecutableAnywhereThrowsNotFound() {
        #expect(throws: ClaudeExecutableResolver.ResolveError.notFound(searchPath: "/a:/b")) {
            try ClaudeExecutableResolver.resolve(
                configuredOverride: nil, searchPath: "/a:/b", isExecutable: { _ in false })
        }
    }
}
