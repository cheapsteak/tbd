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
/// A state may differ only when the two engines hold different screens for the same bytes, and
/// only in the fields its entry names. Those states are listed with the reason, and the list is
/// exact: a new difference fails, a difference in a field the entry does not name fails, and so
/// does a listed field that stops differing, which means the list is stale. The lists are derived
/// from the proof of concept's engine comparison, which found these cells and cursors differing;
/// CI confirms them against the pinned SwiftTerm fork.
///
/// Every body runs on a thread the tests own, one at a time: see `onHandoverThread`.
@Suite(.serialized, .fastPassBounded)
struct ProjectionParityTests {
    /// The two line counts asked for: none, which must read no row, and more than any state's
    /// screen, which reaches into every state's scrollback.
    static let lineCounts = [0, 1_000]
    static let captureScrollback = 1_000

    /// A state listed as differing in one walk: why, and the only fields it may differ in.
    struct Miss: Sendable {
        let reason: String
        let fields: Set<String>
    }

    /// The projection's fields are `lines`, `viewportStart`, `cursor`, `size` and `modes`. With
    /// no lines asked for, both engines start the viewport at minus the row count, so the rows SU
    /// keeps as scrollback move `viewportStart` only when lines are read.
    static let projectionMisses: [String: Miss] = [
        "scroll-up-down": Miss(
            reason: "libghostty keeps the rows SU scrolls off the top as scrollback; SwiftTerm deletes them",
            fields: ["lines", "viewportStart"]),
        "vs16-at-edge": Miss(
            reason: "libghostty widens a heart with VS16 to two columns and wraps it to the next row; SwiftTerm keeps it one column wide in the last column, so the text and the cursor differ",
            fields: ["lines", "cursor"]),
        "wide-overwrite-tail": Miss(
            reason: "printing over the second half of a wide character: libghostty clears its first half, SwiftTerm keeps it",
            fields: ["lines"]),
    ]

    /// A capture is one field, `text`.
    static let captureMisses: [String: Miss] = [
        "scroll-up-down": Miss(
            reason: "libghostty keeps the rows SU scrolls off the top as scrollback; SwiftTerm deletes them",
            fields: ["text"]),
        "vs16-at-edge": Miss(
            reason: "libghostty widens a heart with VS16 to two columns and wraps it to the next row; SwiftTerm keeps it in the last column",
            fields: ["text"]),
        "wide-overwrite-tail": Miss(
            reason: "printing over the second half of a wide character: libghostty clears its first half, SwiftTerm keeps it",
            fields: ["text"]),
    ]

    @Test(arguments: HandoverCorpus.names)
    func projectionMatchesSwiftTermAcrossTheCorpus(_ name: String) async throws {
        try await onHandoverThread {
            let state = HandoverFixtures.state(named: name)
            let swiftTerm = state.swiftTerm()
            let ghostty = try state.ghostty()

            // Each differing field, with its first difference.
            var differences: [String: String] = [:]
            func note(_ field: String, _ maxLines: Int, _ detail: @autoclosure () -> String) {
                if differences[field] == nil { differences[field] = "maxLines \(maxLines): \(detail())" }
            }
            for maxLines in Self.lineCounts {
                let expected = swiftTerm.locked { TerminalScreenProjection.project($0, maxLines: maxLines) }
                let actual = ghostty.withLocked { GhosttyScreenProjection.project($0, maxLines: maxLines) }
                guard expected != actual else { continue }
                if expected.lines != actual.lines {
                    note("lines", maxLines, handoverFirstDifference(expected.lines, actual.lines))
                }
                if expected.viewportStart != actual.viewportStart {
                    note("viewportStart", maxLines, "\(expected.viewportStart) vs \(actual.viewportStart)")
                }
                if expected.cursorRow != actual.cursorRow || expected.cursorColumn != actual.cursorColumn {
                    note("cursor", maxLines, "\(expected.cursorColumn),\(expected.cursorRow) vs \(actual.cursorColumn),\(actual.cursorRow) (x,y)")
                }
                if expected.size != actual.size { note("size", maxLines, "\(expected.size) vs \(actual.size)") }
                if expected.modes != actual.modes { note("modes", maxLines, "\(expected.modes) vs \(actual.modes)") }
            }
            Self.expectOutcome(name, differences: differences, misses: Self.projectionMisses, walk: "projection")

            let expectedCapture = swiftTerm.locked {
                TerminalCellWalk.styledCapture(of: $0, maxScrollbackLines: Self.captureScrollback)
            }
            let actualCapture = ghostty.withLocked {
                GhosttyScreenProjection.styledCapture($0, maxScrollbackLines: Self.captureScrollback)
            }
            var captureDifferences: [String: String] = [:]
            if expectedCapture != actualCapture {
                captureDifferences["text"] = handoverFirstDifference(
                    expectedCapture.components(separatedBy: "\r\n"), actualCapture.components(separatedBy: "\r\n"))
            }
            Self.expectOutcome(name, differences: captureDifferences, misses: Self.captureMisses, walk: "styled capture")
        }
    }

    @Test func knownMissesNameCorpusStates() {
        let names = Set(HandoverCorpus.names)
        for (name, miss) in Array(Self.projectionMisses) + Array(Self.captureMisses) {
            #expect(names.contains(name), "\(name) is listed as a miss but is not a corpus state")
            #expect(!miss.fields.isEmpty, "\(name) is listed as a miss with no field it may differ in")
        }
    }

    private static func expectOutcome(_ name: String, differences: [String: String], misses: [String: Miss], walk: String) {
        func summary(_ fields: [String: String]) -> String {
            fields.keys.sorted().map { "\($0): \(fields[$0] ?? "")" }.joined(separator: " | ")
        }
        if let miss = misses[name] {
            let matching = miss.fields.subtracting(differences.keys)
            #expect(
                matching.isEmpty,
                "\(name) is a known \(walk) miss (\(miss.reason)) but now matches SwiftTerm in \(matching.sorted()): remove them from its entry")
            let unexplained = differences.filter { !miss.fields.contains($0.key) }
            #expect(
                unexplained.isEmpty,
                "\(name): the \(walk) differs from SwiftTerm's beyond its known miss (\(miss.reason)): \(summary(unexplained))")
        } else {
            #expect(differences.isEmpty, "\(name): the \(walk) differs from SwiftTerm's: \(summary(differences))")
        }
    }
}
