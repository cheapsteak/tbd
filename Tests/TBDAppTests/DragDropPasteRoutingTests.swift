import AppKit
import Foundation
import SwiftTerm
import Testing
@testable import TBDApp
import TestSupport

/// File URLs dropped onto the terminal synthesize shell-quoted path text. This
/// pins where `TBDTerminalView.deliverDroppedText` (split from
/// `performDragOperation`, whose `NSDraggingInfo` is not constructible
/// headlessly) sends it: the local keystroke path, byte for byte.
@MainActor
@Suite("Drag-drop paste routing")
struct DragDropPasteRoutingTests {

    /// Records what reaches the local keystroke path.
    private final class SendRecorder: TerminalViewDelegate {
        var sent: [[UInt8]] = []
        func send(source: TerminalView, data: ArraySlice<UInt8>) { sent.append([UInt8](data)) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func bell(source: TerminalView) {}
    }

    private func withView(_ body: (TBDTerminalView, SendRecorder) -> Void) {
        // Isolated defaults: AppearanceSettings must never read/write the
        // developer's real TBDApp.plist (Tests-must-not-touch-~/tbd rule's
        // UserDefaults twin).
        let suite = TestDefaultsSuite("TBDAppTests.DragDropRouting")
        let defaults = suite.defaults
        defer { suite.tearDown() }
        let view = TBDTerminalView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 200),
            font: TBDTerminalView.defaultMonospaceFont,
            appearance: AppearanceSettings(defaults: defaults))
        let recorder = SendRecorder()
        view.terminalDelegate = recorder
        body(view, recorder)
    }

    @Test("a drop rides send() unchanged")
    func dropUsesLocalPath() {
        withView { view, recorder in
            view.deliverDroppedText("'/tmp/a file.txt' /tmp/b.txt")

            #expect(recorder.sent == [[UInt8]("'/tmp/a file.txt' /tmp/b.txt".utf8)])
        }
    }
}
