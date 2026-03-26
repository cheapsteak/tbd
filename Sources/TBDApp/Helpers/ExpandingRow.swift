import AppKit
import SwiftUI

/// View modifier that shows an NSPanel with expanded content when the row is
/// hovered and text is truncated. The panel covers the full row with a plain
/// sidebar background (no selection highlight) — like Xcode's expansion tooltip.
struct ExpandingRowModifier<Expanded: View>: ViewModifier {
    let isTruncated: Bool
    let onClick: (() -> Void)?
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
                    let inset = anchor.contentInset
                    ExpandingRowPanel.show(
                        content: expandedContent(),
                        screenFrame: screenFrame,
                        contentInset: inset,
                        parentWindow: anchor.view?.window,
                        onClick: onClick
                    )
                } else {
                    ExpandingRowPanel.hide()
                }
            }
            .onChange(of: isTruncated) { _, truncated in
                if !truncated { ExpandingRowPanel.hide() }
            }
    }
}

extension View {
    func expandingRow<Expanded: View>(
        isTruncated: Bool,
        onClick: (() -> Void)? = nil,
        @ViewBuilder expanded: @escaping () -> Expanded
    ) -> some View {
        modifier(ExpandingRowModifier(isTruncated: isTruncated, onClick: onClick, expandedContent: expanded))
    }
}

// MARK: - Anchor NSView

@MainActor
final class ExpandingRowAnchor {
    var view: NSView?

    private var rowView: NSView? {
        var current = view
        while let v = current {
            if v is NSTableRowView {
                return v
            }
            current = v.superview
        }
        return view
    }

    var contentInset: CGPoint {
        guard let anchor = view, let row = rowView, row !== anchor else { return .zero }
        let anchorInRow = anchor.convert(anchor.bounds.origin, to: row)
        return CGPoint(x: floor(anchorInRow.x), y: floor(anchorInRow.y))
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

// MARK: - Clickable NSView for the panel content

/// An NSView that detects clicks and forwards them via a callback.
final class ClickableView: NSView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

// MARK: - Panel

@MainActor
final class ExpandingRowPanel {
    private static var panel: NSPanel?

    static func show<V: View>(
        content: V,
        screenFrame: NSRect,
        contentInset: CGPoint,
        parentWindow: NSWindow?,
        onClick: (() -> Void)?
    ) {
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
            p.level = .normal
            p.hasShadow = false
            p.hidesOnDeactivate = false
            // Don't ignore mouse events — we handle clicks ourselves
            p.ignoresMouseEvents = false
            self.panel = p
            return p
        }()

        let hosting = NSHostingView(rootView: AnyView(
            content
                .padding(.trailing, 6)
                .frame(maxHeight: .infinity)
        ))
        let fittingSize = hosting.fittingSize

        let totalWidth = contentInset.x + fittingSize.width

        guard totalWidth > screenFrame.width + 2 else {
            hide()
            return
        }

        let panelFrame = NSRect(
            x: screenFrame.origin.x,
            y: screenFrame.origin.y,
            width: totalWidth,
            height: screenFrame.height
        )

        // Sidebar-material background
        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelFrame.size))
        bg.material = .sidebar
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        bg.layer?.cornerRadius = 5

        hosting.frame = NSRect(
            x: contentInset.x,
            y: 0,
            width: fittingSize.width,
            height: panelFrame.height
        )

        // Clickable container that forwards clicks
        let container = ClickableView(frame: NSRect(origin: .zero, size: panelFrame.size))
        container.onClick = {
            hide()
            // Dispatch after hide so the SwiftUI view is visible when the callback fires
            DispatchQueue.main.async {
                onClick?()
            }
        }
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
