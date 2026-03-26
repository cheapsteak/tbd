import AppKit
import SwiftUI

/// View modifier that shows an NSPanel with expanded content when the row is
/// hovered and text is truncated. The panel covers the full row with a plain
/// sidebar background (no selection highlight) — like Xcode's expansion tooltip.
struct ExpandingRowModifier<Expanded: View>: ViewModifier {
    let isTruncated: Bool
    @ViewBuilder let expandedContent: () -> Expanded

    @State private var anchor = ExpandingRowAnchor()

    func body(content: Content) -> some View {
        content
            .background(
                ExpandingRowAnchorView(anchor: anchor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
            .onHover { hovering in
                if hovering && isTruncated {
                    guard let screenFrame = anchor.screenFrame else { return }
                    ExpandingRowPanel.show(
                        content: expandedContent(),
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
    func expandingRow<Expanded: View>(
        isTruncated: Bool,
        @ViewBuilder expanded: @escaping () -> Expanded
    ) -> some View {
        modifier(ExpandingRowModifier(isTruncated: isTruncated, expandedContent: expanded))
    }
}

// MARK: - Anchor NSView

/// Invisible NSView embedded in the row for reliable screen coordinate conversion.
@MainActor
final class ExpandingRowAnchor {
    var view: NSView?

    /// Walk up to find the NSTableRowView (the List cell) for accurate positioning.
    private var rowView: NSView? {
        var current = view
        while let v = current {
            if String(describing: type(of: v)).contains("RowView") ||
               v is NSTableRowView {
                return v
            }
            current = v.superview
        }
        // Fallback to our own view
        return view
    }

    var screenFrame: NSRect? {
        guard let target = rowView, let window = target.window else { return nil }
        let frameInWindow = target.convert(target.bounds, to: nil)
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

        let hosting = NSHostingView(rootView: AnyView(
            content
                .padding(.trailing, 6)
                .frame(maxHeight: .infinity)
        ))
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

        // Sidebar-material background, no selection highlight
        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelFrame.size))
        bg.material = .sidebar
        bg.blendingMode = .behindWindow
        bg.state = .active

        hosting.frame = NSRect(origin: .zero, size: panelFrame.size)

        let container = NSView(frame: NSRect(origin: .zero, size: panelFrame.size))
        container.addSubview(bg)
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
