import Testing
import Foundation
@testable import TBDApp

@Test func resolveSourceWorktreePath_sidecarPresent_returnsTrimmedContents() {
    let bundleURL = URL(fileURLWithPath: "/Applications/TBD.app")
    let resolved = StatusBarView.resolveSourceWorktreePath(
        bundleURL: bundleURL,
        executablePath: "/Applications/TBD.app/Contents/MacOS/TBDApp",
        sidecarReader: { url in
            #expect(url.path == "/Applications/TBD.app/Contents/SourceWorktreePath.txt")
            return "  /Users/me/tbd/worktrees/foo  \n"
        }
    )
    #expect(resolved == "/Users/me/tbd/worktrees/foo")
}

@Test func resolveSourceWorktreePath_sidecarAbsent_fallsBackToExecPath() {
    let bundleURL = URL(fileURLWithPath: "/some/worktree/.build/debug/TBD.app")
    let resolved = StatusBarView.resolveSourceWorktreePath(
        bundleURL: bundleURL,
        executablePath: "/some/worktree/.build/debug/TBDApp",
        sidecarReader: { _ in nil }
    )
    #expect(resolved == "/some/worktree")
}

@Test func resolveSourceWorktreePath_sidecarEmpty_fallsBackToExecPath() {
    let bundleURL = URL(fileURLWithPath: "/some/worktree/.build/debug/TBD.app")
    let resolved = StatusBarView.resolveSourceWorktreePath(
        bundleURL: bundleURL,
        executablePath: "/some/worktree/.build/debug/TBDApp",
        sidecarReader: { _ in "   \n  " }
    )
    #expect(resolved == "/some/worktree")
}

@Test func resolveSourceWorktreePath_neitherAvailable_returnsNil() {
    let bundleURL = URL(fileURLWithPath: "/Applications/TBD.app")
    let resolved = StatusBarView.resolveSourceWorktreePath(
        bundleURL: bundleURL,
        executablePath: "/Applications/TBD.app/Contents/MacOS/TBDApp",
        sidecarReader: { _ in nil }
    )
    #expect(resolved == nil)
}

@Test func resolveSourceWorktreePath_nilExecPathAndNoSidecar_returnsNil() {
    let bundleURL = URL(fileURLWithPath: "/Applications/TBD.app")
    let resolved = StatusBarView.resolveSourceWorktreePath(
        bundleURL: bundleURL,
        executablePath: nil,
        sidecarReader: { _ in nil }
    )
    #expect(resolved == nil)
}
