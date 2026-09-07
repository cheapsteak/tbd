import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

/// **The composer's controls can be found by name.** A GUI driver — cua-driver,
/// an XCUITest-shaped tool, the offscreen harness in this suite — reaches a
/// control through the accessibility tree, and the only stable handle that tree
/// carries is the identifier. Labels are not that handle: the send button is
/// named after whichever terminal it points at, the blocked banner says whatever
/// the daemon carried, and a thumbnail's sentence changes with its number.
///
/// So this suite mounts the real `MessageComposerView` in a real (offscreen)
/// window, walks the accessibility tree of the hosting view, and asserts the
/// identifiers are actually in it. Asserting on the *tree* rather than on the
/// source is the whole point: `.accessibilityIdentifier` on a container SwiftUI
/// declines to make an element at all is a no-op that reads perfectly well in a
/// diff, and every assertion here fails against the composer as it stood before
/// the identifiers were added.
@MainActor
@Suite("composer accessibility identifiers")
struct ComposerAccessibilityIdentifierTests {

    // MARK: - Fixtures

    private static let inventory = TerminalCompletionsResult(
        commands: (0..<20).map {
            CompletionCommand(
                name: "compact\($0)", description: "Compact the conversation, take \($0)")
        },
        agents: [], freshness: .fresh, source: .probe)

    private func makeWorktree() -> LocalWorktree {
        LocalWorktree(Worktree(
            id: UUID(), repoID: UUID(), name: "wt", displayName: "WT", branch: "main",
            path: "/tmp/wt", status: .active, tmuxServer: "test-server", location: .local))!
    }

    private func makeTerminal(worktreeID: UUID) -> Terminal {
        Terminal(
            id: UUID(), worktreeID: worktreeID, tmuxWindowID: "@1", tmuxPaneID: "%1",
            kind: .claude)
    }

    // MARK: - The harness

    /// A mounted composer in an offscreen window, and what has to be torn down
    /// after it. The shape is `CompletionOverlayPlacementTests`', for the same
    /// reason: SwiftUI runs `.task` and lays a hierarchy out only for a view in
    /// a window that has been shown.
    private struct Mounted {
        let window: NSWindow
        let host: NSHostingView<AnyView>
        let state: AppState
        let suiteName: String

        func tearDown() {
            window.orderOut(nil)
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
    }

    private func mount(
        state composerState: ComposerState = .running,
        prepare: (ComposerDraft) -> Void = { _ in }
    ) -> Mounted {
        _ = NSApplication.shared
        // Before the hosting view is made: SwiftUI builds no accessibility tree
        // at all until a client has asked for one.
        enableAccessibilityBridge()
        let suiteName = "ComposerAccessibilityIdentifierTests-\(UUID().uuidString)"
        let appState = AppState(userDefaults: UserDefaults(suiteName: suiteName)!)
        appState.composerCompletionsFetcher = { _ in Self.inventory }
        let worktree = makeWorktree()
        let terminal = makeTerminal(worktreeID: worktree.id)
        prepare(appState.composerDraft(for: terminal.id))

        let root = AnyView(
            VStack(spacing: 0) {
                // Stands in for the transcript above the composer, so the
                // completion list has the region it opens out over.
                Color.clear
                MessageComposerView(
                    terminal: terminal, worktree: worktree, state: composerState)
            }
            .environment(appState))

        let host = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 720, height: 520),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        return Mounted(window: window, host: host, state: appState, suiteName: suiteName)
    }

    /// One pump of both pumps SwiftUI needs: the main run loop, which drives
    /// AppKit's layout and display, and the cooperative pool, which drives
    /// `.task`.
    private func pump() async {
        spinRunLoop()
        await Task.yield()
    }

