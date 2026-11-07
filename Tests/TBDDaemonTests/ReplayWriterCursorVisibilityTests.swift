import Foundation
import SwiftTerm
import Testing

@testable import TBDDaemonLib

/// SwiftTerm shows the cursor on every `?1049h`, so the replay must set a hidden
/// cursor after the alt-screen switch, not before it.
private final class CursorProbeDelegate: TerminalDelegate {
    var bytes: [UInt8] = []
    func send(source: Terminal, data: ArraySlice<UInt8>) { bytes.append(contentsOf: data) }
}

@Suite("ReplayWriter cursor visibility")
struct ReplayWriterCursorVisibilityTests {
    private let esc = "\u{1b}"

    private func makeState(alternateOn: Bool, cursorVisible: Bool) -> PaneState {
        PaneState(
            paneID: "%1", cursorX: 0, cursorY: 0,
            alternateOn: alternateOn,
            alternateSavedX: nil, alternateSavedY: nil,
            scrollRegionUpper: 0, scrollRegionLower: 24,
            cursorVisible: cursorVisible, insertMode: false,
            applicationCursorKeys: false, applicationKeypad: false,
            wraparound: true,
            mouseStandard: false, mouseButton: false,
            mouseAny: false, mouseSGR: false,
            originMode: false, paneInMode: 0,
            width: 80, height: 25, historySize: 0)
    }

    private func assemble(_ state: PaneState) throws -> Data {
        try ReplayWriter.assemble(
            history: [], altScreen: state.alternateOn ? [] : nil, pending: [],
            state: state, cols: 80, rows: 25)
    }

    /// Feeds `data` to a fresh SwiftTerm terminal and reads DECRQM `?25`
    /// (1 = visible, 2 = hidden).
    private func cursorMode(after data: Data) -> Int? {
        let delegate = CursorProbeDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 80, rows: 25))
        terminal.feed(byteArray: [UInt8](data))
        delegate.bytes.removeAll()
        terminal.feed(text: "\(esc)[?25$p")
        let reply = String(bytes: delegate.bytes, encoding: .utf8) ?? ""
        guard let head = reply.range(of: "?25;"),
              let tail = reply[head.upperBound...].range(of: "$y") else { return nil }
        return Int(reply[head.upperBound..<tail.lowerBound])
    }

    @Test("A hidden cursor on an alt screen stays hidden")
    func hiddenOnAltScreen() throws {
        let data = try assemble(makeState(alternateOn: true, cursorVisible: false))
        #expect(cursorMode(after: data) == 2)
    }

    @Test("A visible cursor on an alt screen stays visible")
    func visibleOnAltScreen() throws {
        let data = try assemble(makeState(alternateOn: true, cursorVisible: true))
        #expect(cursorMode(after: data) == 1)
    }

    @Test("A hidden cursor on the primary screen stays hidden")
    func hiddenOnPrimaryScreen() throws {
        let data = try assemble(makeState(alternateOn: false, cursorVisible: false))
        #expect(cursorMode(after: data) == 2)
    }

    @Test("The assembled bytes set cursor visibility after the alt-screen switch")
    func visibilityFollowsSwitch() throws {
        let data = try assemble(makeState(alternateOn: true, cursorVisible: false))
        let text = String(decoding: data, as: UTF8.self)
        let switchRange = try #require(text.range(of: "\(esc)[?1049h"))
        let lastVisibility = try #require(text.range(of: "\(esc)[?25", options: .backwards))
        #expect(lastVisibility.lowerBound > switchRange.upperBound)
        #expect(text[lastVisibility.upperBound...].hasPrefix("l"))
    }
}
