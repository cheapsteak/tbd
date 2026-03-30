import SwiftUI
import SwiftTerm
import AppKit

/// Displays a read-only snapshot of a terminal's last state before suspend.
/// Uses SwiftTerm's TerminalView to render ANSI escape sequences with full color.
struct SnapshotTerminalView: NSViewRepresentable {
    let snapshot: String

    func makeNSView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        tv.nativeBackgroundColor = NSColor.black
        tv.nativeForegroundColor = NSColor(white: 0.85, alpha: 1.0)
        tv.allowMouseReporting = false

        // Feed the captured ANSI snapshot into the terminal emulator
        tv.feed(text: snapshot)

        return tv
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        // Static snapshot — no updates needed
    }
}
