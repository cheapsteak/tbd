import AppKit
import Foundation
import TestSupport
import SwiftTerm
import Testing
@testable import TBDApp

/// R6-H3: file URLs dropped onto the terminal synthesize shell-quoted path
/// text that used to bypass `PasteInterception` and ride `send()` — while
/// control-mode attached that means ONE arbitrarily large `.input` sidecar
/// frame, and an oversize frame trips the daemon-side scanner's desync,
/// tearing down the app-wide shared sidecar connection (no Phase A
/// reconnect). Dropped paths are a paste-shaped bulk insert, so they must
/// ride the SAME decision path as a pasteboard paste.
///
/// These pin the routing branches of `TBDTerminalView.deliverDroppedText`
/// (split from `performDragOperation`, whose `NSDraggingInfo` is not
/// constructible headlessly): attached → the control-mode paste handler owns
/// the bytes; detached → the local keystroke path, byte-for-byte unchanged.
@MainActor
@Suite("Drag-drop paste routing")
struct DragDropPasteRoutingTests {

    /// Records what reaches the local keystroke path (the pre-control-mode
    /// destination of a drop).
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
        let defaultsSuite = TestDefaultsSuite("DragDropRouting")
        defer { defaultsSuite.tearDown() }
        let defaults = defaultsSuite.defaults
        let view = TBDTerminalView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 200),
            font: TBDTerminalView.defaultMonospaceFont,
            appearance: AppearanceSettings(defaults: defaults))
        let recorder = SendRecorder()
        view.terminalDelegate = recorder
        body(view, recorder)
    }

    @Test("attached: the control-mode paste handler consumes the drop — nothing rides the keystroke path")
    func attachedDropRidesPastePath() {
        withView { view, recorder in
            var handlerReceived: [Data] = []
            view.onControlModePaste = { data in
                handlerReceived.append(data)
                return true   // consumed: shipped as a .paste frame (or refused oversize)
            }

            view.deliverDroppedText("'/tmp/a file.txt' /tmp/b.txt")

            #expect(handlerReceived == [Data("'/tmp/a file.txt' /tmp/b.txt".utf8)])
            #expect(recorder.sent.isEmpty, "a consumed drop must not ALSO ride send()")
        }
    }

    @Test("handler declines (not attached): the drop falls through to the keystroke path")
    func decliningHandlerFallsThrough() {
        withView { view, recorder in
            view.onControlModePaste = { _ in false }   // PasteInterception said .passthrough

            view.deliverDroppedText("/tmp/plain.txt")

            #expect(recorder.sent == [[UInt8]("/tmp/plain.txt".utf8)])
        }
    }

    @Test("no handler (detached): pre-control-mode behavior, bytes ride send() unchanged")
    func detachedDropUsesLocalPath() {
        withView { view, recorder in
            view.onControlModePaste = nil

            view.deliverDroppedText("/tmp/detached.txt")

            #expect(recorder.sent == [[UInt8]("/tmp/detached.txt".utf8)])
        }
    }
}
