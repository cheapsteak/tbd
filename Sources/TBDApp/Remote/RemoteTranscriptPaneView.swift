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
/// - `caughtUp` – false while the daemon is still paging the transcript in,
///   which the pane shows as loading while records appear;
/// - `refreshToken` – bumped on every completed sync, so an append that moved
///   none of the other three is still read.
///
/// Items are published into `AppState.sessionTranscripts` under
/// `RemoteTranscriptTail.storeKey`, where `TranscriptOverlayView` finds them.
/// The overlay is hosted here with a pane-local coordinator, because the
/// remote detail tab has no window-level overlay host, and each frame carries
/// the cache file so "Show full output" can read it app-side. Links to file
/// paths are suppressed: they name files on another machine.
struct RemoteTranscriptPaneView: View {
    let selection: RemoteSessionSelection
    let path: String?
    let generation: Int
    let caughtUp: Bool
    var refreshToken: Int = 0

    @Environment(AppState.self) var appState

    @StateObject private var overlayCoordinator = TranscriptOverlayCoordinator()
    @State private var tail = RemoteTranscriptTail()
    @State private var presentationMemo = TranscriptPresentationMemo()
    @State private var atBottom = true
    @State private var scrollToBottomToken = 0
    @State private var activityGroupExpansion: [String: Bool] = [:]
    @State private var activityToggleToken = 0

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
        let refreshToken: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
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
            key: storeKey, path: path, generation: generation, refreshToken: refreshToken)
        ) {
            await read()
        }
        .onChange(of: selection) { old, _ in
            release(RemoteTranscriptTail.storeKey(old))
            overlayCoordinator.close()
            activityGroupExpansion.removeAll()
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
            if !caughtUp {
                ProgressView().controlSize(.small)
                Text("Loading…")
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
                } else {
                    ProgressView()
                    Text("Loading transcript…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let presentation = TranscriptPresentation.build(
                items: items,
                expansionOverrides: activityGroupExpansion,
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
                nodesProvider: { presentation.nodes }
            )
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

    private func read() async {
        guard let path else { return }
        let key = storeKey
        guard let fresh = await tail.read(key: key, path: path, generation: generation),
              !Task.isCancelled
        else { return }
        if appState.sessionTranscripts[key] != fresh {
            appState.sessionTranscripts[key] = fresh
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
