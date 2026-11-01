import SwiftUI
import TBDShared

// MARK: - PaneChromeState

/// The state a pane's per-kind controls read: whether a file shows its
/// rendered view or its source, whether it can render at all, a web page's
/// current address, and the checkmark a copy of that address shows.
///
/// It lives apart from the leaf (`PanePlaceholder`) so that the view drawing
/// the controls can own it. On the daemon path the controls sit in the tab
/// row — the workspace tab bar for a primary, the side region's strip for a
/// panel — and that view hands its state to the leaf, which then draws no
/// header (panel tabs spec, "The leaf seam"). A leaf handed none owns one
/// itself and draws its own header, as it does in a legacy split and in the
/// multi-worktree grid.
@MainActor
@Observable
final class PaneChromeState {
    /// How long the copy-address control shows its checkmark after a copy.
    static let copyConfirmation: Duration = .milliseconds(1500)

    /// True while a file pane shows its source instead of its rendered view.
    var showSourceCode = false

    /// True while a file pane's content can render, which is when the
    /// rendered/source toggle is offered. The leaf writes it from
    /// `HasRenderableContentKey`.
    var hasRenderableContent = false

    /// True for ``copyConfirmation`` after ``copyAddress(_:)``.
    private(set) var didCopyAddress = false

    /// A web pane's live state, whose `currentURL` follows in-page navigation.
    /// It is an `ObservableObject`, and this class does not forward its
    /// changes: a view showing the address holds it as `@ObservedObject`.
    @ObservationIgnored let webviewState: WebviewState

    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let pasteboard: @MainActor (String) -> Void
    /// The pending checkmark reset, cancelled by a later copy so each copy
    /// shows the checkmark for the full ``copyConfirmation``.
    @ObservationIgnored private var copyReset: Task<Void, Never>?

    /// - Parameters:
    ///   - pasteboard: receives each copied address; the general pasteboard
    ///     by default.
    ///   - clock: times the checkmark's reset.
    init(
        pasteboard: @escaping @MainActor (String) -> Void = { copyToPasteboard($0) },
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.webviewState = WebviewState()
        self.clock = clock
        self.pasteboard = pasteboard
    }

    /// Writes `url` to the pasteboard and shows the checkmark until
    /// ``copyConfirmation`` passes on the clock. A copy while the checkmark
    /// shows restarts that wait.
    func copyAddress(_ url: URL) {
        pasteboard(url.absoluteString)
        didCopyAddress = true
        copyReset?.cancel()
        let clock = self.clock
        let delay = Self.copyConfirmation
        copyReset = Task { [weak self] in
            try? await clock.sleep(for: delay)
            // A later copy cancelled this reset, possibly after its sleep had
            // already returned; that copy's own reset clears the checkmark.
            guard !Task.isCancelled else { return }
            self?.didCopyAddress = false
        }
    }

    /// Does what `control`'s button does to this state: the render toggle
    /// flips the file between its rendered view and its source, and
    /// copy-address copies the page's current address, which follows in-page
    /// navigation, or `contentURL`, the address its content opened with,
    /// until the page reports one. The transcript control changes the
    /// layout, not this state, so the view that draws it sends that itself
    /// and this does nothing for it.
    func perform(_ control: PaneChromeControl, contentURL: URL?) {
        switch control {
        case .renderToggle:
            showSourceCode.toggle()
        case .copyAddress:
            guard let url = webviewState.currentURL ?? contentURL else { return }
            copyAddress(url)
        case .transcript:
            break
        }
    }
}

// MARK: - PaneChromeStore

/// One `PaneChromeState` per ID, for a view whose leaves change under one
/// tab row: the workspace view's primary, keyed by workspace tab, or the side
/// region's panels, keyed by panel. What it guarantees is one state per ID,
/// the same instance for as long as the ID is kept, so a leaf's web view and
/// copy checkmark never see another leaf's.
///
/// It does not keep a leaf's rendered/source choice across a rebuild. A
/// leaf's teardown resets its `HasRenderableContentKey` report into the
/// state (`PanePlaceholder`), so the rebuilt leaf's first report that its
/// file can render turns source view off: the toggle starts on the rendered
/// view again whenever its leaf is rebuilt.
///
/// Not observed: views observe the states it hands out, never the store, so
/// creating a state while a body is evaluated invalidates nothing.
@MainActor
final class PaneChromeStore {
    private var states: [UUID: PaneChromeState] = [:]