    /// Synchronous on purpose: `RunLoop.run(_:before:)` is unavailable from an
    /// async context, and one turn of the main run loop is exactly what AppKit
    /// needs to lay out and display what SwiftUI just published.
    private func spinRunLoop() {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.004))
    }

    /// Poll, bounded, for the tree to hold everything named. Returns the last
    /// set it saw either way, so a failure can print what was actually there.
    private func settle(
        _ mounted: Mounted, until wanted: Set<String>, maxPumps: Int = 250
    ) async -> Set<String> {
        var seen = axIdentifiers(in: mounted.host)
        for _ in 0..<maxPumps {
            if wanted.isSubset(of: seen) { return seen }
            await pump()
            seen = axIdentifiers(in: mounted.host)
        }
        return seen
    }

    /// The same poll for a family of identifiers rather than exact names: the
    /// completion rows are named after the commands the ranker chose, which is
    /// not something a test should have to predict.
    private func settle(
        _ mounted: Mounted, untilAnyHasPrefix prefix: String, maxPumps: Int = 250
    ) async -> Set<String> {
        var seen = axIdentifiers(in: mounted.host)
        for _ in 0..<maxPumps {
            if seen.contains(where: { $0.hasPrefix(prefix) }) { return seen }
            await pump()
            seen = axIdentifiers(in: mounted.host)
        }
        return seen
    }

    private func report(_ mounted: Mounted, _ seen: Set<String>) -> Comment {
        Comment(rawValue: """
            the tree held: \(seen.sorted().joined(separator: ", "))
            \(axTreeDescription(in: mounted.host))
            """)
    }

    // MARK: - The core controls

    /// The container, the field, and the button: what any driver needs before it
    /// can do anything at all with the composer.
    @Test func theComposerExposesItsContainerFieldAndSendButton() async throws {
        let mounted = mount()
        defer { mounted.tearDown() }
        let wanted: Set<String> = [
            ComposerAccessibility.root,
            ComposerAccessibility.field,
            ComposerAccessibility.send,
        ]
        let seen = await settle(mounted, until: wanted)
        #expect(wanted.isSubset(of: seen), report(mounted, seen))
    }

    // MARK: - The completion list

    /// The list and its rows, each row addressable on its own. A list that
    /// exposed only itself would let a driver see the menu and pick nothing out
    /// of it.
    @Test func theOpenMenuExposesItselfAndEachRow() async throws {
        let mounted = mount { $0.text = "/comp" }
        defer { mounted.tearDown() }
        let prefix = ComposerAccessibility.menuRow(command: "")
        let seen = await settle(mounted, untilAnyHasPrefix: prefix)

        #expect(seen.contains(ComposerAccessibility.menu), report(mounted, seen))
        let rows = seen.filter { $0.hasPrefix(prefix) }
        #expect(!rows.isEmpty, report(mounted, seen))
        // Named by command, so two rows are two identifiers rather than one
        // repeated — the property that makes a specific row selectable.
        #expect(rows.count > 1, report(mounted, seen))
        #expect(
            rows.contains(ComposerAccessibility.menuRow(command: "compact0")),
            report(mounted, seen))
    }

    // MARK: - The attachment strip

    /// A staged image, its thumbnail, and its own remove button. The button is
    /// the one that had to be argued for: an attachment thumbnail was a
    /// `.combine`d element, which folds the x into the picture and leaves
    /// nothing to press.
    @Test func aStagedImageExposesItsThumbnailAndItsRemoveButton() async throws {
        let mounted = mount { draft in
            draft.stage(path: "/tmp/tbd-composer-a11y-nonexistent.png", id: UUID())
        }
        defer { mounted.tearDown() }
        let wanted: Set<String> = [
            ComposerAccessibility.attachments,
            ComposerAccessibility.attachmentItem(number: 1),
            ComposerAccessibility.attachmentRemove(number: 1),
        ]
        let seen = await settle(mounted, until: wanted)
        #expect(wanted.isSubset(of: seen), report(mounted, seen))
    }

    // MARK: - The two banners

    /// Blocked: the sentence, and the button that gets somebody to the dialog.
    @Test func theBlockedBannerExposesItsMessageAndRevealButton() async throws {
        let mounted = mount(state: .blocked(message: "Claude is asking something"))
        defer { mounted.tearDown() }
        let wanted: Set<String> = [
            ComposerAccessibility.blockedMessage,
            ComposerAccessibility.blockedReveal,
        ]
        let seen = await settle(mounted, until: wanted)
        #expect(wanted.isSubset(of: seen), report(mounted, seen))
    }

    /// Not running: the note explaining that a send resumes the session.
    @Test func theNotRunningNoteIsExposed() async throws {
        let mounted = mount(state: .notRunning(exited: true))
        defer { mounted.tearDown() }
        let seen = await settle(mounted, until: [ComposerAccessibility.note])
        #expect(seen.contains(ComposerAccessibility.note), report(mounted, seen))
    }

    /// And the note is not there when the session is running — so the assertion
    /// above is about the state and not about a string that is always present.
    @Test func theNotRunningNoteIsAbsentWhileRunning() async throws {
        let mounted = mount()
        defer { mounted.tearDown() }
        _ = await settle(mounted, until: [ComposerAccessibility.field])
        let seen = axIdentifiers(in: mounted.host)
        #expect(!seen.contains(ComposerAccessibility.note), report(mounted, seen))
        #expect(!seen.contains(ComposerAccessibility.blockedReveal), report(mounted, seen))
    }
}

