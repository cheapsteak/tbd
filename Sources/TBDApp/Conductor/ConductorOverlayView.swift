import SwiftUI
import TBDShared

struct ConductorOverlayView: View {
    @EnvironmentObject var appState: AppState
    let terminal: Terminal
    let tmuxServer: String

    @State private var dragStartHeight: CGFloat = 0
    @State private var dragIndicatorOffset: CGFloat? = nil

    private let minHeight: CGFloat = 100

    var body: some View {
        GeometryReader { geometry in
            let maxHeight = geometry.size.height * 0.8

            VStack(spacing: 0) {
                // Terminal
                TerminalPanelView(
                    terminalID: terminal.id,
                    tmuxServer: tmuxServer,
                    tmuxWindowID: terminal.tmuxWindowID,
                    tmuxBridge: appState.tmuxBridge
                )
                .frame(height: appState.conductorHeight)
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
                    if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if dragStartHeight == 0 { dragStartHeight = appState.conductorHeight }
                            let proposed = dragStartHeight + value.translation.height
                            let clamped = max(minHeight, min(maxHeight, proposed))
                            dragIndicatorOffset = clamped - appState.conductorHeight
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
            .background(.ultraThinMaterial)
        }
    }
}
