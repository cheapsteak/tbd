// The states the handover suites run beside the corpus, each state's bytes and preamble built
// once per process, and the threads the suites run their bodies on.
import Foundation
import Synchronization
import TestSupport
import Testing

/// States a review of the handback named, each one a sequence the formatter's order broke for a
/// SwiftTerm receiver. They are kept apart from the proof of concept's corpus, whose counts are
/// pinned.
enum HandoverReviewStates {
    private static let e = "\u{1b}"

    /// Numbered, coloured lines, for a primary screen with something on it.
    private static func lines(_ count: Int) -> String {
        (0..<count).map { "\(e)[3\($0 % 8)mreview line \($0)\(e)[0m\r\n" }.joined()
    }

    static let states: [HandoverState] = {
        let cases: [(String, String)] = [
            // Soft-wrapped rows in scrollback and one on the screen, then `tput rmam`.
            ("wrapped-history-then-nowrap",
             (0..<40).map { "\($0) " + String(repeating: "w", count: 150) + "\r\n" }.joined()
                + String(repeating: "v", count: 120) + "\(e)[?7l"),
            // A full-screen program that turns autowrap off on the alternate screen.
            ("alt-tui-nowrap",
             lines(30) + "\(e)[?1049h\(e)[2J\(e)[1;1H status\(e)[?7l\(e)[24;1H" + String(repeating: "-", count: 90)
                + "\(e)[5;5H"),
            // crossterm's EnableMouseCapture: three tracking modes, urxvt's encoding, then SGR's.
            ("mouse-crossterm", "\(e)[?1000h\(e)[?1002h\(e)[?1003h\(e)[?1015h\(e)[?1006h"),
            // The legacy alternate screens, which save no cursor, with the cursor away from home
            // on both screens.
            ("alt-47-cursor-moved", lines(5) + "\(e)[3;10Hprimary\(e)[?47h\(e)[2J\(e)[12;30Halt"),
            ("alt-1047-cursor-moved", lines(5) + "\(e)[3;10Hprimary\(e)[?1047h\(e)[2J\(e)[12;30Halt"),
        ]
        return cases.map {
            HandoverState(
                name: $0.0, bytes: Array($0.1.utf8), cols: HandoverCorpus.scenarioCols, rows: HandoverCorpus.scenarioRows)
        }
    }()
}

/// Each state's bytes and the daemon's preamble for it, built the first time a test asks and
/// shared after that. Both are immutable, so the suites and their cases can share them.
enum HandoverFixtures {
    /// Every state the crossings run: the corpus's, then the review's.
    static let names: [String] = HandoverCorpus.names + HandoverReviewStates.states.map(\.name)

    private static let reviewStates: [String: HandoverState] = Dictionary(
        uniqueKeysWithValues: HandoverReviewStates.states.map { ($0.name, $0) })
    private static let states = Mutex<[String: HandoverState]>([:])
    private static let preambles = Mutex<[String: [UInt8]]>([:])

    /// The state's bytes. A workload state's are cut from its workload once.
    static func state(named name: String) -> HandoverState {
        if let review = reviewStates[name] { return review }
        if let cached = states.withLock({ $0[name] }) { return cached }
        let state = HandoverCorpus.state(named: name)
        states.withLock { $0[name] = state }
        return state
    }

    /// What the daemon writes a viewer that attaches to the state: TBD's handover writer, run on a
    /// SwiftTerm emulator that read the state's bytes.
    static func preamble(named name: String) -> [UInt8] {
        if let cached = preambles.withLock({ $0[name] }) { return cached }
        let preamble = state(named: name).swiftTerm().writerBytes()
        preambles.withLock { $0[name] = preamble }
        return preamble
    }
}

/// Runs `body` on a thread the tests own, not on the cooperative pool. The handover suites feed
/// and walk workloads of a megabyte and 5,000 rows of scrollback without suspending, and on CI's
/// three-thread pool that holds up every suite waiting on it (`Tests/CLAUDE.md`, "A stall is a
/// spell of 1–20 s"). A preference for `GateExecutor` moves this nonisolated operation onto one
/// of its threads, and `body` never suspends, so it runs start to finish there. Its assertions
/// still belong to the test: it is the same task.
///
/// The thread is checked by name first, so a preference that stopped reaching the body fails
/// here instead of quietly putting the work back on the pool. The suites are `.serialized`
/// because `GateExecutor` starts a thread for every job: in parallel, every case would get one.
func onHandoverThread(_ body: () throws -> Void) async throws {
    try await withTaskExecutorPreference(GateExecutor.shared) {
        #expect(handoverThreadName() == GateExecutor.threadName)
        try body()
    }
}

/// Which thread runs this code. Synchronous on purpose: `Thread.current` is unavailable from an
/// async context, because the answer can change across a suspension point.
private func handoverThreadName() -> String? {
    Thread.current.name
}
