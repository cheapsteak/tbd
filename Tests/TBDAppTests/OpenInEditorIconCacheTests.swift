import AppKit
import Testing
@testable import TBDApp

/// Tests for `OpenInEditorButton.appIcon(forPath:)` — the cached editor app
/// icon loader. Mirrors `WorktreeRowIconCacheTests`: the cache exists so the
/// NSImage handed to `Image(nsImage:)` is identity-stable across body
/// evaluations; a fresh `NSWorkspace.icon(forFile:)` instance per render
/// rebuilt every pinned editor's icon layer on each hover toggle.
@MainActor
@Suite("OpenInEditorIconCache")
struct OpenInEditorIconCacheTests {

    @Test("appIcon returns the identical instance on repeated calls")
    func returnsSameInstance() {
        // NSWorkspace.icon(forFile:) never returns nil — unknown paths get the
        // generic document icon — so any stable path exercises the cache.
        let path = "/System/Library/CoreServices/Finder.app"
        let first = OpenInEditorButton.appIcon(forPath: path)
        let second = OpenInEditorButton.appIcon(forPath: path)
        #expect(first === second)
    }

    @Test("appIcon caches per path, not one image for all paths")
    func distinctPathsGetDistinctEntries() {
        let finder = OpenInEditorButton.appIcon(forPath: "/System/Library/CoreServices/Finder.app")
        let bin = OpenInEditorButton.appIcon(forPath: "/bin")
        #expect(finder !== bin)
    }
}
