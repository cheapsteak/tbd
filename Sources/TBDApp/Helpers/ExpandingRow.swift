import AppKit
import os
import SwiftUI

private let logger = Logger(subsystem: "com.tbd.app", category: "ExpandingRow")

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
                // Defer to next run loop — showing the panel during a layout
                // pass crashes (NSHostingView triggers setNeedsUpdateConstraints
                // on the child window while the parent is mid-layout).
                DispatchQueue.main.async {
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
            if v is NSTableRowView { return v }
            current = v.superview
        }
        logger.warning("NSTableRowView not found in view hierarchy — expansion panel may be mispositioned")
        return view
    }

    var contentInset: CGPoint {
        guard let anchor = view, let row = rowView, row !== anchor else { return .zero }
        let anchorInRow = anchor.convert(anchor.bounds.origin, to: row)
        // Snap to half-points (Retina 2x pixel grid) to prevent sub-pixel shifts
        return CGPoint(x: round(anchorInRow.x * 2) / 2, y: round(anchorInRow.y * 2) / 2)
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
    private static var clickMonitor: Any?
    private static var currentOnClick: (() -> Void)?
    private static var currentPanelFrame: NSRect = .zero

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
            // Must ignore mouse events so onHover on the SwiftUI view
            // doesn't flicker (panel appearing would steal the hover)
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

        let container = NSView(frame: NSRect(origin: .zero, size: panelFrame.size))
        container.addSubview(bg)
        container.addSubview(hosting)

        panel.contentView = container
        panel.setFrame(panelFrame, display: true)
        currentPanelFrame = panelFrame
        currentOnClick = onClick

        if panel.parent == nil {
            parentWindow.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)

        // Local event monitor intercepts clicks in the panel's screen area.
        // The panel ignores mouse events (for hover), but we catch clicks
        // at the app level and check if they land within the panel's frame.
        if clickMonitor == nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
                let clickScreen = NSEvent.mouseLocation
                let isInPanel = currentPanelFrame.contains(clickScreen)
                if isInPanel {
                    let callback = currentOnClick
                    hide()
                    // Fire callback AND let the click through to the List
                    // so selection state stays in sync
                    DispatchQueue.main.async { callback?() }
                }
                // Always pass the event through
                return event
            }
        }
    }

    static func hide() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        currentOnClick = nil
        guard let panel = panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}
