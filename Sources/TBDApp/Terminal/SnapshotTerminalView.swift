import SwiftUI
import SwiftTerm
import AppKit

/// Displays a read-only snapshot of a terminal's last state before suspend.
/// Uses SwiftTerm's TerminalView to render ANSI escape sequences with full color.
/// Defers feeding content until after first layout so the terminal geometry
/// matches the actual view size, preventing incorrect line wrapping.
struct SnapshotTerminalView: NSViewRepresentable {
    let snapshot: String

    func makeNSView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: .zero)
        tv.nativeBackgroundColor = NSColor.black
        tv.nativeForegroundColor = NSColor(white: 0.85, alpha: 1.0)
        tv.allowMouseReporting = false
        return tv
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        // Feed snapshot once the view has real dimensions from layout
        if nsView.bounds.width > 0 && !context.coordinator.hasFed {
            context.coordinator.hasFed = true
            nsView.feed(text: snapshot)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var hasFed = false
    }
}
