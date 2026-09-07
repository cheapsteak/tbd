import AppKit
import Foundation
import SwiftUI
import TBDShared
import TestSupport
@testable import TBDApp

/// The transcript composer, mounted the way the pane mounts it, for suites that
/// have to ask a *drawn* composer a question: where its completion list lands,
/// what a driver can reach in it, and what each of its four states looks like.
///
/// It owns the fixture half of that — an isolated `AppState`, a worktree, a
/// terminal whose real columns put the composer into the state under test, a
/// scratch directory for staged images — and delegates the hosting half to
/// `OffscreenHost`, whose doc comment states what an offscreen mount does and
/// does not prove.
///
/// **Mounting is deferred to the first use of `host`.** Everything the composer
/// reads on appearance — the draft it restores, the completions inventory it
/// adopts — has to be in place before SwiftUI runs `.task`, and a harness that
/// mounted in its initializer would leave a caller no turn in which to put it
/// there. `prepare` and `openMenu(typing:)` both write before that first mount.
@MainActor
final class ComposerHarness {

    // MARK: - Configuration

    /// What stands above the composer in the mounted stack.
    ///
    /// The region matters even when it is empty: the completion list opens
    /// *upward*, out over the transcript, so a composer mounted with nothing
    /// above it has nowhere to put its rows.
    enum Backdrop {
        /// `Color.clear` — a region to grow into, and all a geometry assertion
        /// needs.
        case empty
        /// `TranscriptPreviewStrip`: a few rows of plausible conversation, so a
        /// rendered composer is shown in the pane it belongs to.
        case transcriptPreview
        /// A caller's own view — for a suite whose question is about the
        /// *neighbour*, such as ordering the SwiftUI overlay against a hosted
        /// AppKit view.
        case custom(AnyView)
    }

    /// The pane geometry the composer suites mount at: wide enough for the
    /// list's full 460pt width to sit inside it with room to spare, tall enough
    /// that a full-height list has somewhere to open.
    static let defaultSize = NSSize(width: 720, height: 520)

    /// A completions inventory with more commands than the list's eight-row cap,
    /// so the cap is exercised rather than assumed, and every name is derived
    /// from its index so a test can name a row it expects to see.
    static func inventory(commandCount: Int = 20) -> TerminalCompletionsResult {
        TerminalCompletionsResult(
            commands: (0..<commandCount).map {
                CompletionCommand(
                    name: "compact\($0)",
                    description: "Compact the conversation, take \($0)")
            },
            agents: [], freshness: .fresh, source: .probe)
    }

    // MARK: - The fixture

    let appState: AppState
    let worktree: LocalWorktree
    let terminal: Terminal
    /// Resolved from `terminal`'s own columns by the production rule, never
    /// asserted into place — so a suite that mounts a blocked composer is
    /// mounting what the daemon's record would actually produce.
    let state: ComposerState

    /// This terminal's unsent message. Writes to it before the first `host`
    /// access are what the composer restores on appearance.
    var draft: ComposerDraft { appState.composerDraft(for: terminal.id) }

    private let defaults: UserDefaults
    private let suiteName: String
    private let scratchDirectory: URL
    private let size: NSSize
    private let appearance: NSAppearance?
    private let backdrop: Backdrop
    private var mounted: OffscreenHost<AnyView>?

    /// Build the fixture. Nothing is mounted yet.
    ///
    /// - Parameters:
    ///   - name: Names the `UserDefaults` suite and the scratch directory in a
    ///     listing. Give it the calling suite's name.
    ///   - terminal: Builds the session the composer points at, given the
    ///     harness's own worktree id. Defaults to a running Claude terminal;
    ///     `parkedTerminal` and `blockedTerminal` build the other two states out
    ///     of the same columns the daemon writes.
    ///   - backdrop: What stands above the composer.
    ///   - prepare: Runs before the mount, with the draft and a scratch
    ///     directory to stage images into.
    init(
        name: String,
        terminal: ((UUID) -> Terminal)? = nil,
        size: NSSize = ComposerHarness.defaultSize,
        appearance: NSAppearance? = NSAppearance(named: .aqua),
        inventory: TerminalCompletionsResult = ComposerHarness.inventory(),
        backdrop: Backdrop = .empty,
        prepare: (Setup) throws -> Void = { _ in }
    ) throws {
        suiteName = "\(name)-\(UUID().uuidString)"
        // A suite of its own, never `UserDefaults.standard`: this executable is
        // unbundled, so "standard" is the developer's real `TBDApp.plist`.
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("UserDefaults refused the suite name \(suiteName)")
        }
        self.defaults = defaults
        appState = AppState(userDefaults: defaults)
        appState.composerCompletionsFetcher = { _ in inventory }

        let worktree = Self.worktree()
        self.worktree = worktree
        let terminal = terminal?(worktree.id) ?? Self.runningTerminal(worktreeID: worktree.id)
        self.terminal = terminal
        state = ComposerState.resolve(
            terminal: terminal, isRemoteWorktree: false, composerEnabled: true)

