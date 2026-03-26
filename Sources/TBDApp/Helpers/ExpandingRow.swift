import AppKit
import SwiftUI

/// Shows an NSPanel child window with expanded content when the row is hovered
/// and the text is truncated. The panel renders the full `expandedContent` view
/// positioned exactly over the original row, escaping sidebar clipping.
struct ExpandingRowModifier<Expanded: View>: ViewModifier {
    let isTruncated: Bool
    @ViewBuilder let expandedContent: () -> Expanded

    @State private var isHovered = false
    @State private var rowFrame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear
                        .preference(key: RowFrameKey.self, value: geo.frame(in: .global))
                }
            )
            .onPreferenceChange(RowFrameKey.self) { rowFrame = $0 }
            .onHover { hovering in
                isHovered = hovering
                if hovering && isTruncated {
                    ExpandingRowPanel.show(
                        content: expandedContent(),
                        rowFrame: rowFrame
                    )
                } else {
                    ExpandingRowPanel.hide()
                }
            }
    }

    private struct RowFrameKey: PreferenceKey {
        static var defaultValue: CGRect { .zero }
        static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
            value = nextValue()
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

// MARK: - Panel

/// Singleton NSPanel that shows expanded row content over the sidebar.
@MainActor
final class ExpandingRowPanel {
    private static var panel: NSPanel?
    private static var hostingView: NSHostingView<AnyView>?

    static func show<V: View>(content: V, rowFrame: CGRect) {
        guard let mainWindow = NSApp.keyWindow ?? NSApp.mainWindow else { return }

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

        // Wrap content with background matching the sidebar
        let wrapped = AnyView(
            content
                .padding(.trailing, 6)
                .background(Color(nsColor: .controlBackgroundColor))
        )

        let hosting = NSHostingView(rootView: wrapped)
        let fittingSize = hosting.fittingSize

        // Only show if content is wider than the row
        guard fittingSize.width > rowFrame.width + 2 else {
            hide()
            return
        }

        // Convert SwiftUI global coords (top-left origin) to screen coords (bottom-left origin)
        let contentRect = mainWindow.contentView?.frame ?? mainWindow.frame
        let screenX = mainWindow.frame.origin.x + rowFrame.minX
        let screenY = mainWindow.frame.origin.y + contentRect.height - rowFrame.maxY

        let panelFrame = NSRect(
            x: screenX,
            y: screenY,
            width: fittingSize.width,
            height: rowFrame.height
        )

        hosting.frame = NSRect(origin: .zero, size: panelFrame.size)
        panel.contentView = hosting
        panel.setFrame(panelFrame, display: true)
        self.hostingView = hosting

        if panel.parent == nil {
            mainWindow.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    static func hide() {
        guard let panel = panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}
