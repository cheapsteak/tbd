import AppKit
import SwiftUI

/// Shows an NSPanel child window with expanded content when the row is hovered
/// and the text is truncated. The panel renders the full `expandedContent` view
/// positioned exactly over the original row, escaping sidebar clipping.
struct ExpandingRowModifier<Expanded: View>: ViewModifier {
    let isTruncated: Bool
    @ViewBuilder let expandedContent: (Bool) -> Expanded

    @State private var anchor = ExpandingRowAnchor()
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                ExpandingRowAnchorView(anchor: anchor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
            .onHover { hovering in
                isHovered = hovering
                if hovering && isTruncated {
                    guard let screenFrame = anchor.screenFrame else { return }
                    ExpandingRowPanel.show(
                        content: expandedContent(true),
                        screenFrame: screenFrame,
                        parentWindow: anchor.view?.window
                    )
                } else {
                    ExpandingRowPanel.hide()
                }
            }
    }
}

extension View {
    /// - Parameter expanded: Closure receiving `isHovered` bool so the expanded
    ///   content can match the row's hover highlight.
    func expandingRow<Expanded: View>(
        isTruncated: Bool,
        @ViewBuilder expanded: @escaping (Bool) -> Expanded
    ) -> some View {
        modifier(ExpandingRowModifier(isTruncated: isTruncated, expandedContent: expanded))
    }
}

// MARK: - Anchor NSView (for reliable screen coordinate conversion)

/// Holds a reference to an invisible NSView embedded in the row.
/// We use this to get the real screen coordinates via AppKit,
/// avoiding SwiftUI coordinate space issues with toolbars.
@MainActor
final class ExpandingRowAnchor {
    var view: NSView?

    var screenFrame: NSRect? {
        guard let view, let window = view.window else { return nil }
        let frameInWindow = view.convert(view.bounds, to: nil)
        let screenOrigin = window.convertPoint(toScreen: frameInWindow.origin)
        return NSRect(origin: screenOrigin, size: frameInWindow.size)
    }
}

struct ExpandingRowAnchorView: NSViewRepresentable {
    let anchor: ExpandingRowAnchor

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        anchor.view = v
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

// MARK: - Panel

/// Singleton NSPanel that shows expanded row content over the sidebar.
@MainActor
final class ExpandingRowPanel {
    private static var panel: NSPanel?

    static func show<V: View>(content: V, screenFrame: NSRect, parentWindow: NSWindow?) {
        guard let parentWindow else { return }

        let panel = self.panel ?? {
            let p = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .floating
            p.hasShadow = false
            p.ignoresMouseEvents = true
            self.panel = p
            return p
        }()

        let wrapped = AnyView(
            content
                .padding(.trailing, 6)
                .frame(maxHeight: .infinity)
        )
        let hosting = NSHostingView(rootView: wrapped)
        let fittingSize = hosting.fittingSize

        // Only show if content is wider than the row
        guard fittingSize.width > screenFrame.width + 2 else {
            hide()
            return
        }

        let panelFrame = NSRect(
            x: screenFrame.origin.x,
            y: screenFrame.origin.y,
            width: fittingSize.width,
            height: screenFrame.height
        )

        // Use NSVisualEffectView with sidebar material to match the sidebar's
        // translucent appearance
        let container = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelFrame.size))
        container.material = .sidebar
        container.blendingMode = .behindWindow
        container.state = .active

        hosting.frame = container.bounds
        container.addSubview(hosting)

        panel.contentView = container
        panel.setFrame(panelFrame, display: true)

        if panel.parent == nil {
            parentWindow.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    static func hide() {
        guard let panel = panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}
