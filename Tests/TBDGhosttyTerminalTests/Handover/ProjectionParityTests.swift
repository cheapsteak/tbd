import Foundation
import SwiftTerm
@testable import TBDGhosttyTerminal
// Scoped, so a bare `Terminal` cannot mean TBDShared's row model.
import struct TBDShared.TerminalScreen
import TBDTerminalSerialization
import TestSupport
import Testing

/// A libghostty viewer must answer the daemon's screen requests and styled captures exactly as a
/// SwiftTerm one does, so a reader cannot tell which engine replied. Every corpus state is fed to
/// both engines and both walks are compared.
///
/// A state may differ only when the two engines hold different screens for the same bytes. Those
/// states are listed with the reason, and the list is exact: a new difference fails, and so does a
/// listed state that stops differing, which means the list is stale. The lists are derived from the
/// proof of concept's engine comparison, which found these cells and cursors differing; CI confirms
/// them against the pinned SwiftTerm fork.
@Suite(.fastPassBounded)
struct ProjectionParityTests {
    /// The two line counts asked for: none, which must read no row, and more than any state's
    /// screen, which reaches into every state's scrollback.
    static let lineCounts = [0, 1_000]
    static let captureScrollback = 1_000

    static let projectionMisses: [String: String] = [
        "scroll-up-down": "libghostty keeps the rows SU scrolls off the top as scrollback; SwiftTerm deletes them",
        "vs16-at-edge": "libghostty widens a heart with VS16 to two columns and wraps it to the next row; SwiftTerm keeps it one column wide in the last column, so the text and the cursor differ",
        "wide-overwrite-tail": "printing over the second half of a wide character: libghostty clears its first half, SwiftTerm keeps it",
    ]

    static let captureMisses: [String: String] = [
        "scroll-up-down": "libghostty keeps the rows SU scrolls off the top as scrollback; SwiftTerm deletes them",
        "vs16-at-edge": "libghostty widens a heart with VS16 to two columns and wraps it to the next row; SwiftTerm keeps it in the last column",
        "wide-overwrite-tail": "printing over the second half of a wide character: libghostty clears its first half, SwiftTerm keeps it",
    ]

    @Test(arguments: HandoverCorpus.names)
    func projectionMatchesSwiftTermAcrossTheCorpus(_ name: String) throws {
        let state = HandoverCorpus.state(named: name)
        let swiftTerm = state.swiftTerm()
        let ghostty = try state.ghostty()

        var differences: [String] = []
        for maxLines in Self.lineCounts {
            let expected = swiftTerm.locked { TerminalScreenProjection.project($0, maxLines: maxLines) }
            let actual = ghostty.withLocked { GhosttyScreenProjection.project($0, maxLines: maxLines) }
            guard expected != actual else { continue }
            var parts: [String] = []
            if expected.lines != actual.lines { parts.append(handoverFirstDifference(expected.lines, actual.lines)) }
            if expected.viewportStart != actual.viewportStart {
                parts.append("viewportStart \(expected.viewportStart) vs \(actual.viewportStart)")
            }
            if expected.cursorRow != actual.cursorRow || expected.cursorColumn != actual.cursorColumn {
                parts.append("cursor \(expected.cursorColumn),\(expected.cursorRow) vs \(actual.cursorColumn),\(actual.cursorRow) (x,y)")
            }
            if expected.size != actual.size { parts.append("size \(expected.size) vs \(actual.size)") }
            if expected.modes != actual.modes { parts.append("modes \(expected.modes) vs \(actual.modes)") }
            differences.append("maxLines \(maxLines): " + parts.joined(separator: "; "))
        }
        expectOutcome(name, differences: differences, misses: Self.projectionMisses, walk: "projection")

        let expectedCapture = swiftTerm.locked {
            TerminalCellWalk.styledCapture(of: $0, maxScrollbackLines: Self.captureScrollback)
        }
        let actualCapture = ghostty.withLocked {
            GhosttyScreenProjection.styledCapture($0, maxScrollbackLines: Self.captureScrollback)
        }
        var captureDifferences: [String] = []
        if expectedCapture != actualCapture {
            captureDifferences.append(handoverFirstDifference(
                expectedCapture.components(separatedBy: "\r\n"), actualCapture.components(separatedBy: "\r\n")))
        }
        expectOutcome(name, differences: captureDifferences, misses: Self.captureMisses, walk: "styled capture")
    }

    @Test func knownMissesNameCorpusStates() {
        let names = Set(HandoverCorpus.names)
        for name in Self.projectionMisses.keys.sorted() + Self.captureMisses.keys.sorted() {
            #expect(names.contains(name), "\(name) is listed as a miss but is not a corpus state")
        }
    }

    private func expectOutcome(_ name: String, differences: [String], misses: [String: String], walk: String) {
        if let reason = misses[name] {
            #expect(
                !differences.isEmpty,
                "\(name) is a known \(walk) miss (\(reason)) but now matches SwiftTerm: remove it from the list")
        } else {
            #expect(differences.isEmpty, "\(name): the \(walk) differs from SwiftTerm's: \(differences.joined(separator: " | "))")
        }
    }
}
