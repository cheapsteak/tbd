import AppKit
import SwiftUI
import Testing

/// What `OffscreenHost.tearDown()` has to guarantee, and — just as important —
/// what it must not try to guarantee.
///
/// It has to let go of the hosted tree: a mounted `NSHostingView` and the
/// ground under it are the expensive half of a mount, and a suite that mounts
/// several per run must not carry them all to the end of the process.
///
/// It must not try to take the window out of `NSApp.windows`. Measured, against
/// a bare `NSWindow` with no SwiftUI in it at all: a window that has been
/// ordered front is never deallocated in this process, and the one gesture that
/// does remove it from that list — flipping `isReleasedWhenClosed` before
/// `close()` — removes it by sending a `release` ARC never balanced. That is an
/// over-release of an object still owned, and its use-after-free lands later,
/// in whatever unrelated test is running when the last real owner lets go: it
/// reached CI as a signal 11 in a whole-suite run while every narrow local run
/// stayed green.
@Suite("offscreen host lifecycle")
@MainActor
struct OffscreenHostLifecycleTests {
    /// Small on purpose: nothing here asks a layout question.
    private static let hostSize = NSSize(width: 120, height: 80)

    @Test("tearDown releases the hosted tree while the host is still alive")
    func tearDownReleasesTheHostedTree() {
        // The mount happens inside a pool of its own, and everything the weak
        // references are read against happens outside it. Mounting hands out
        // autoreleased references — from `NSHostingView`'s own construction as
        // much as from these accessors — and in the enclosing pool those
        // outlive the whole test, so the tree would read as "still alive"
        // however thorough teardown was.
        var host: OffscreenHost<Color>?
        weak var hostingView: NSView?
        weak var ground: NSView?
        autoreleasepool {
            let mounted = OffscreenHost(root: Color.blue, size: Self.hostSize)
            hostingView = mounted.hostingView
            ground = mounted.contentView
            mounted.tearDown()
            // Kept alive deliberately: teardown itself has to drop the tree,
            // not the host's own deallocation at the end of a test.
            host = mounted
        }
        #expect(pumpUntilReleased { hostingView }, "tearDown() left the hosting view mounted")
        #expect(pumpUntilReleased { ground }, "tearDown() left the ground view mounted")
        #expect(host != nil, "the host under test was released early")
    }

    @Test("tearDown leaves the window for AppKit to release")
    func tearDownLeavesTheWindowForAppKitToRelease() {
        let host = OffscreenHost(root: Color.blue, size: Self.hostSize)
        // Strong on purpose, and safe precisely because teardown does not ask
        // AppKit to release a window this reference owns a share of.
        let window = host.window

        host.tearDown()

        #expect(window.isVisible == false, "tearDown() left the window on screen")
        #expect(window.contentView == nil, "tearDown() left the hosted tree in the window")
        // Membership in `NSApp.windows` is the observable signature of the
        // ownership question. Measured: an ordered-front window is never
        // deallocated in this process, so a correct teardown leaves it in that
        // list, and the one gesture that removes it — flipping
        // `isReleasedWhenClosed` before `close()` — removes it by sending a
        // `release` ARC never balanced. A window missing from the list here has
        // been released once too often, and the use-after-free lands later.
        #expect(
            NSApp.windows.contains(window),
            "tearDown() over-released the window — AppKit dropped it from NSApp.windows")
    }

    @Test("tearDown is idempotent")
    func tearDownIsIdempotent() {
        let host = OffscreenHost(root: Color.blue, size: Self.hostSize)
        let window = host.window

        host.tearDown()
        host.tearDown()

        #expect(window.isVisible == false, "a second tearDown() put the window back")
        #expect(
            NSApp.windows.contains(window),
            "a second tearDown() released the window a second time")
    }
}
