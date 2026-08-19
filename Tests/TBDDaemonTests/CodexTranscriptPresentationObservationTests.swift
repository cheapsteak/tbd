import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

@Suite("Codex transcript presentation observations")
struct CodexPresentationObservationTests {
    @Test("presentation stamps are minted in tracker observation order")
    func presentationStampsFollowTrackerOrder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-presentation-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("rollout.jsonl")
        try Data(
            (#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"a"}}"# + "\n").utf8
        ).write(to: transcript)

        let firstAt = Date(timeIntervalSince1970: 1_700_000_000)
        let secondAt = firstAt.addingTimeInterval(1)
        let dates = BlockingPresentationDates(first: firstAt, subsequent: secondAt)
        let tracker = CodexTranscriptActivityTracker()
        let targets = [CodexTranscriptActivityTracker.Target(
            transcriptPath: transcript.path,
            worktreeID: UUID()
        )]

        let first = Task {
            await tracker.observeStamped(transcripts: targets, now: dates.provider)
        }
        guard await waitUntil({ dates.firstCallIsBlocked }) else {
            dates.releaseFirstCall()
            _ = await first.value
            Issue.record("first observation never reached its actor stamp")
            return
        }

        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(
            (#"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"a"}}"# + "\n").utf8
        ))
        try handle.close()
        let second = Task {
            await tracker.observeStamped(transcripts: targets, now: dates.provider)
        }

        dates.releaseFirstCall()
        let firstObservation = await first.value
        let secondObservation = await second.value

        #expect(firstObservation.states[transcript.path] == .working)
        #expect(firstObservation.observedAt == firstAt)
        #expect(secondObservation.states[transcript.path] == .idle)
        #expect(secondObservation.observedAt == secondAt)
    }
}

private final class BlockingPresentationDates: @unchecked Sendable {
    private let lock = NSLock()
    private let first: Date
    private let subsequent: Date
    private let release = DispatchSemaphore(value: 0)
    private var callCount = 0
    private var firstBlocked = false

    init(first: Date, subsequent: Date) {
        self.first = first
        self.subsequent = subsequent
    }

    var firstCallIsBlocked: Bool {
        lock.withLock { firstBlocked }
    }

    var provider: @Sendable () -> Date {
        { [self] in
            let call = lock.withLock { () -> Int in
                let call = callCount
                callCount += 1
                if call == 0 { firstBlocked = true }
                return call
            }
            guard call == 0 else { return subsequent }
            release.wait()
            return first
        }
    }

    func releaseFirstCall() {
        release.signal()
    }
}
