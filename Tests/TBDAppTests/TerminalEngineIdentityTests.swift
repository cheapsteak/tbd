import AppKit
import Foundation
import os
import Testing
@testable import TBDApp
import TBDGhosttyTerminal
import TBDShared
import TestSupport

/// A program sees one terminal whichever engine draws it: libghostty answers
/// the identity queries and the OSC 7501 probe with SwiftTerm's bytes, and
/// the reports it hands over parsed come out the other side as the daemon
/// would have read the raw ones.
///
/// The engine-level checks build both engines through the factory and need a
/// Metal device for libghostty's view; without one they skip with that reason.
/// The checks below them drive a headless libghostty terminal, which needs no
/// Metal, so the parts of the identity that live in the adapter are covered on
/// every runner. Design: `docs/specs/2026-11-07-libghostty-terminal-engine-design.md`.
@MainActor
@Suite("Terminal engine identity", .fastPassBounded)
struct TerminalEngineIdentityTests {
    private static let da1 = "\u{1b}[c"
    private static let da2 = "\u{1b}[>c"
    private static let xtversion = "\u{1b}[>0q"
    private static let probe = "\u{1b}]7501;?\u{07}"
    private static var probeReply: [UInt8] { Array(ProgramStatusProtocol.probeReply.utf8) }
    /// What starts libghostty's own probe answer, which must never reach a pty.
    private static var libghosttyAnswerStart: [UInt8] { Array("\u{1b}]7501;?:".utf8) }

    // MARK: - Both engines

