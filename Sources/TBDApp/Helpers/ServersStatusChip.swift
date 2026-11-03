import AppKit
import SwiftUI
import TBDShared

/// What the status bar's Servers chip shows, as a value. `make` returns nil
/// where the bar shows no chip.
struct ServersChipPresentation: Equatable {
    enum Style: Equatable {
        /// A server runs: a green capsule holding a green dot and "N running".
        case running
        /// Nothing runs: the `server.rack` glyph and "Servers", muted.
        case idle
    }

    var style: Style
    var title: String
    var accessibilityLabel: String

    /// The chip's tooltip, the toolbar item's when it has no main URL. The
    /// chip always opens the menu, whose first row opens the main URL.
    static let help = "Dev servers"

    /// The chip for `list`, the selected worktree's dev servers. It shows only
    /// while Tabs in the toolbar is on, since with it off the toolbar's
    /// Servers item shows them, and only under that item's own rule,
    /// `AppState.showsServersButton`: while the worktree has any server,
    /// declared or running. The title and the spoken label are the toolbar
    /// item's, from `ServersButtonLabel`.
    static func make(tabsInToolbar: Bool, list: DevServerListResult?) -> ServersChipPresentation? {
        guard tabsInToolbar, AppState.showsServersButton(list), let list else { return nil }
        let runningCount = ServersButtonLabel.runningCount(list)
        return ServersChipPresentation(
            style: runningCount > 0 ? .running : .idle,
            title: ServersButtonLabel.title(runningCount: runningCount),
            accessibilityLabel: ServersButtonLabel.accessibilityLabel(runningCount: runningCount))
    }
}

/// The status bar's Servers chip, at the start of the bar's right-hand group,
/// shown while Tabs in the toolbar is on: the toolbar gives up its Servers
/// item then, and this chip takes its place. Spec:
/// `docs/specs/2026-11-02-tabs-in-toolbar-design.md`, "Servers in the status
/// bar".
///
/// - **The setting** is read through `@AppStorage`, on the store the window's
///   hosted panes read (`MainWindowSplitView`), with its one default.
/// - **The list** is read here rather than in `StatusBarView`'s body, so a
///   change to any worktree's dev-server list re-evaluates this chip and not
///   the whole bar.
/// - **The label** is set in the bar's font, which it inherits. Running, it is
///   a capsule of system green at `fillOpacity` holding a `dotSide` dot and
///   the count in green at medium weight, a capsule like the auto-archive
///   chip's; it does not animate, because the bar stays on screen for hours
///   and a pulse would pull the eye from the terminal. Idle, it is the glyph
///   and "Servers" in the secondary colour, chrome-less like the bar's other
///   labels, with their hover underline.
/// - **A click** opens the shared `ServersMenu` upward from the chip
///   (`ServersChipMenuHost`). The label is a plain-styled `Button` and the
///   menu an `NSMenu`, as `PRChipMenu`'s are, for the same reason: a SwiftUI
///   `Menu` draws its label in the control font, ignoring the bar's.
struct ServersStatusChip: View {
    @Environment(AppState.self) private var appState
    @AppStorage(AppState.tabsInToolbarKey) private var tabsInToolbar: Bool = AppState.tabsInToolbarDefault

    /// The worktree whose servers the chip shows: the one selected worktree,
    /// `ServersMenu.selectedWorktreeID(in:)`, or nil.
    let worktreeID: UUID?

    @State private var isHovering = false
    @State private var menuHost = ServersChipMenuHost()

    /// The running capsule's fill: system green at this opacity.
    static let fillOpacity: Double = 0.15
    /// The running dot's diameter.
    static let dotSide: CGFloat = 6
    /// The gap between the dot and the count.
    static let dotTextGap: CGFloat = 4
    /// The gap between the idle glyph and "Servers".
    static let glyphTextGap: CGFloat = 3
    /// The capsule's padding around its dot and count, the auto-archive
    /// chip's.
    static let capsuleHorizontalPadding: CGFloat = 7
    static let capsuleVerticalPadding: CGFloat = 2

