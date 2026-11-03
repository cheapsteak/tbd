import AppKit
import Testing
@testable import TBDApp

/// Tests for `WorktreeRowPresentation.loadIcon` — the cached sidebar PR status
/// icon loader. The cache keeps the `NSImage` a row cell is handed
/// identity-stable, so setting the same icon again hands the cell the image it
/// already holds, and the bundle read runs once per icon.
@MainActor
@Suite("WorktreeRowIconCache")
struct WorktreeRowIconCacheTests {

    @Test("loadIcon returns a non-nil template image for a bundled PR icon")
    func loadsKnownIcon() {
        // "git-pull-request" is a real resource in Sources/TBDApp/Resources/Icons
        // and the name PRStatusPresentation uses for open PRs.
        let image = WorktreeRowPresentation.loadIcon("git-pull-request")
        #expect(image != nil)
        #expect(image?.isTemplate == true)
    }

    @Test("loadIcon returns the identical instance on repeated calls")
    func returnsSameInstance() {
        let first = WorktreeRowPresentation.loadIcon("git-merge")
        let second = WorktreeRowPresentation.loadIcon("git-merge")
        #expect(first != nil)
        #expect(first === second)
    }

    @Test("loadIcon returns nil for an unknown icon name")
    func unknownIconIsNil() {
        #expect(WorktreeRowPresentation.loadIcon("no-such-icon") == nil)
    }
}
