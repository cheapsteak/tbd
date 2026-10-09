import AppKit
import SwiftUI
import TBDShared

/// The right half of a remote session's detail pane: the session's
/// conversation, rendered by the same table renderer Session History uses.
///
/// This view reads a file; it never fetches. Whoever drives the daemon's
/// `remote.transcriptSync` hands in what each sync reported:
///
/// - `path` – the session's cache file, nil until a sync has named one;
/// - `generation` – bumped by the daemon when it replaced the file with a
///   conversation that starts over; a change drops every item and re-reads
///   from byte zero (`RemoteTranscriptTail`);
/// - `caughtUp` – false while the daemon is still paging the transcript in
///   (or before the first sync has answered), which the header shows as a
///   non-blocking "Syncing…" while records already cached stay readable. The
///   full-pane loading state is only for a session with no cache file yet;
/// - `refreshToken` – bumped on every completed sync, so an append that moved
///   none of the other three is still read;
/// - `head` – bumped by the daemon on every prepend of earlier history. A
///   change under the same generation re-reads the whole file and bumps the
///   table's `prependToken` in the same update, so the top visible row stays
///   where it was on screen (`ReadPlan`);
/// - `hasEarlier` / `earlier` – whether history above the cache can be
///   loaded, and where loading it stands. The table's near-top transitions go
///   out through `onNearTop` (the driver decides whether to load), and the
///   header overlay (`RemoteTranscriptEarlierHeader`) shows the state; its
///   retry button calls `onLoadEarlier`. The pane never reads the flag: with
///   it off `hasEarlier` is always false and the header never shows.
///
/// Items are published into `AppState.sessionTranscripts` under
/// `RemoteTranscriptTail.storeKey`, where `TranscriptOverlayView` finds them.
/// The overlay is hosted here with a pane-local coordinator, because the
/// remote detail tab has no window-level overlay host, and each frame carries
/// the cache file so "Show full output" can read it app-side. Links to file
/// paths are suppressed: they name files on another machine.
///
/// Below the transcript sits the shared `MessageComposerView` for a
/// `.remote` target, when `RemoteComposerState` offers one: the provider
/// declares `send-submit`.
struct RemoteTranscriptPaneView: View {
    let selection: RemoteSessionSelection
    let path: String?
    let generation: Int
    let caughtUp: Bool
    var refreshToken: Int = 0
    /// The last sync's failure, if the most recent one failed.
    var syncError: String?
    var head: Int = 0
    var hasEarlier = false
    var earlier: RemoteTranscriptEarlierState = .idle
    /// Each near-top transition of the table.
    var onNearTop: @MainActor (Bool) -> Void = { _ in }
    /// The header's "Load earlier messages" button.
    var onLoadEarlier: @MainActor () -> Void = {}

    @Environment(AppState.self) var appState

    @StateObject private var overlayCoordinator = TranscriptOverlayCoordinator()
    @State private var tail = RemoteTranscriptTail()
    @State private var presentationMemo = TranscriptPresentationMemo()
    @State private var atBottom = true
    @State private var scrollToBottomToken = 0
    @State private var activityGroupExpansion: [String: Bool] = [:]
    @State private var activityToggleToken = 0
    @State private var prependToken = 0
    @State private var isNearTop = false
    /// The generation and head of the last successful read, so `ReadPlan`
    /// can tell a prepend from a reset.
    @State private var lastRead: ReadPlan.Mark?
    /// Every item ID that has started the loaded window, so an activity group
    /// that earlier history extends at its front keeps its identity (see
    /// `TranscriptPresentation.groupKeyID`). Cleared on a new conversation or
    /// session, whose window shares no IDs with this one.
    @State private var windowStartIDs: Set<String> = []

    private var storeKey: String { RemoteTranscriptTail.storeKey(selection) }

    private var items: [TranscriptItem] {
        appState.sessionTranscripts[storeKey] ?? []
    }

    /// Everything that should cause a re-read. `.task(id:)` restarts on any
    /// change and cancels the read it replaces.
    private struct ReadRequest: Equatable {
        let key: String
        let path: String?
        let generation: Int
        let head: Int
        let refreshToken: Int
    }

    /// How a read relates to the one before it.
    enum ReadPlan: Equatable {
        /// Same generation and head: whatever was appended is read on.
        case incremental
        /// Same generation, new head: earlier history landed at the front.
        /// The file is re-read whole and the table told to hold its top row.
        case anchoredReread
        /// New generation: a new conversation. The table's `.id` rebuilds it,
        /// which opens it at the bottom.
        case resetToBottom

        struct Mark: Equatable {
            let generation: Int
            let head: Int
        }