    /// The state for `id`, created on first use; the same instance on every
    /// later call until `id` is pruned.
    func state(for id: UUID) -> PaneChromeState {
        if let state = states[id] {
            return state
        }
        let state = PaneChromeState()
        states[id] = state
        return state
    }

    /// Drops the state of every ID not in `ids`. A dropped ID asked for again
    /// gets a fresh state.
    func prune(keeping ids: Set<UUID>) {
        states = states.filter { ids.contains($0.key) }
    }
}

// MARK: - PaneChromeControl

/// The control a pane's kind puts in its tab row, as a value, so the row can
/// decide which one to show and the button can draw it without reading
/// anything else.
enum PaneChromeControl: Equatable {
    /// A Claude terminal's transcript toggle, on while its transcript panel
    /// exists, whether or not that panel is in front.
    case transcript(isOn: Bool)
    /// A renderable file's rendered/source toggle.
    case renderToggle(showingSource: Bool)
    /// A web page's copy-address, showing a checkmark after a copy.
    case copyAddress(copied: Bool)

    /// The control viewer content of `kind` puts in its tab row, wherever
    /// that row is — the workspace tab bar for a primary, the side region's
    /// strip for a panel: the rendered/source toggle for a file that can
    /// render, and copy-address for a web page. A file that cannot render, a
    /// note, a transcript and the Changes list have none.
    static func viewerControl(
        for kind: PanelKind, canRender: Bool, showingSource: Bool, copied: Bool
    ) -> PaneChromeControl? {
        switch kind {
        case .file:
            guard canRender else { return nil }
            return .renderToggle(showingSource: showingSource)
        case .web:
            return .copyAddress(copied: copied)
        case .note, .transcript, .changes:
            return nil
        }
    }

    /// The symbol's colour.
    enum Tint {
        case accent
        case primary
        case secondary
    }

    var systemImage: String {
        switch self {
        case .transcript(let isOn):
            return isOn ? "text.bubble.fill" : "text.bubble"
        case .renderToggle:
            return "chevron.left.forwardslash.chevron.right"
        case .copyAddress(let copied):
            return copied ? "checkmark" : "doc.on.doc"
        }
    }

    /// Nil leaves the symbol in the button style's own colour.
    var tint: Tint? {
        switch self {
        case .transcript(let isOn):
            return isOn ? .accent : .primary
        case .renderToggle(let showingSource):
            return showingSource ? .primary : .secondary
        case .copyAddress:
            return nil
        }
    }

    /// The tooltip, which also names the button for accessibility.
    var help: String {
        switch self {
        case .transcript(let isOn):
            return isOn
                ? "Hide the chat-style live transcript pane"
                : "Show the chat-style live transcript pane"
        case .renderToggle(let showingSource):
            return showingSource ? "Show rendered view" : "Show source code"
        case .copyAddress:
            return "Copy URL"
        }
    }
}

// MARK: - PaneChromeControlButton

/// An icon-only button for a ``PaneChromeControl``, sized for a tab row:
/// 28 pt wide and the row's full height, all of it clickable. It reads
/// nothing but its control.
struct PaneChromeControlButton: View {
    let control: PaneChromeControl
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            symbol
                .frame(width: 28)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(control.help)
        .accessibilityLabel(Text(control.help))
    }

    @ViewBuilder
    private var symbol: some View {
        let image = Image(systemName: control.systemImage)
            .font(.system(size: 11))
        switch control.tint {
        case .accent?:
            image.foregroundStyle(Color.accentColor)
        case .primary?:
            image.foregroundStyle(.primary)
        case .secondary?:
            image.foregroundStyle(.secondary)
        case nil:
            image
        }
    }
}
