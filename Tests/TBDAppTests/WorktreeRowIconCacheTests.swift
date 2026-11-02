import AppKit
import Testing
@testable import TBDApp

/// Tests for `WorktreeRowView.loadIcon` — the cached sidebar PR status icon
/// loader. The cache exists so the NSImage handed to `Image(nsImage:)` is
/// identity-stable across body evaluations; a fresh instance per render made
/// every row's icon layer rebuild simultaneously (visible mass blink).
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
