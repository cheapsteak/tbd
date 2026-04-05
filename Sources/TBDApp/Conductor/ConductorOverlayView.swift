import AppKit
import SwiftUI
import TBDShared

struct ConductorOverlayView: View {
    @EnvironmentObject var appState: AppState
    let terminal: Terminal
    let tmuxServer: String
    let parentHeight: CGFloat

    @State private var dragStartHeight: CGFloat = 0
    @State private var dragIndicatorOffset: CGFloat? = nil
    @State private var isHoveringHandle = false

    private let minHeight: CGFloat = 100

    private var maxHeight: CGFloat { parentHeight * 0.8 }
    private var effectiveHeight: CGFloat {
        appState.conductorHeight > 0 ? appState.conductorHeight : parentHeight * 0.5
    }

    var body: some View {
        VStack(spacing: 0) {
            // Terminal
            TerminalPanelView(
                terminalID: terminal.id,
                tmuxServer: tmuxServer,
                tmuxWindowID: terminal.tmuxWindowID,
                tmuxBridge: appState.tmuxBridge,
                worktreePath: "conductor"
            )
            .frame(height: effectiveHeight)
            .clipped()

            // Drag handle
            ZStack {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 1)

                if let offset = dragIndicatorOffset {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                        .offset(y: offset)
                }
            }
            .frame(height: 4)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHoveringHandle = hovering
                if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartHeight == 0 { dragStartHeight = effectiveHeight }
                        let proposed = dragStartHeight + value.translation.height
                        let clamped = max(minHeight, min(maxHeight, proposed))
                        dragIndicatorOffset = clamped - effectiveHeight
                    }
                    .onEnded { value in
                        let proposed = dragStartHeight + value.translation.height
                        appState.conductorHeight = max(minHeight, min(maxHeight, proposed))
                        dragStartHeight = 0
                        dragIndicatorOffset = nil
                    }
            )

            // Suggestion bar (conditional)
            if let suggestion = appState.conductorSuggestion {
                ConductorSuggestionBar(suggestion: suggestion)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: appState.showConductor) { _, visible in
            if visible {
                // Focus the conductor terminal when overlay becomes visible.
                // Delay slightly to let SwiftUI finish the opacity transition.
                DispatchQueue.main.async {
                    if let window = NSApp.keyWindow {
                        focusConductorTerminal(in: window.contentView)
                    }
                }
            }
        }
        .onDisappear {
            // Clean up pushed cursor if we disappear while hovering
            if isHoveringHandle { NSCursor.pop() }
        }
    }

    /// Walk the view tree to find the conductor's TBDTerminalView and make it first responder.
    private func focusConductorTerminal(in view: NSView?) {
        guard let view else { return }
        if let terminalView = view as? TBDTerminalView,
           terminalView.worktreePath == "conductor" {
            view.window?.makeFirstResponder(terminalView)
            return
        }
        for subview in view.subviews {
            focusConductorTerminal(in: subview)
        }
    }
}
