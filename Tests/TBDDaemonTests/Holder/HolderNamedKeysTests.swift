import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// `HolderNamedKeys.bytes(for:modes:)` is entirely branches — a table lookup
/// with two families whose answer depends on DECCKM and the rest fixed per
/// name — so there is no computation for a test to exercise except "is this
/// literal byte sequence the one that comes out." A byte transposed in one
/// escape sequence (`ESC O A` vs `ESC [ A`, an `~` dropped from a paging key,
/// an off-by-one in a function-key CSI number) would still return non-nil and
/// still look plausible, so nothing short of asserting the exact bytes for
/// every branch — including both DECCKM states and the `nil`-modes default —
/// catches it. This file walks every case in the table plus the unknown-name
/// fallthrough to `nil`.
@Suite struct HolderNamedKeysTests {

    private static let cursorOn = TerminalScreen.ChildModes(
        bracketedPaste: false, applicationCursor: true, alternateScreen: false)
    private static let cursorOff = TerminalScreen.ChildModes(
        bracketedPaste: false, applicationCursor: false, alternateScreen: false)

    // MARK: - Control combos

    @Test(arguments: [
        ("C-Space", Data([0x00])),
        ("C-@", Data([0x00])),
        ("C-a", Data([0x01])),
        ("C-z", Data([0x1a])),
        ("C-A", Data([0x01])),
        ("C-Z", Data([0x1a])),
        ("C-[", Data([0x1b])),
        ("C-\\", Data([0x1c])),
        ("C-]", Data([0x1d])),
        ("C-^", Data([0x1e])),
        ("C-_", Data([0x1f])),
    ])
    func controlCombosProduceTheirC0Byte(name: String, expected: Data) {
        let actual = HolderNamedKeys.bytes(for: name, modes: nil)
        #expect(actual == expected, """
            \(name) → \(actual.map({ Array($0) }) as Any), expected \(Array(expected))
            """)
    }

    // MARK: - Fixed-byte named keys (mode-independent)

    @Test(arguments: [
        ("Enter", Data([0x0d])),
        ("Return", Data([0x0d])),
        ("Escape", Data([0x1b])),
        ("Esc", Data([0x1b])),
        ("Tab", Data([0x09])),
        ("BTab", Data([0x1b, 0x5b, 0x5a])),
        ("BSpace", Data([0x7f])),
        ("BackSpace", Data([0x7f])),
        ("Space", Data([0x20])),
    ])
    func fixedByteKeysAreModeIndependent(name: String, expected: Data) {
        let actual = HolderNamedKeys.bytes(for: name, modes: nil)
        #expect(actual == expected, """
            \(name) → \(actual.map({ Array($0) }) as Any), expected \(Array(expected))
            """)
    }

    // MARK: - Cursor family, DECCKM on: SS3 (`ESC O <final>`)

    @Test(arguments: [
        ("Up", Data([0x1b, 0x4f, 0x41])),
        ("Down", Data([0x1b, 0x4f, 0x42])),
        ("Right", Data([0x1b, 0x4f, 0x43])),
        ("Left", Data([0x1b, 0x4f, 0x44])),
        ("Home", Data([0x1b, 0x4f, 0x48])),
        ("End", Data([0x1b, 0x4f, 0x46])),
    ])
    func cursorKeysUnderApplicationCursorTakeSS3Form(name: String, expected: Data) {
        let actual = HolderNamedKeys.bytes(for: name, modes: Self.cursorOn)
        #expect(actual == expected, """
            \(name) under DECCKM → \(actual.map({ Array($0) }) as Any), expected \(Array(expected))
            """)
    }

    // MARK: - Cursor family, DECCKM off (and the `nil`-modes default): CSI (`ESC [ <final>`)

    @Test(arguments: [
        ("Up", Data([0x1b, 0x5b, 0x41])),
        ("Down", Data([0x1b, 0x5b, 0x42])),
        ("Right", Data([0x1b, 0x5b, 0x43])),
        ("Left", Data([0x1b, 0x5b, 0x44])),
        ("Home", Data([0x1b, 0x5b, 0x48])),
        ("End", Data([0x1b, 0x5b, 0x46])),
    ])
    func cursorKeysWithoutApplicationCursorTakeCSIForm(name: String, expected: Data) {
        let actual = HolderNamedKeys.bytes(for: name, modes: Self.cursorOff)
        #expect(actual == expected, """
            \(name) without DECCKM → \(actual.map({ Array($0) }) as Any), expected \(Array(expected))
            """)
    }

    /// `modes: nil` must read as DECCKM off, not as some third state — this is
    /// the `applicationCursor = modes?.applicationCursor ?? false` default.
    @Test func nilModesDefaultsToCSICursorForm() {
        let actual = HolderNamedKeys.bytes(for: "Up", modes: nil)
        #expect(actual == Data([0x1b, 0x5b, 0x41]), """
            Up with nil modes → \(actual.map({ Array($0) }) as Any), expected the CSI form \
            [0x1b, 0x5b, 0x41] — nil must default to DECCKM off
            """)
    }

    // MARK: - Paging and editing keys (mode-independent)

    @Test(arguments: [
        ("PageUp", Data([0x1b, 0x5b, 0x35, 0x7e])),
        ("PPage", Data([0x1b, 0x5b, 0x35, 0x7e])),
        ("PageDown", Data([0x1b, 0x5b, 0x36, 0x7e])),
        ("NPage", Data([0x1b, 0x5b, 0x36, 0x7e])),
        ("Insert", Data([0x1b, 0x5b, 0x32, 0x7e])),
        ("IC", Data([0x1b, 0x5b, 0x32, 0x7e])),
        ("Delete", Data([0x1b, 0x5b, 0x33, 0x7e])),
        ("DC", Data([0x1b, 0x5b, 0x33, 0x7e])),
    ])
    func pagingAndEditingKeysAreModeIndependent(name: String, expected: Data) {
        let actual = HolderNamedKeys.bytes(for: name, modes: nil)
        #expect(actual == expected, """
            \(name) → \(actual.map({ Array($0) }) as Any), expected \(Array(expected))
            """)
    }

    // MARK: - Function keys (mode-independent)

    @Test(arguments: [
        ("F1", Data([0x1b, 0x4f, 0x50])),
        ("F2", Data([0x1b, 0x4f, 0x51])),
        ("F3", Data([0x1b, 0x4f, 0x52])),
        ("F4", Data([0x1b, 0x4f, 0x53])),
        ("F5", Data([0x1b, 0x5b, 0x31, 0x35, 0x7e])),
        ("F6", Data([0x1b, 0x5b, 0x31, 0x37, 0x7e])),
        ("F7", Data([0x1b, 0x5b, 0x31, 0x38, 0x7e])),
        ("F8", Data([0x1b, 0x5b, 0x31, 0x39, 0x7e])),
        ("F9", Data([0x1b, 0x5b, 0x32, 0x30, 0x7e])),
        ("F10", Data([0x1b, 0x5b, 0x32, 0x31, 0x7e])),
        ("F11", Data([0x1b, 0x5b, 0x32, 0x33, 0x7e])),
        ("F12", Data([0x1b, 0x5b, 0x32, 0x34, 0x7e])),
    ])
    func functionKeysAreModeIndependent(name: String, expected: Data) {
        let actual = HolderNamedKeys.bytes(for: name, modes: nil)
        #expect(actual == expected, """
            \(name) → \(actual.map({ Array($0) }) as Any), expected \(Array(expected))
            """)
    }

    // MARK: - Unknown names

    @Test(arguments: ["Bogus", "", "C-", "C-ab", "up"])
    func unknownOrMalformedNamesReturnNil(name: String) {
        let actual = HolderNamedKeys.bytes(for: name, modes: nil)
        #expect(actual == nil, "\(name) → \(actual.map({ Array($0) }) as Any), expected nil")
    }
}