        self.size = size
        self.appearance = appearance
        self.backdrop = backdrop
        scratchDirectory = URL(
            fileURLWithPath: fencedScratchRoot(prefix: "tbdcomposer"), isDirectory: true)

        try prepare(Setup(
            draft: appState.composerDraft(for: terminal.id),
            scratchDirectory: scratchDirectory))
    }

    /// Put the window away, drop the defaults suite, and remove anything staged.
    ///
    /// Safe to call from a `defer`, and safe on a harness that never mounted.
    func tearDown() {
        mounted?.tearDown()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: scratchDirectory)
    }

    // MARK: - Preparation

    /// What `prepare` is handed: the draft the composer will restore, and a
    /// directory to put files in that the harness will remove again.
    @MainActor
    struct Setup {
        let draft: ComposerDraft
        /// A fresh directory under the run's fenced scratch root. Created on
        /// demand by `stage(png:)`; removed by `tearDown()`.
        let scratchDirectory: URL

        /// Stage an image on the draft, and return its `[Image #N]` number.
        ///
        /// - Parameter png: The bytes to write. `nil` stages a path with **no
        ///   file behind it**, which is a real state — an attachment whose file
        ///   went away — and the one a test that only cares about the strip's
        ///   structure should use, because it needs no decode to settle.
        @discardableResult
        func stage(png: Data?) throws -> Int {
            let id = UUID()
            let url = scratchDirectory.appendingPathComponent("\(id).png")
            if let png {
                try FileManager.default.createDirectory(
                    at: scratchDirectory, withIntermediateDirectories: true)
                try png.write(to: url, options: [.atomic])
            }
            return draft.stage(path: url.path, id: id)
        }

        /// Append an image's token to the draft text, the way inserting at the
        /// caret would — so the strip shows the thumbnail as *in* the message
        /// rather than detached.
        func appendToken(_ number: Int) {
            draft.text += ComposerTokens.text(for: number)
        }
    }

    // MARK: - Terminals

    /// A local worktree for the composer to be scoped to. Local because a remote
    /// one has no composer at all.
    static func worktree() -> LocalWorktree {
        guard let worktree = LocalWorktree(Worktree(
            id: UUID(), repoID: UUID(), name: "wt", displayName: "WT", branch: "main",
            path: "/tmp/wt", status: .active, tmuxServer: "test-server", location: .local))
        else { fatalError("a local worktree fixture failed to build") }
        return worktree
    }

    /// A Claude session that is up: `ComposerState.resolve` reads this as
    /// `.running`.
    static func runningTerminal(worktreeID: UUID, label: String = "claude") -> Terminal {
        Terminal(
            id: UUID(), worktreeID: worktreeID, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: label, kind: .claude)
    }

    /// A parked session — the columns the daemon writes when the process is
    /// gone. `exited` distinguishes only *who* ended it, which is the wording
    /// the note under the field carries.
    static func parkedTerminal(
        worktreeID: UUID, exited: Bool, label: String = "claude"
    ) -> Terminal {
        Terminal(
            id: UUID(), worktreeID: worktreeID, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: label, kind: .claude, hibernatedAt: Date(),
            hibernateReason: exited ? .exited : .manual)
    }

    /// A session sitting on a dialog: an awaiting-input reason whose
    /// notification type classifies as `.promptOnScreen`, which is what
    /// `ComposerState.resolve` reads as blocked.
    static func blockedTerminal(
        worktreeID: UUID, message: String, label: String = "claude"
    ) -> Terminal {
        Terminal(
            id: UUID(), worktreeID: worktreeID, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: label, kind: .claude,
            awaitingInputReason: AwaitingInputReason(
                message: message, hookEventName: "Notification",
                notificationType: "permission_prompt"),
            awaitingInputObservedAt: Date())
    }

    // MARK: - Mounting

    /// The mounted composer, mounting it on first use.
    var host: OffscreenHost<AnyView> {
        if let mounted { return mounted }
        let host = OffscreenHost(root: root(), size: size, appearance: appearance)
        mounted = host
        return host
    }

    private func root() -> AnyView {
        AnyView(
            VStack(spacing: 0) {
                backdropView
                MessageComposerView(
                    terminal: terminal, worktree: worktree, state: state)
            }
            .environment(appState))
    }

    /// Whatever stands above the composer takes the leftover height, so the
    /// composer keeps the natural height it has in the pane. Without the
    /// priority two flexible views split the window evenly and the composer
    /// renders twice as tall as it ever is.
    @ViewBuilder
    private var backdropView: some View {
        Group {
            switch backdrop {
            case .empty:
                Color.clear
            case .transcriptPreview:
                TranscriptPreviewStrip()
            case .custom(let view):
                view
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
    }

    // MARK: - Reaching into the mounted composer

    /// The composer's text view — the only `ComposerTextView` in the tree.
    var textView: ComposerTextView? {
        host.firstDescendant(ComposerTextView.self)
    }

    /// The completion list.
    ///
    /// `CompletionOverlayView` backs itself with a `.menu`-material
    /// `VisualEffectView`, which is an `NSViewRepresentable` and therefore a
    /// real `NSView` in the hierarchy — the one piece of the SwiftUI overlay
    /// whose frame AppKit can be asked for.
    var completionList: NSVisualEffectView? {
        host.firstDescendant(NSVisualEffectView.self) { $0.material == .menu }
    }

    /// Open the completion list on `text`, and wait for it to reach full height.
    ///
    /// **"Typing" here means the draft-restore path**, not a synthesized
    /// keystroke, and the difference is not cosmetic. The composer's own set-up
    /// restores the draft as its first act and reports the restored text back
    /// through `onTextChange` — the same production route a keystroke takes to
    /// open the list — so writing the draft before the mount means nothing races
    /// the restore. Typing after the mount loses: the restore lands on top of
    /// the typed text, clears it as an empty draft, and dismisses the menu a
    /// turn later.
    ///
    /// Full height, rather than merely present, is what proves the **inventory**
    /// landed too: a menu still waiting on it shows one short "Loading commands"
    /// row, and stopping there would measure a placement the eight rows never
    /// had.
    ///
    /// - Returns: whether the list reached full height, so a caller can
    ///   `#require` it against `diagnostics()`.
    func openMenu(
        typing text: String, maxPumps: Int = OffscreenHostDefaults.maxPumps
    ) async -> Bool {
        draft.text = text
        return await host.settle(maxPumps: maxPumps) {
            guard let list = completionList else { return false }
            return list.bounds.height >= CompletionOverlayView.maxHeight
        }
    }

    /// Poll, bounded, until every identifier in `wanted` is in the accessibility
    /// tree. Returns the last set it saw either way, so a failure can report
    /// what was actually there.
    ///
    /// Only meaningful inside `withAccessibilityBridge`.
    func settle(
        untilIdentifiers wanted: Set<String>,
        maxPumps: Int = OffscreenHostDefaults.maxPumps
    ) async -> Set<String> {
        await settleAccessibility(maxPumps: maxPumps) { wanted.isSubset(of: $0) }
    }

    /// The same poll for a *family* of identifiers rather than exact names: the
    /// completion rows are named after the commands the ranker chose, which is
    /// not something a test should have to predict.
    func settle(
        untilAnyIdentifierHasPrefix prefix: String,
        maxPumps: Int = OffscreenHostDefaults.maxPumps
    ) async -> Set<String> {
        await settleAccessibility(maxPumps: maxPumps) { seen in
            seen.contains { $0.hasPrefix(prefix) }
        }
    }

    private func settleAccessibility(
        maxPumps: Int, until condition: (Set<String>) -> Bool
    ) async -> Set<String> {
        var seen = host.accessibilityIdentifiers()
        for _ in 0..<maxPumps {
            if condition(seen) { return seen }
            await host.pump()
            seen = host.accessibilityIdentifiers()
        }
        return seen
    }

    /// What the tree actually held when a wait ran out — so a failure names the
    /// state it gave up in rather than only the state it wanted.
    func diagnostics() -> String {
        let effects = host.descendants(NSVisualEffectView.self)
            .map { "material=\($0.material.rawValue) h=\($0.bounds.height)" }
        let text = textView?.string ?? "<no text view>"
        return "text=\(text.debugDescription) effects=\(effects) "
            + "views=\(host.descendants(NSView.self).count)"
    }
}

/// A few rows of plausible conversation, standing in for the transcript above
/// the composer.
///
/// A **fixture**, not a preview of the real table: rendering the production
/// `TableTranscriptView` here would drag its coordinator, its measurement cache
/// and a session's worth of nodes into a test whose subject is the composer.
/// What the composer needs from its neighbour is the two things this provides —
/// a region to open the completion list out over, and something above the field
/// so a rendered composer is shown in a pane rather than floating on a blank
/// square.
struct TranscriptPreviewStrip: View {
    /// Deliberately dull and generic: this is a public repository, and a fixture
    /// is the easiest place for somebody's real work to end up in it.
    private static let exchange: [(speaker: String, text: String)] = [
        ("You", "Can you pull the retry logic out of the client and test it on its own?"),
        ("Agent", "Moved it into `RetryPolicy`, with the backoff as an injected clock "
            + "so the tests do not sleep. Three call sites updated."),
        ("You", "Good. What happens when the deadline passes mid-attempt?"),
        ("Agent", "The attempt finishes and the policy refuses the next one — a "
            + "deadline bounds the waiting, never the work already in flight."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer(minLength: 0)
            ForEach(Array(Self.exchange.enumerated()), id: \.offset) { _, turn in
                VStack(alignment: .leading, spacing: 3) {
                    Text(turn.speaker)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(turn.text)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}