    var body: some View {
        if let worktreeID,
           let chip = ServersChipPresentation.make(
               tabsInToolbar: tabsInToolbar, list: appState.devServerLists[worktreeID]) {
            Button {
                menuHost.popUp(worktreeID: worktreeID, appState: appState)
            } label: {
                ServersChipLabel(chip: chip, isHovering: isHovering)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .background(ServersChipMenuAnchor(host: menuHost))
            .help(ServersChipPresentation.help)
            .modifier(StatusBarHoverAffordance(isHovering: $isHovering))
            .accessibilityLabel(chip.accessibilityLabel)
        }
    }

    /// Where `NSMenu.popUp(positioning: nil, at:in:)` must put the menu's top
    /// leading corner, in the coordinates of a chip with `chipBounds`, for a
    /// menu `menuHeight` tall to open upward: its bottom edge on the chip's
    /// top edge and its leading edge on the chip's. The top is `menuHeight`
    /// beyond the chip's top, the smaller y in a flipped view and the larger
    /// in one that is not. `NSMenu` puts the menu's top left corner at the
    /// point, or its top right under a right-to-left layout, so the x is the
    /// chip's left edge or its right.
    nonisolated static func menuOrigin(
        chipBounds: NSRect, menuHeight: CGFloat, flipped: Bool, rightToLeft: Bool
    ) -> NSPoint {
        let x = rightToLeft ? chipBounds.maxX : chipBounds.minX
        let y = flipped ? chipBounds.minY - menuHeight : chipBounds.maxY + menuHeight
        return NSPoint(x: x, y: y)
    }
}

/// The chip's label for one presentation. Colours are resolved by SwiftUI, so
/// the system green follows the appearance.
private struct ServersChipLabel: View {
    let chip: ServersChipPresentation
    let isHovering: Bool

    private static let green = Color(nsColor: .systemGreen)

    var body: some View {
        switch chip.style {
        case .running:
            HStack(spacing: ServersStatusChip.dotTextGap) {
                Circle()
                    .fill(Self.green)
                    .frame(width: ServersStatusChip.dotSide, height: ServersStatusChip.dotSide)
                // One line, as every label in the bar: a squeeze truncates
                // rather than wrapping and growing the bar.
                Text(chip.title)
                    .lineLimit(1)
            }
            .fontWeight(.medium)
            .foregroundStyle(Self.green)
            .padding(.horizontal, ServersStatusChip.capsuleHorizontalPadding)
            .padding(.vertical, ServersStatusChip.capsuleVerticalPadding)
            .background(Self.green.opacity(ServersStatusChip.fillOpacity), in: Capsule())
            .contentShape(Capsule())
        case .idle:
            HStack(spacing: ServersStatusChip.glyphTextGap) {
                Image(systemName: "server.rack")
                Text(chip.title)
                    .lineLimit(1)
                    .underline(isHovering)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
    }
}

/// Builds the chip's Servers menu through `ServersMenu` each time it opens,
/// so it never shows a stale list, and pops it up upward from the chip
/// (`ServersStatusChip.menuOrigin`). It is also the target the menu's rows
/// send to. The chip holds it in `@State` for its lifetime, so the rows'
/// weak targets stay alive while the menu is open; it reaches the chip's
/// view through `ServersChipMenuAnchor`.
@MainActor
final class ServersChipMenuHost: NSObject {
    /// The zero-content view laid behind the chip, sized to it.
    weak var anchorView: NSView?
    /// The state the last menu was built from, which its rows run against.
    weak var appState: AppState?

    /// A fresh Servers menu for `worktreeID`, each row sending
    /// `itemChosen(_:)` to this host.
    func makeMenu(worktreeID: UUID, appState: AppState) -> NSMenu {
        self.appState = appState
        let menu = NSMenu(title: "Servers")
        menu.autoenablesItems = false
        ServersMenu.rebuild(
            menu, worktreeID: worktreeID, appState: appState, target: self, action: #selector(itemChosen(_:)))
        return menu
    }

    /// Opens the menu with its bottom edge on the chip's top edge and its
    /// leading edge on the chip's. Without a windowed anchor it opens at the
    /// pointer, as `PRChipMenu` does.
    func popUp(worktreeID: UUID, appState: AppState) {
        let menu = makeMenu(worktreeID: worktreeID, appState: appState)
        guard let view = anchorView, view.window != nil else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            return
        }
        let origin = ServersStatusChip.menuOrigin(
            chipBounds: view.bounds, menuHeight: menu.size.height, flipped: view.isFlipped,
            rightToLeft: view.userInterfaceLayoutDirection == .rightToLeft)
        menu.popUp(positioning: nil, at: origin, in: view)
    }

    /// Runs the chosen row's command; any other sender runs nothing.
    @objc func itemChosen(_ sender: Any?) {
        guard let appState else { return }
        ServersMenu.runChosen(sender, appState: appState)
    }
}

/// A zero-content view laid behind the Servers chip, sized to it, so the
/// chip's menu pops up in the chip's own coordinates. It hands itself to the
/// host, and never takes the mouse, so clicks reach the chip's button.
private struct ServersChipMenuAnchor: NSViewRepresentable {
    let host: ServersChipMenuHost

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughAnchorView(frame: .zero)
        host.anchorView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        host.anchorView = nsView
    }
}

/// An `NSView` that is never the target of a hit test.
private final class PassThroughAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
