import Darwin
import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

/// The daemon's headless emulator and the Program Status Protocol (OSC 7501).
///
/// Two obligations, both from the spec ("Answering the probe"): the `?` probe
/// is answered **synchronously, inside the parse**, so the reply reaches the
/// child ahead of the DA1 answer to a query queued behind it; and a handback
/// preamble — a replay — never answers a probe or delivers a report. Reports
/// the child writes reach the tap's `deliver` with their payload intact.
///
/// Driven against a real `HolderReader` over a socketpair, never started:
/// `feedChildOutputForTesting` feeds the same emulator the drain loop feeds, on
/// the calling thread, and the emulator's replies are written to the reader's
/// end of the pair, so whatever the child would have received is readable
/// from ours as soon as the feed returns.
@Suite struct HolderProgramStatusTests {

    private static let esc = "\u{1b}"
    private static let bel = "\u{07}"
    private static let probeBEL = "\u{1b}]7501;?\u{07}"
    private static let probeST = "\u{1b}]7501;?\u{1b}\\"
    private static let reportPayload = "state=working:app=claude-code"

    // MARK: - Probe

    @Test func flagOnAnswersProbeTerminatedByBEL() async throws {
        let harness = try Harness(enabled: true)
        defer { harness.tearDown() }

        await harness.reader.feedChildOutputForTesting(Data(Self.probeBEL.utf8))

        #expect(harness.readReplies() == Array(ProgramStatusProtocol.probeReply.utf8))
        #expect(harness.delivered.isEmpty, "a probe is answered, never delivered as a report")
    }

    @Test func flagOnAnswersProbeTerminatedByST() async throws {
        let harness = try Harness(enabled: true)
        defer { harness.tearDown() }

        await harness.reader.feedChildOutputForTesting(Data(Self.probeST.utf8))

        #expect(harness.readReplies() == Array(ProgramStatusProtocol.probeReply.utf8))
        #expect(harness.delivered.isEmpty)
    }

    @Test func flagOffAnswersNothingAndDeliversNothing() async throws {
        let harness = try Harness(enabled: false)
        defer { harness.tearDown() }

        await harness.reader.feedChildOutputForTesting(Data(Self.probeBEL.utf8))
        await harness.reader.feedChildOutputForTesting(
            Data("\(Self.esc)]7501;\(Self.reportPayload)\(Self.bel)".utf8))

        #expect(harness.readReplies().isEmpty)
        #expect(harness.delivered.isEmpty)
    }

    @Test func gateTurnedOffAfterConstructionSilencesTheHandler() async throws {
        let harness = try Harness(enabled: true)
        defer { harness.tearDown() }

        harness.gate.set(false)
        await harness.reader.feedChildOutputForTesting(Data(Self.probeBEL.utf8))
        await harness.reader.feedChildOutputForTesting(
            Data("\(Self.esc)]7501;\(Self.reportPayload)\(Self.bel)".utf8))

        #expect(harness.readReplies().isEmpty)
        #expect(harness.delivered.isEmpty)
    }

    @Test func noTapLeavesOSC7501Unhandled() async throws {
        let harness = try Harness(tap: false)
        defer { harness.tearDown() }

        await harness.reader.feedChildOutputForTesting(Data(Self.probeBEL.utf8))

        #expect(harness.readReplies().isEmpty)
    }

    @Test func probeReplyPrecedesDA1Reply() async throws {
        let harness = try Harness(enabled: true)
        defer { harness.tearDown() }

        // One feed, probe first: the order Claude Code writes them in.
        await harness.reader.feedChildOutputForTesting(
            Data("\(Self.probeBEL)\(Self.esc)[c".utf8))

        let replies = harness.readReplies()
        let probeReply = Array(ProgramStatusProtocol.probeReply.utf8)
        #expect(replies.count > probeReply.count, "DA1 must also have been answered")
        #expect(Array(replies.prefix(probeReply.count)) == probeReply)
        let rest = Array(replies.dropFirst(probeReply.count))
        #expect(rest.starts(with: Array("\(Self.esc)[".utf8)), "the DA1 reply follows the probe reply")
    }

    // MARK: - Reports