/// Every accessibility identifier in the tree rooted at `view`.
///
/// It walks the **accessibility** tree rather than the view hierarchy, because
/// the question is what an assistive client — or a GUI driver, which is one —
/// can actually reach. Two things about that tree are not obvious, and both had
/// to be found by measurement:
///
/// - **SwiftUI does not build one until a client asks for it.** Until then
///   `NSHostingView.accessibilityChildren()` is empty and a walk reports nothing
///   at all, whatever the view declares. `enableAccessibilityBridge()` flips the
///   switch a driver flips, and every mount here calls it.
/// - **SwiftUI's nodes are not `NSAccessibilityProtocol` in Swift's eyes.** They
///   are `SwiftUI.AccessibilityNode` objects that implement the accessibility
///   methods without declaring the Objective-C protocol, so `as?` fails on every
///   one of them and a typed walk silently sees an empty tree. They are reached
///   the way Objective-C reaches them instead: by selector.
///
/// Children are the union of what a node declares and, for an `NSView`, its
/// subviews — which is how AppKit itself resolves children for a view that has
/// not overridden them, and how the `NSTextView` inside the composer's
/// representable is reached.
///
/// **It lives here rather than in `Tests/TestSupport/`.** That target is the
/// daemon's support library — it depends on `TBDDaemonLib` and links into the
/// daemon suites — and this would drag AppKit into all of them for one
/// AppKit-only caller. As a top-level function in the app test target it is
/// already reusable by every suite in it.
@MainActor
func axIdentifiers(in view: NSView) -> Set<String> {
    var found: Set<String> = []
    axWalk(view) { node, _ in
        if let identifier = axAttribute(node, "accessibilityIdentifier") as? String,
           !identifier.isEmpty {
            found.insert(identifier)
        }
    }
    return found
}

/// The same walk as an indented outline, so a failure names the tree it found
/// rather than only the identifier it wanted.
@MainActor
func axTreeDescription(in view: NSView) -> String {
    var lines: [String] = []
    axWalk(view) { node, depth in
        let role = axAttribute(node, "accessibilityRole") as? String ?? "-"
        let identifier = (axAttribute(node, "accessibilityIdentifier") as? String)
            .map { " id=\($0)" } ?? ""
        let label = (axAttribute(node, "accessibilityLabel") as? String)
            .map { " label=\($0.prefix(40))" } ?? ""
        lines.append(
            String(repeating: "  ", count: depth) + "\(type(of: node))"
                + " role=\(role)\(identifier)\(label)")
    }
    return lines.joined(separator: "\n")
}

/// Ask SwiftUI and AppKit to build accessibility trees at all.
///
/// `AXEnhancedUserInterface` is the flag an assistive client sets on an
/// application when it attaches, and SwiftUI's macOS bridge waits for it: with
/// it clear, a hosting view's accessibility children are empty no matter what
/// the view declares. A GUI driver sets it by connecting; a test has to set it
/// itself, which is what makes this harness measure the same tree the driver
/// will see.
///
/// Process-wide and left on. Turning it back off would race the suite's own
/// parallel tests, and it costs nothing anywhere else — an accessibility tree
/// nobody reads changes no behavior.
@MainActor
func enableAccessibilityBridge() {
    let selector = Selector(("accessibilitySetValue:forAttribute:"))
    let app = NSApplication.shared
    guard app.responds(to: selector) else { return }
    _ = app.perform(selector, with: NSNumber(value: true), with: "AXEnhancedUserInterface")
}

/// One accessibility accessor, by selector — see `axIdentifiers(in:)` for why it
/// cannot simply be a method call on a typed value.
@MainActor
private func axAttribute(_ node: NSObject, _ name: String) -> Any? {
    guard node.responds(to: Selector((name))) else { return nil }
    return node.value(forKey: name)
}

/// Depth-first over the accessibility tree, visiting each node once.
@MainActor
private func axWalk(_ root: NSView, visit: (NSObject, Int) -> Void) {
    var seen = Set<ObjectIdentifier>()

    func children(of node: NSObject) -> [Any] {
        let declared = axAttribute(node, "accessibilityChildren") as? [Any] ?? []
        return declared + ((node as? NSView)?.subviews ?? [])
    }

    func step(_ element: Any, _ depth: Int) {
        guard let node = element as? NSObject else { return }
        guard seen.insert(ObjectIdentifier(node)).inserted else { return }
        visit(node, depth)
        for child in children(of: node) { step(child, depth + 1) }
    }

    step(root, 0)
}