    @Test("DA1, DA2 and XTVERSION get the same bytes from libghostty as from SwiftTerm",
          .enabled(if: EngineTestSupport.canBuildGhostty, EngineTestSupport.noMetalDevice))
    func bothEnginesAnswerDeviceAttributesTheSame() async {
        let swiftTerm = EngineUnderTest(kind: .swiftTerm, label: "EngineIdentity.SwiftTerm")
        let ghostty = EngineUnderTest(kind: .ghostty, label: "EngineIdentity.Ghostty")
        defer {
            swiftTerm.tearDown()
            ghostty.tearDown()
        }
        #expect(ghostty.engine.kind == .ghostty, "the factory fell back, so this compares SwiftTerm with itself")
        await EngineTestSupport.settle()

        let queries: [(name: String, query: String, replyStart: String)] = [
            ("DA1", Self.da1, "\u{1b}[?"),
            ("DA2", Self.da2, "\u{1b}[>"),
            ("XTVERSION", Self.xtversion, "\u{1b}P>|"),
        ]
        for (name, query, replyStart) in queries {
            swiftTerm.recorder.reset()
            ghostty.recorder.reset()
            swiftTerm.feed(query)
            ghostty.feed(query)
            let answered = await EngineTestSupport.waitUntil(
                "both engines to answer \(name)",
                observed: { "SwiftTerm \(swiftTerm.recorder.summary); libghostty \(ghostty.recorder.summary)" }
            ) {
                !swiftTerm.recorder.sent.isEmpty && !ghostty.recorder.sent.isEmpty
            }
            guard answered else { return }
            await EngineTestSupport.settle()

            let expected = swiftTerm.recorder.sent
            #expect(expected.starts(with: Array(replyStart.utf8)),
                    "SwiftTerm's \(name) reply \(EngineTestSupport.describe(expected)) is not one, so this compares nothing")
            #expect(ghostty.recorder.sent == expected,
                    "\(name): libghostty answered \(EngineTestSupport.describe(ghostty.recorder.sent)), SwiftTerm \(EngineTestSupport.describe(expected))")
        }
    }

    /// DA1 follows the probe as Claude Code sends it, and is the barrier: once
    /// its reply is in, the probe has been decided.
    @Test("The OSC 7501 probe, then DA1, gets the same bytes from both engines, with reporting on and with it off",
          .enabled(if: EngineTestSupport.canBuildGhostty, EngineTestSupport.noMetalDevice),
          arguments: [true, false])
    func bothEnginesAnswerTheProgramStatusProbeTheSame(reporting: Bool) async {
        let swiftTerm = EngineUnderTest(kind: .swiftTerm, label: "EngineIdentity.ProbeSwiftTerm")
        let ghostty = EngineUnderTest(kind: .ghostty, label: "EngineIdentity.ProbeGhostty")
        defer {
            swiftTerm.tearDown()
            ghostty.tearDown()
        }
        #expect(ghostty.engine.kind == .ghostty, "the factory fell back, so this compares SwiftTerm with itself")
        swiftTerm.engine.setProgramStatusReporting(enabled: reporting)
        ghostty.engine.setProgramStatusReporting(enabled: reporting)
        await EngineTestSupport.settle()
        swiftTerm.recorder.reset()
        ghostty.recorder.reset()

        swiftTerm.feed(Self.probe + Self.da1)
        ghostty.feed(Self.probe + Self.da1)
        let da1ReplyStart = Array("\u{1b}[?".utf8)
        let answered = await EngineTestSupport.waitUntil(
            "both engines to answer the DA1 behind the probe",
            observed: { "SwiftTerm \(swiftTerm.recorder.summary); libghostty \(ghostty.recorder.summary)" }
        ) {
            Self.contains(da1ReplyStart, in: swiftTerm.recorder.sent)
                && Self.contains(da1ReplyStart, in: ghostty.recorder.sent)
        }
        guard answered else { return }
        await EngineTestSupport.settle()

        let expected = swiftTerm.recorder.sent
        let actual = ghostty.recorder.sent
        #expect(actual == expected,
                "reporting \(reporting): libghostty sent \(EngineTestSupport.describe(actual)), SwiftTerm \(EngineTestSupport.describe(expected))")
        #expect(!Self.contains(Self.libghosttyAnswerStart, in: actual),
                "libghostty's own probe answer reached send: \(EngineTestSupport.describe(actual))")
        if reporting {
            #expect(actual.starts(with: Self.probeReply), "with reporting on the probe must be answered first")
        } else {
            #expect(!Self.contains(Self.probeReply, in: actual), "with reporting off the probe must go unanswered")
        }
    }

    // MARK: - The adapter, headless

    /// The answers the engine hands libghostty are read from SwiftTerm at run
    /// time. Fed to a headless libghostty terminal, they must give SwiftTerm's
    /// bytes exactly; this runs without Metal, where the engine-level check
    /// above cannot.
    @Test("libghostty given SwiftTerm's identity answers DA1, DA2 and XTVERSION with SwiftTerm's bytes")
    func libghosttyGivenSwiftTermsIdentityAnswersWithItsBytes() throws {
        let identity = SwiftTermDeviceIdentity.answers
        let attributes = try #require(identity.deviceAttributes, "SwiftTerm's DA1 or DA2 reply did not parse")
        let version = try #require(identity.xtversion, "SwiftTerm's XTVERSION reply did not parse")
        let writes = OSAllocatedUnfairLock<[UInt8]>(initialState: [])
        let terminal = try TBDGhosttyTerminal.GhosttyTerminal(
            cols: 80, rows: 24, scrollbackLines: 100,
            callbacks: GhosttyTerminalCallbacks(
                writePty: { bytes in writes.withLock { $0.append(contentsOf: bytes) } },
                deviceAttributes: { attributes },
                xtversion: { version }))
        defer { terminal.close() }
        let swiftTerm = SwiftTermDeviceIdentity.rawAnswers()

        let pairs: [(name: String, query: String, expected: [UInt8])] = [
            ("DA1", Self.da1, swiftTerm.da1),
            ("DA2", Self.da2, swiftTerm.da2),
            ("XTVERSION", Self.xtversion, swiftTerm.xtversion),
        ]
        for (name, query, expected) in pairs {
            writes.withLock { $0 = [] }
            terminal.feed(text: query)
            let answer = writes.withLock { $0 }
            #expect(!expected.isEmpty, "SwiftTerm gave no \(name) reply")
            #expect(answer == expected,
                    "\(name): libghostty answered \(EngineTestSupport.describe(answer)), SwiftTerm \(EngineTestSupport.describe(expected))")
        }
    }

    /// Ties the swap to libghostty's real bytes: what it writes for the probe
    /// is recognised as its answer, whole, and nothing of it survives removal.
    @Test("libghostty's own answer to the probe is recognised and swapped whole")
    func libghosttysOwnProbeAnswerIsRecognised() throws {
        let writes = OSAllocatedUnfairLock<[UInt8]>(initialState: [])
        let terminal = try TBDGhosttyTerminal.GhosttyTerminal(
            cols: 80, rows: 24, scrollbackLines: 100,
            callbacks: GhosttyTerminalCallbacks(
                writePty: { bytes in writes.withLock { $0.append(contentsOf: bytes) } },
                // libghostty answers the probe only while this is set.
                programStatus: { _ in }))
        defer { terminal.close() }

        terminal.feed(text: Self.probe)
        let answer = writes.withLock { $0 }
        #expect(answer.starts(with: Self.libghosttyAnswerStart),
                "libghostty's probe answer changed shape: \(EngineTestSupport.describe(answer))")
        #expect(ProgramStatusProbeAnswer.replacingLibghosttyAnswers(in: answer, with: nil).isEmpty,
                "removing libghostty's answer left \(EngineTestSupport.describe(answer))")
        #expect(ProgramStatusProbeAnswer.replacingLibghosttyAnswers(in: answer, with: Self.probeReply) == Self.probeReply)
    }

    @Test("A probe answer is swapped in place among other replies, removed when there is no replacement, and an unfinished one is left alone")
    func probeAnswerIsSwappedInPlace() {
        let reply = Array("\u{1b}[?65;1c".utf8)
        let answerST = Array("\u{1b}]7501;?:states=idle,working:kinds=permission\u{1b}\\".utf8)
        let answerBEL = Array("\u{1b}]7501;?:states=idle\u{07}".utf8)
        let unfinished = Array("\u{1b}]7501;?:states=idle".utf8)
        let report = Array("\u{1b}]7501;state=idle\u{07}".utf8)
        func swap(_ bytes: [UInt8], _ replacement: [UInt8]?) -> [UInt8] {
            ProgramStatusProbeAnswer.replacingLibghosttyAnswers(in: bytes, with: replacement)
        }

        #expect(swap(reply + answerST + reply, Self.probeReply) == reply + Self.probeReply + reply)
        #expect(swap(reply + answerST + reply, nil) == reply + reply)
        #expect(swap(answerBEL + answerST, Self.probeReply) == Self.probeReply + Self.probeReply)
        #expect(swap(reply + unfinished, Self.probeReply) == reply + unfinished)
        #expect(swap(reply, Self.probeReply) == reply)
        #expect(swap(report, nil) == report, "a reply that is not a probe answer was touched")
        #expect(swap([], Self.probeReply).isEmpty)
    }

    /// No Claude recording is committed to read reports from, so the corpus is
    /// the shapes Claude Code sends: its main entry through every state, a
    /// blocked prompt of each kind with a title and a message, a task entry
    /// with an id, its clear, progress while working, and text outside ASCII.
    nonisolated private static let claudeReports: [String] = [
        "state=working:app=claude-code",
        "state=working:app=claude-code:progress=40",
        "state=idle:app=claude-code",
        "state=done:app=claude-code:msg=\(base64("Finished the refactor"))",
        "state=blocked:kind=permission:app=claude-code:title=\(base64("Bash"))"
            + ":msg=\(base64("Allow rm -r build?"))",
        "state=blocked:kind=question:app=claude-code:msg=\(base64("Which branch should I use?"))",
        "state=blocked:kind=auth:app=claude-code:msg=\(base64("Log in to continue"))",
        "state=working:app=claude-code:id=task-1:title=\(base64("Explore the repo"))",
        "state=done:app=claude-code:id=task-1",
        "state=clear:id=task-1",
        "state=error:app=claude-code:msg=\(base64("API error: overloaded"))",
        "state=done:app=claude-code:title=\(base64("Résumé ✓"))",
    ]

    @Test("Each Claude-shaped report, parsed by libghostty and written back, parses as the raw report does")
    func rebuiltProgramStatusPayloadParsesLikeTheRawOne() throws {
        let received = OSAllocatedUnfairLock<[GhosttyTerminalCallbacks.ProgramStatus]>(initialState: [])
        let terminal = try TBDGhosttyTerminal.GhosttyTerminal(
            cols: 80, rows: 24, scrollbackLines: 100,
            callbacks: GhosttyTerminalCallbacks(programStatus: { status in
                received.withLock { $0.append(status) }
            }))
        defer { terminal.close() }

        for data in Self.claudeReports {
            received.withLock { $0 = [] }
            terminal.feed(text: "\u{1b}]7501;\(data)\u{1b}\\")
            let statuses = received.withLock { $0 }
            #expect(statuses.count == 1, "libghostty delivered \(statuses.count) reports for \(data)")
            guard let status = statuses.first else { continue }

            let raw = ProgramStatusParser.parse(Array(data.utf8))
            #expect(raw != nil, "TBD's parser rejects the corpus report \(data)")
            let rebuilt = ProgramStatusPayloadBuilder.payload(for: status)
            #expect(ProgramStatusParser.parse(rebuilt) == raw,
                    "\(data) came back as \(EngineTestSupport.describe(rebuilt))")
        }
    }

    // MARK: - Helpers

    nonisolated private static func base64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    nonisolated private static func contains(_ needle: [UInt8], in haystack: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return needle.isEmpty }
        for start in 0...(haystack.count - needle.count)
        where haystack[start..<(start + needle.count)].elementsEqual(needle) {
            return true
        }
        return false
    }
}