    @Test func reportIsDeliveredWithExactPayloadAndNotAnswered() async throws {
        let harness = try Harness(enabled: true)
        defer { harness.tearDown() }

        await harness.reader.feedChildOutputForTesting(
            Data("\(Self.esc)]7501;\(Self.reportPayload)\(Self.bel)".utf8))

        #expect(harness.delivered == [Array(Self.reportPayload.utf8)])
        #expect(harness.readReplies().isEmpty, "a report gets no reply")
    }

    @Test func reportsAreDeliveredInParseOrder() async throws {
        let harness = try Harness(enabled: true)
        defer { harness.tearDown() }

        let first = "state=working:app=claude-code"
        let second = "state=blocked:app=claude-code:kind=permission"
        await harness.reader.feedChildOutputForTesting(
            Data("\(Self.esc)]7501;\(first)\(Self.bel)text\(Self.esc)]7501;\(second)\(Self.esc)\\".utf8))

        #expect(harness.delivered == [Array(first.utf8), Array(second.utf8)])
    }

    // MARK: - Preamble (replay)

    @Test func preambleNeitherAnswersNorDelivers() async throws {
        let harness = try Harness(enabled: true)
        defer { harness.tearDown() }

        await harness.reader.ingest(preamble: Data(
            "\(Self.probeBEL)\(Self.esc)]7501;\(Self.reportPayload)\(Self.bel)hello".utf8))

        #expect(harness.readReplies().isEmpty)
        #expect(harness.delivered.isEmpty)

        // And the silence ends with the preamble: the child's next probe is
        // answered.
        await harness.reader.feedChildOutputForTesting(Data(Self.probeBEL.utf8))
        #expect(harness.readReplies() == Array(ProgramStatusProtocol.probeReply.utf8))
    }

    // MARK: - Harness

    /// What the tap's `deliver` received, in order. `deliver` runs inside the
    /// parse on the feeding thread, so the box is lock-guarded like the real
    /// store's inbox is thread-safe.
    private final class DeliveryBox: @unchecked Sendable {
        private let lock = NSLock()
        private var payloads: [[UInt8]] = []

        func append(_ payload: [UInt8]) {
            lock.lock()
            defer { lock.unlock() }
            payloads.append(payload)
        }

        var all: [[UInt8]] {
            lock.lock()
            defer { lock.unlock() }
            return payloads
        }
    }

    /// A `HolderReader` over one end of a socketpair, never started, with a
    /// program-status tap whose `deliver` records into a box.
    private struct Harness {
        let reader: HolderReader
        let gate: ProgramStatusGate
        private let box: DeliveryBox
        private let ours: Int32

        init(enabled: Bool = true, tap: Bool = true) throws {
            var pair: [Int32] = [-1, -1]
            try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
            ours = pair[1]
            let flags = fcntl(ours, F_GETFL, 0)
            _ = fcntl(ours, F_SETFL, flags | O_NONBLOCK)
            let gate = ProgramStatusGate(enabled: enabled)
            let box = DeliveryBox()
            self.gate = gate
            self.box = box
            let programStatus: HolderProgramStatusTap? = tap
                ? HolderProgramStatusTap(gate: gate, deliver: { payload in box.append(payload) })
                : nil
            // The reader owns `pair[0]` and closes it in its `deinit`.
            reader = HolderReader(
                sessionID: UUID(),
                ptyFD: pair[0],
                columns: 80,
                rows: 24,
                scrollbackLines: 200,
                programStatus: programStatus,
                observedChildFromStart: true)
        }

        var delivered: [[UInt8]] { box.all }

        /// Everything the emulator has written back to the "child" so far. The
        /// replies are written synchronously inside the feed, so they are
        /// already queued when the feed returns; a non-blocking read drains
        /// them, and `EAGAIN` means there are none.
        func readReplies() -> [UInt8] {
            var out: [UInt8] = []
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = buffer.withUnsafeMutableBytes { raw in
                    Darwin.read(ours, raw.baseAddress, raw.count)
                }
                if count > 0 {
                    out.append(contentsOf: buffer[0..<count])
                    continue
                }
                return out
            }
        }

        /// Closes this side only. The reader's own end is closed by its
        /// `deinit`, which is safe because the reader is `.idle`: no thread was
        /// ever started, so none can be inside a read on it.
        func tearDown() {
            close(ours)
        }
    }
}
