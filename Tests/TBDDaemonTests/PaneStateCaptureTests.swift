import Foundation
import Testing
@testable import TBDDaemonLib

/// Unit tests for the replay pane-state capture format + parser (addendum §3,
/// capture step: `list-panes -F` pane state). No tmux.
@Suite("PaneStateCapture")
struct PaneStateCaptureTests {

    /// A fabricated response line in the canonical field order. Field values
    /// are deliberately all-distinct so a transposed field can't pass.
    private let primaryLine = "%3 17 42 0 4294967295 4294967295 2 48 1 0 1 1 1 0 1 0 1 0 0 120 49 137"

    /// An alt-screen pane: `alternate_on` = 1 and a real saved cursor.
    private let altLine = "%7 0 0 1 5 9 0 23 0 0 0 0 1 0 0 1 1 1 1 80 24 0"

    @Test("format has exactly as many fields as the parser expects, space-separated")
    func formatFieldCountMatchesParser() {
        let fields = PaneStateCapture.format.split(separator: " ", omittingEmptySubsequences: false)
        #expect(fields.count == PaneStateCapture.fieldCount)
        #expect(fields.first == "#{pane_id}")
        // Every field is a single #{...} expansion — no literal text that could
        // collide with expanded values.
        for field in fields {
            #expect(field.hasPrefix("#{") && field.hasSuffix("}"), "unexpected field shape: \(field)")
        }
    }

    @Test("listPanesCommand single-quotes the format for the control stream")
    func commandQuoting() {
        let command = PaneStateCapture.listPanesCommand(target: "%3")
        #expect(command == "list-panes -t %3 -F '\(PaneStateCapture.format)'")
        #expect(!command.contains("\n"))
    }

    @Test("round-trips a primary-screen line with every field correct")
    func roundTripPrimary() throws {
        let states = try PaneStateCapture.parse([primaryLine])
        let state = try #require(states.first)
        #expect(states.count == 1)
        #expect(state.paneID == "%3")
        #expect(state.cursorX == 17)
        #expect(state.cursorY == 42)
        #expect(state.alternateOn == false)
        // UINT_MAX sentinel (tmux's "no saved cursor") maps to nil.
        #expect(state.alternateSavedX == nil)
        #expect(state.alternateSavedY == nil)
        #expect(state.scrollRegionUpper == 2)
        #expect(state.scrollRegionLower == 48)
        #expect(state.cursorVisible == true)
        #expect(state.insertMode == false)
        #expect(state.applicationCursorKeys == true)
        #expect(state.applicationKeypad == true)
        #expect(state.wraparound == true)
        #expect(state.mouseStandard == false)
        #expect(state.mouseButton == true)
        #expect(state.mouseAny == false)
        #expect(state.mouseSGR == true)
        #expect(state.originMode == false)
        #expect(state.paneInMode == 0)
        // pane_width/pane_height (M4.3): the replay assembler's cols/rows.
        #expect(state.width == 120)
        #expect(state.height == 49)
        // history_size (review H1): gates the pure-scrollback capture leg.
        #expect(state.historySize == 137)
    }

    @Test("round-trips an alt-screen line: alternate_on and saved cursor present")
    func roundTripAltScreen() throws {
        let states = try PaneStateCapture.parse([altLine])
        let state = try #require(states.first)
        #expect(state.paneID == "%7")
        #expect(state.alternateOn == true)
        #expect(state.alternateSavedX == 5)
        #expect(state.alternateSavedY == 9)
        #expect(state.mouseAny == true)
        #expect(state.originMode == true)
        #expect(state.paneInMode == 1)
        #expect(state.width == 80)
        #expect(state.height == 24)
        #expect(state.historySize == 0)
    }

    @Test("multiple panes parse in order and filter by pane ID")
    func multiplePanesFilter() throws {
        let states = try PaneStateCapture.parse([primaryLine, altLine])
        #expect(states.map(\.paneID) == ["%3", "%7"])

        let selected = try PaneStateCapture.state(forPane: "%7", in: [primaryLine, altLine])
        #expect(selected?.paneID == "%7")
        #expect(selected?.alternateOn == true)

        let missing = try PaneStateCapture.state(forPane: "%99", in: [primaryLine, altLine])
        #expect(missing == nil)
    }

    @Test("a line with the wrong field count throws (replay must not run half-blind)")
    func wrongFieldCountThrows() {
        let truncated = "%3 17 42 0"
        #expect(throws: PaneStateCaptureError.wrongFieldCount(
            line: truncated, expected: PaneStateCapture.fieldCount, actual: 4)) {
            try PaneStateCapture.parse([truncated])
        }
    }

    @Test("an empty field (unknown format variable expanded to nothing) throws")
    func emptyFieldThrows() {
        // Simulates a format variable that doesn't exist on the running tmux:
        // it expands to empty, leaving two adjacent spaces. Field count is
        // preserved but the field itself is unparseable — must throw, not skip.
        let line = "%3 17 42 0 4294967295 4294967295 2 48 1 0 1 1 1 0 1 0 1 0 0 120 49 "
        #expect(throws: PaneStateCaptureError.self) {
            try PaneStateCapture.parse([line])
        }
    }

    @Test("a non-numeric field throws invalidField")
    func nonNumericFieldThrows() {
        let line = "%3 17 abc 0 4294967295 4294967295 2 48 1 0 1 1 1 0 1 0 1 0 0 120 49 0"
        #expect(throws: PaneStateCaptureError.invalidField(name: "cursor_y", value: "abc")) {
            try PaneStateCapture.parse([line])
        }
    }

    @Test("a bogus pane id (no % prefix) throws invalidField")
    func bogusPaneIDThrows() {
        let line = "3 17 42 0 4294967295 4294967295 2 48 1 0 1 1 1 0 1 0 1 0 0 120 49 0"
        #expect(throws: PaneStateCaptureError.invalidField(name: "pane_id", value: "3")) {
            try PaneStateCapture.parse([line])
        }
    }

    @Test("empty response yields empty result")
    func emptyResponse() throws {
        #expect(try PaneStateCapture.parse([]) == [])
    }

    @Test("blank and whitespace-only lines are tolerated, not parsed")
    func blankLinesTolerated() throws {
        let states = try PaneStateCapture.parse(["", "  ", primaryLine, ""])
        #expect(states.count == 1)
        #expect(states.first?.paneID == "%3")
    }
}
