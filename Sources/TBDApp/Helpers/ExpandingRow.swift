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
    private static var hosting: NSHostingView<AnyView>?
    private static var bg: NSView?
    private static var clickMonitor: Any?
    private static var currentOnClick: (() -> Void)?
    private static var currentPanelFrame: NSRect = .zero
    private static var currentIsDark: Bool?
    // Cached inputs to avoid recomputing fittingSize on every hover tick.
    // fittingSize forces a layout pass on the hosting view; doing it 60×/sec
    // during hover is part of what blew the per-window update-constraints
    // budget that surfaced as NSGenericException.
    private static var lastFittingSize: NSSize?
    private static var lastFittingInputs: (screenW: CGFloat, screenH: CGFloat, insetX: CGFloat)?

    static func show<V: View>(
        content: V,
        screenFrame: NSRect,
        contentInset: CGPoint,
        parentWindow: NSWindow?,
        onClick: (() -> Void)?
    ) {
        guard let parentWindow else { return }

        // Cheap geometry rejection BEFORE allocating any AppKit views. Most
        // hover ticks on non-truncated rows hit this path.
        // Width-relevant inputs for fittingSize are screen height (frame max
        // height) and the trailing padding on content. If those haven't changed
        // we can reuse last known fittingSize and short-circuit early.
        let inputs = (screenW: screenFrame.width, screenH: screenFrame.height, insetX: contentInset.x)
        if let cached = lastFittingSize,
           let prev = lastFittingInputs,
           prev == inputs {
            let totalWidth = contentInset.x + cached.width
            if totalWidth <= screenFrame.width + 2 {
                hide()
                return
            }
        }

        let panel = self.panel ?? {
            let p = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            p.isOpaque = true
            p.level = .normal
            p.hasShadow = false
            p.hidesOnDeactivate = false
            // Must ignore mouse events so onHover on the SwiftUI view
            // doesn't flicker (panel appearing would steal the hover)
            p.ignoresMouseEvents = true
            self.panel = p
            return p
        }()

        // Persist ONE NSHostingView and ONE bg NSView for the panel's lifetime.
        // Reassigning panel.contentView and re-allocating NSHostingView on every
        // hover tick is what triggered "more Update Constraints in Window passes
        // than there are views" — each rebuild forces a fresh constraint pass
        // against the panel's window and we exhaust AppKit's per-window budget.
        let hosting: NSHostingView<AnyView>
        if let existing = self.hosting {
            hosting = existing
            hosting.rootView = AnyView(
                content
                    .padding(.trailing, 6)
                    .frame(maxHeight: .infinity)
            )
        } else {
            hosting = NSHostingView(rootView: AnyView(
                content
                    .padding(.trailing, 6)
                    .frame(maxHeight: .infinity)
            ))
            // Use frame-based layout, not AutoLayout. Mixing manual `frame =`
            // with the default translatesAutoresizingMaskIntoConstraints=false
            // makes NSHostingView keep posting setNeedsUpdateConstraints up to
            // the panel's window every layout pass.
            hosting.translatesAutoresizingMaskIntoConstraints = true
            self.hosting = hosting
        }

        // Recompute fittingSize only when the cache is stale.
        let fittingSize: NSSize
        if let cached = lastFittingSize,
           let prev = lastFittingInputs,
           prev == inputs,
           self.hosting != nil {
            fittingSize = cached
        } else {
            fittingSize = hosting.fittingSize
            lastFittingSize = fittingSize
            lastFittingInputs = inputs
        }
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

        let bg: NSView
        if let existing = self.bg {
            bg = existing
            bg.frame = NSRect(origin: .zero, size: panelFrame.size)
        } else {
            bg = NSView(frame: NSRect(origin: .zero, size: panelFrame.size))
            bg.translatesAutoresizingMaskIntoConstraints = true
            bg.wantsLayer = true
            bg.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            bg.layer?.cornerRadius = 5
            bg.addSubview(hosting)
            self.bg = bg
            // Set contentView exactly once for the panel's lifetime.
            panel.contentView = bg
        }

        // windowBackgroundColor resolves to pure white in light mode, which is
        // too bright for the sidebar's vibrancy-tinted gray. Use approximate
        // sidebar background values instead. Only rewrite the layer color
        // when appearance actually changes — cheap, but not free.
        let isDark = parentWindow.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if currentIsDark != isDark {
            let bgColor = isDark
                ? NSColor(white: 0.157, alpha: 1.0)   // ≈ #282828, macOS dark sidebar
                : NSColor(white: 241.0 / 255.0, alpha: 1.0)   // ≈ #F1F1F1, measured via Digital Color Meter
            bg.layer?.backgroundColor = bgColor.cgColor
            currentIsDark = isDark
        }

        let newHostingFrame = NSRect(
            x: contentInset.x,
            y: 0,
            width: fittingSize.width,
            height: panelFrame.height
        )
        if hosting.frame != newHostingFrame {
            hosting.frame = newHostingFrame
        }

        if currentPanelFrame != panelFrame {
            panel.setFrame(panelFrame, display: true)
            currentPanelFrame = panelFrame
        }
        currentOnClick = onClick

        if panel.parent == nil {
            parentWindow.addChildWindow(panel, ordered: .above)
        }
        if !panel.isVisible {
            panel.orderFront(nil)
        }

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
