import AppKit
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

/// The prompt rail's renderer switch and what each renderer mounts: the
/// UserDefaults key, the mount each renderer hands the table, the gutter the
/// transcript's container view keeps, and the SwiftUI renderer's state wired
/// to the coordinator.
@Suite("Prompt rail mount")
@MainActor
struct PromptRailMountTests {
    private typealias Container = PromptRailContainer<EmptyView>

    @Test("the renderer key reads unset and unknown values as the AppKit default")
    func rendererKeyThreeStates() throws {
        let suiteName = "prompt-rail-renderer-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(AppState.promptRailRendererDefault == .appKit)
        #expect(AppState.promptRailRenderer(defaults: defaults) == .appKit)

        defaults.set("swiftui", forKey: AppState.promptRailRendererKey)
        #expect(AppState.promptRailRenderer(defaults: defaults) == .swiftUI)

        defaults.set("bogus", forKey: AppState.promptRailRendererKey)
        #expect(AppState.promptRailRenderer(defaults: defaults) == .appKit)

        defaults.set("appkit", forKey: AppState.promptRailRendererKey)
        #expect(AppState.promptRailRenderer(defaults: defaults) == .appKit)
    }

    @Test("the Settings picker's binding writes the raw value the readers decode")
    func pickerWritesTheKey() throws {
        let suiteName = "prompt-rail-picker-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let stored = Binding<String?>(
            get: { defaults.string(forKey: AppState.promptRailRendererKey) },
            set: { defaults.set($0, forKey: AppState.promptRailRendererKey) }
        )
        let picker = AppState.promptRailRendererBinding(stored)

        #expect(picker.wrappedValue == .appKit)
        picker.wrappedValue = .swiftUI
        #expect(defaults.string(forKey: AppState.promptRailRendererKey) == "swiftui")
        #expect(AppState.promptRailRenderer(defaults: defaults) == .swiftUI)
        #expect(picker.wrappedValue == .swiftUI)

