import Testing
import Foundation
@testable import TBDApp

@Test func sourceWorktreePathResolver_sidecarPresent_returnsTrimmedContents() {
    let bundleURL = URL(fileURLWithPath: "/Applications/TBD.app")
    let resolved = SourceWorktreePathResolver.resolve(
        bundleURL: bundleURL,
        executablePath: "/Applications/TBD.app/Contents/MacOS/TBDApp",
        sidecarReader: { url in
            #expect(url.path == "/Applications/TBD.app/Contents/SourceWorktreePath.txt")
            return "  /Users/me/tbd/worktrees/foo  \n"
        }
    )
    #expect(resolved == "/Users/me/tbd/worktrees/foo")
}

@Test func sourceWorktreePathResolver_sidecarAbsent_fallsBackToExecPath() {
    let bundleURL = URL(fileURLWithPath: "/some/worktree/.build/debug/TBD.app")
    let resolved = SourceWorktreePathResolver.resolve(
        bundleURL: bundleURL,
        executablePath: "/some/worktree/.build/debug/TBDApp",
        sidecarReader: { _ in nil }
    )
    #expect(resolved == "/some/worktree")
}

@Test func sourceWorktreePathResolver_sidecarEmpty_fallsBackToExecPath() {
    let bundleURL = URL(fileURLWithPath: "/some/worktree/.build/debug/TBD.app")
    let resolved = SourceWorktreePathResolver.resolve(
        bundleURL: bundleURL,
        executablePath: "/some/worktree/.build/debug/TBDApp",
        sidecarReader: { _ in "   \n  " }
    )
    #expect(resolved == "/some/worktree")
}

@Test func sourceWorktreePathResolver_neitherAvailable_returnsNil() {
    let bundleURL = URL(fileURLWithPath: "/Applications/TBD.app")
    let resolved = SourceWorktreePathResolver.resolve(
        bundleURL: bundleURL,
        executablePath: "/Applications/TBD.app/Contents/MacOS/TBDApp",
        sidecarReader: { _ in nil }
    )
    #expect(resolved == nil)
}

@Test func sourceWorktreePathResolver_nilExecPathAndNoSidecar_returnsNil() {
    let bundleURL = URL(fileURLWithPath: "/Applications/TBD.app")
    let resolved = SourceWorktreePathResolver.resolve(
        bundleURL: bundleURL,
        executablePath: nil,
        sidecarReader: { _ in nil }
    )
    #expect(resolved == nil)
}

@Test func sourceWorktreePathResolver_sidecarPrefersOverExecPath() {
    // When both sidecar and exec path are available, sidecar should win
    let bundleURL = URL(fileURLWithPath: "/Applications/TBD.app")
    let resolved = SourceWorktreePathResolver.resolve(
        bundleURL: bundleURL,
        executablePath: "/fallback/worktree/.build/debug/TBDApp",
        sidecarReader: { _ in "/preferred/worktree" }
    )
    #expect(resolved == "/preferred/worktree")
}