        static func next(previous: Mark?, current: Mark) -> ReadPlan {
            guard let previous else { return .incremental }
            if previous.generation != current.generation { return .resetToBottom }
            if previous.head != current.head { return .anchoredReread }
            return .incremental
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if let frame = overlayCoordinator.current {
                TranscriptOverlayView(
                    frame: frame,
                    hasBack: overlayCoordinator.hasBack,
                    onBack: { overlayCoordinator.pop() },
                    onClose: { overlayCoordinator.close() }
                )
                .padding(12)
            }
        }
        .environmentObject(overlayCoordinator)
        .task(id: ReadRequest(
            key: storeKey, path: path, generation: generation, head: head,
            refreshToken: refreshToken)
        ) {
            await read()
        }
        .onChange(of: selection) { old, _ in
            release(RemoteTranscriptTail.storeKey(old))
            overlayCoordinator.close()
            activityGroupExpansion.removeAll()
            windowStartIDs.removeAll()
            lastRead = nil
        }
        .onDisappear {
            release(storeKey)
            overlayCoordinator.close()
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Transcript")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            if let syncError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(syncError)
                Text("Sync failed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(syncError)
            } else if !caughtUp {
                ProgressView().controlSize(.small)
                Text("Syncing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        let items = self.items
        if items.isEmpty {
            VStack(spacing: 8) {
                if caughtUp {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No messages yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if path == nil {
                    // No cache file yet: nothing to show until the first
                    // page lands.
                    ProgressView()
                    Text("Loading transcript…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    // A cache file exists; its read is in flight or it holds
                    // nothing yet. The header says a sync is still running.
                    Text("Reading transcript…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let presentation = TranscriptPresentation.build(
                items: items,
                expansionOverrides: activityGroupExpansion,
                windowStartIDs: windowStartIDs,
                memo: presentationMemo
            )
            TableTranscriptView(
                context: TranscriptCardContext(
                    terminalID: nil,
                    openTranscriptOverlay: openTranscriptItem,
                    toggleActivityGroup: setActivityGroup,
                    appState: appState,
                    // No resolver: path tokens are never minted as links.
                    linkResolver: nil,
                    onLinkClicked: { target in
                        if let url = TranscriptLinkDestination.remote(target) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                ),
                atBottom: $atBottom,
                scrollToBottomToken: scrollToBottomToken,
                activityToggleToken: activityToggleToken,
                linkRoot: "",
                nodesProvider: { presentation.nodes },
                prependToken: prependToken,
                onNearTop: { near in
                    isNearTop = near
                    onNearTop(near)
                }
            )
            .overlay(alignment: .top) {
                let content = RemoteTranscriptEarlierHeader.Content.resolve(
                    state: earlier, hasEarlier: hasEarlier, nearTop: isNearTop)
                if content != .hidden {
                    RemoteTranscriptEarlierHeader(content: content, onRetry: onLoadEarlier)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !atBottom {
                    Button {
                        scrollToBottomToken &+= 1
                    } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 28))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .background(.ultraThinMaterial, in: Circle())
                            .shadow(radius: 4)
                    }
                    .buttonStyle(.plain)
                    .padding(16)
                    .help("Scroll to bottom")
                }
            }
            // A new session or a new conversation rebuilds the table's
            // stateful coordinator rather than diffing across the reset.
            .id("\(storeKey)#\(generation)")
        }
    }

    /// Outside the table's `.id`, so a generation reset that rebuilds the
    /// table leaves a half-written message alone; keyed by the session, so a
    /// selection change gets that session's own draft and registration.
    @ViewBuilder
    private var composer: some View {
        let state = appState.remoteComposerState(for: selection)
        if state != .hidden {
            Divider()
            MessageComposerView(target: .remote(selection), state: state.composerState)
                .id(ComposerKey.remote(selection))
        }
    }

    private func read() async {
        guard let path else { return }
        let key = storeKey
        let mark = ReadPlan.Mark(generation: generation, head: head)
        let plan = ReadPlan.next(previous: lastRead, current: mark)
        guard let fresh = await tail.read(
            key: key, path: path, generation: generation, head: head),
              !Task.isCancelled
        else { return }
        // Only a read that landed moves the mark, so a prepend whose re-read
        // failed is still anchored when the next read succeeds.
        lastRead = mark
        if plan == .resetToBottom { windowStartIDs.removeAll() }
        if let start = TranscriptPresentation.windowStartID(of: fresh) {
            windowStartIDs.insert(start)
        }
        if appState.sessionTranscripts[key] != fresh {
            appState.sessionTranscripts[key] = fresh
            // Same main-actor turn as the items, so the table sees the new
            // rows and the reason for them in one update.
            if plan == .anchoredReread {
                prependToken &+= 1
            }
        }
    }

    /// Drops what is held for `key` — the tail's state and the published
    /// items — so a session no pane shows keeps nothing resident. Reopening
    /// re-reads the cache file, which is local and cheap.
    private func release(_ key: String) {
        appState.sessionTranscripts.removeValue(forKey: key)
        let tail = self.tail
        Task { await tail.forget(key: key) }
    }

    private func openTranscriptItem(_ itemID: String) {
        overlayCoordinator.open(
            terminalID: nil, itemID: itemID, historySessionID: storeKey, detailPath: path)
    }

    private func setActivityGroup(_ id: String, expanded: Bool) {
        activityGroupExpansion[id] = expanded
        activityToggleToken &+= 1
    }
}