        picker.wrappedValue = .appKit
        #expect(AppState.promptRailRenderer(defaults: defaults) == .appKit)
    }

    @Test("each renderer gets its own mount")
    func mountPerRenderer() {
        let state = PromptRailState()
        let earlier = PromptRailEarlierHistory(hasEarlier: true, load: {})

        switch Container.mount(for: .appKit, earlier: earlier, state: state) {
        case .appKit(let carried):
            #expect(carried?.hasEarlier == true, "the AppKit mount dropped the earlier-history state")
        case .none, .swiftUI:
            Issue.record("the AppKit renderer did not get an AppKit mount")
        }

        switch Container.mount(for: .swiftUI, earlier: earlier, state: state) {
        case .swiftUI(let held):
            #expect(held === state, "the SwiftUI mount holds a different state")
        case .none, .appKit:
            Issue.record("the SwiftUI renderer did not get a SwiftUI mount")
        }
    }

    @Test("the container keeps the gutter its mount asks for")
    func containerGutterPerMount() {
        #expect(PromptRailMount.appKit(earlier: nil).containerGutter == PromptRailLayout.width)
        #expect(PromptRailMount.swiftUI(PromptRailState()).containerGutter == 0)
        #expect(PromptRailMount.none.containerGutter == 0)

        let railed = TranscriptContainerView(scrollView: NSScrollView(), leadingGutter: 20)
        railed.frame = NSRect(x: 0, y: 0, width: 680, height: 600)
        railed.layoutSubtreeIfNeeded()
        #expect(railed.scrollView.frame.minX == 20)
        #expect(railed.scrollView.frame.width == 660)
        #expect(railed.scrollView.frame.height == 600)

        let bare = TranscriptContainerView(scrollView: NSScrollView(), leadingGutter: 0)
        bare.frame = NSRect(x: 0, y: 0, width: 680, height: 600)
        bare.layoutSubtreeIfNeeded()
        #expect(bare.scrollView.frame.minX == 0)
        #expect(bare.scrollView.frame.width == 680)
    }

    @Test("the rail fills the gutter below the card, whichever is installed first")
    func containerStacksRailBelowCard() {
        let container = TranscriptContainerView(
            scrollView: NSScrollView(), leadingGutter: PromptRailLayout.width)
        container.frame = NSRect(x: 0, y: 0, width: 680, height: 600)
        let card = NSView()
        let rail = NSView()
        container.cardView = card
        container.railView = rail
        container.layoutSubtreeIfNeeded()

        #expect(rail.frame == NSRect(x: 0, y: 0, width: PromptRailLayout.width, height: 600))
        #expect(container.subviews == [container.scrollView, rail, card])
    }

    @Test("the state applies presenter calls on the next main-queue turn, the last value winning")
    func stateDefersAndCoalesces() async throws {
        let entries = PromptOutline.entries(from: transcriptRenderNodes(
            from: PromptRailFixtures.conversation(prompts: 3, replySentences: { _ in 1 })))
        try #require(entries.count == 3)
        let state = PromptRailState()

        state.promptRail(entriesDidChange: Array(entries.prefix(1)))
        state.promptRail(entriesDidChange: entries)
        state.promptRail(activeIndexDidChange: 0)
        state.promptRail(activeIndexDidChange: 2)
        // Calls can arrive inside `updateNSView`: nothing observed may change yet.
        #expect(state.entries.isEmpty, "a presenter call wrote the entries synchronously")
        #expect(state.activeIndex == nil, "a presenter call wrote the active index synchronously")

        await drainMainQueue()
        #expect(state.entries == entries)
        #expect(state.activeIndex == 2)

        // A list that shrinks past the active index, before a new index
        // arrives, reads as no active entry.
        state.promptRail(entriesDidChange: Array(entries.prefix(2)))
        await drainMainQueue()
        #expect(state.activeIndex == nil)

        // Nil is a value to deliver, not "nothing arrived".
        state.promptRail(activeIndexDidChange: 1)
        await drainMainQueue()
        #expect(state.activeIndex == 1)
        state.promptRail(activeIndexDidChange: nil)
        await drainMainQueue()
        #expect(state.activeIndex == nil)
    }

    @Test("a SwiftUI mount makes its state the presenter and routes its jumps to the table")
    func swiftUIMountWiresPresenterAndJump() async throws {
        let suiteName = "prompt-rail-mount-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        let nodes = transcriptRenderNodes(
            from: PromptRailFixtures.conversation(prompts: 3, replySentences: { _ in 2 }))
        let state = PromptRailState()
        let table = TableTranscriptView(
            context: TranscriptCardContext(
                terminalID: nil,
                openTranscriptOverlay: nil,
                appState: appState,
                linkResolver: nil,
                onLinkClicked: nil),
            atBottom: .constant(true),
            scrollToBottomToken: 0,
            activityToggleToken: 0,
            linkRoot: "",
            nodesProvider: { nodes },
            promptRail: .swiftUI(state))
        let host = OffscreenHost(root: table, size: NSSize(width: 680, height: 600))
        defer { host.tearDown() }

        let delivered = await host.settle { state.entries.count == 3 }
        try #require(delivered, "the state never received the outline (entries: \(state.entries.count))")
        let container = try #require(host.firstDescendant(TranscriptContainerView.self))
        let coordinator = try #require(container.coordinator, "the container has no coordinator")

        #expect(state.entries == coordinator.promptEntries)
        #expect(state.entries.map(\.id) == ["p-0", "p-1", "p-2"])
        // The SwiftUI renderer draws its rail beside the table, not in it.
        #expect(container.leadingGutter == 0)

        let onJump = try #require(state.onJump, "makeNSView left the state's onJump unset")
        onJump("p-1")
        #expect(coordinator.heldJumpTargetID == "p-1", "onJump did not reach the table's jump")
    }

    /// End to end through the pane shape: the container reads the key, picks
    /// the branch, and the table's `makeNSView` builds the gutter its mount
    /// names. One arm per renderer, each on its own suite so `.standard` is
    /// never read or written.
    @Test("the container mounts the renderer its key names, with the gutter in the right place")
    func containerMountsChosenRenderer() async throws {
        // Key unset: the AppKit default keeps the gutter inside the container.
        do {
            let suiteName = "prompt-rail-container-appkit-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let host = Self.hostContainer(defaults: defaults)
            defer { host.tearDown() }
            let container = try await Self.settledContainer(in: host)

            #expect(host.flippedWindowFrame(container).minX == 0)
            #expect(host.flippedWindowFrame(container).width == 680)
            #expect(container.leadingGutter == PromptRailLayout.width)
            #expect(container.scrollView.frame.minX == 20)
            #expect(container.scrollView.frame.width == 660)
            let coordinator = try #require(container.coordinator, "the container has no coordinator")
            let rail = try #require(container.railView as? PromptRailNSView, "the AppKit mount installed no rail")
            #expect(coordinator.promptRailPresenter === rail,
                    "the AppKit mount did not make its rail the presenter")
            #expect(container.cardView is PromptRailCardNSView, "the AppKit mount installed no card")
        }

        // "swiftui": the table sits right of the SwiftUI rail column, with no
        // gutter of its own, and the container's state hears the outline.
        do {
            let suiteName = "prompt-rail-container-swiftui-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set("swiftui", forKey: AppState.promptRailRendererKey)
            let host = Self.hostContainer(defaults: defaults)
            defer { host.tearDown() }
            let container = try await Self.settledContainer(in: host)

            #expect(host.flippedWindowFrame(container).minX == 20)
            #expect(host.flippedWindowFrame(container).width == 660)
            #expect(container.leadingGutter == 0)
            #expect(container.scrollView.frame.minX == 0)
            #expect(container.scrollView.frame.width == 660)

            let coordinator = try #require(container.coordinator, "the container has no coordinator")
            let state = try #require(
                coordinator.promptRailPresenter as? PromptRailState,
                "the SwiftUI mount did not make the container's state the presenter")
            let delivered = await host.settle { state.entries.count == 3 }
            #expect(delivered, "the state never received the outline (entries: \(state.entries.count))")
            #expect(state.entries == coordinator.promptEntries)
        }
    }

    /// A pane-shaped mount: `PromptRailContainer` over a table of three
    /// prompts, reading the renderer key from `defaults`.
    private static func hostContainer(defaults: UserDefaults) -> OffscreenHost<AnyView> {
        let appState = AppState(userDefaults: defaults)
        let nodes = transcriptRenderNodes(
            from: PromptRailFixtures.conversation(prompts: 3, replySentences: { _ in 2 }))
        let root = PromptRailContainer { mount in
            TableTranscriptView(
                context: TranscriptCardContext(
                    terminalID: nil,
                    openTranscriptOverlay: nil,
                    appState: appState,
                    linkResolver: nil,
                    onLinkClicked: nil),
                atBottom: .constant(true),
                scrollToBottomToken: 0,
                activityToggleToken: 0,
                linkRoot: "",
                nodesProvider: { nodes },
                promptRail: mount)
        }
        .defaultAppStorage(defaults)
        return OffscreenHost(root: AnyView(root), size: NSSize(width: 680, height: 600))
    }

    /// The host's container once SwiftUI has made and sized it.
    private static func settledContainer(in host: OffscreenHost<AnyView>) async throws -> TranscriptContainerView {
        let laidOut = await host.settle {
            (host.firstDescendant(TranscriptContainerView.self)?.bounds.width ?? 0) > 0
        }
        try #require(laidOut, "the table never mounted and laid out")
        await host.pump(times: 5)
        return try #require(host.firstDescendant(TranscriptContainerView.self))
    }
}
