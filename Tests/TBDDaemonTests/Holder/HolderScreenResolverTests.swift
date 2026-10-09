import Clocks
import Foundation
import TBDShared
import Testing

@testable import TBDDaemonLib
import TestSupport

/// The screen contract's three answers, each constructible, plus the two rules
/// a reader is most likely to get wrong.
///
/// The headline property is that **which store answered is decided from the
/// census ledger and nowhere else**, and that the detached case sends no frame
/// at all — the half that keeps a thousand-session fleet free of this path's
/// existence. The two easily-mistaken rules are the honest re-read on a failed
/// pull (a viewer that detached mid-pull leaves a *live* reader, not a stale
/// one) and the provenance on a viewer answer coming from the daemon's reader
/// rather than from the reply.
///
/// Every bound runs on a `TestClock`, so nothing sleeps.
@Suite("HolderScreenResolver", .clockDriven, .serialized)
struct HolderScreenResolverTests {

    // MARK: - Harness

    /// The two things the resolver asks about, plus a send-counting sidecar.
    ///
    /// Doubles rather than a real registry on purpose: reaching `.viewer`
    /// through a real one needs a real holder, a real pty and a real attach for
    /// what is a pure question about which store gets asked.
    private final class Harness: @unchecked Sendable {
        private let lock = NSLock()
        private var sentFrames: [Data] = []

        /// What the census says is reading. `nil` is "nobody".
        var role: PtyReaderRole?
        /// The daemon reader's own answer, or nil for "no published reader".
        var daemonScreen: TerminalScreen?
        /// What the reader answers on the *second* ask, when a test wants the
        /// honest re-read to differ from the first.
        var daemonScreenAfterPull: TerminalScreen?
        /// The reader's construction fact.
        var observedChildFromStart = true
        /// When set, the reader's screen throws it — a projection bug.
        var screenError: Error?

        var frames: [Data] { lock.withLock { sentFrames } }
        var sendCount: Int { lock.withLock { sentFrames.count } }

        func makePull(clock: any Clock<Duration>) -> HolderScreenPull {
            HolderScreenPull(
                sendFrame: { [self] frame in
                    lock.withLock { sentFrames.append(frame) }
                    return 1
                },
                clock: clock)
        }

        func makeResolver(pull: HolderScreenPull?) -> HolderScreenResolver {
            HolderScreenResolver(
                ptyReader: { [self] _ in role },
                daemonStore: { [self] _ in
                    guard daemonScreen != nil else { return nil }
                    return HolderDaemonStore(
                        screen: { [self] _ in
                            if let screenError { throw screenError }
                            // Keyed on a frame having gone out, not on a call
                            // count: the resolver asks the reader exactly once
                            // on the fallback, so "after the pull" is "after
                            // the request was sent" and nothing else.
                            let afterPull = lock.withLock { !sentFrames.isEmpty }
                            if afterPull, let after = daemonScreenAfterPull { return after }
                            guard let screen = daemonScreen else { throw NoPublishedReader() }
                            return screen
                        },
                        observedChildFromStart: observedChildFromStart)
                },
                pull: pull,
                retainedScrollbackLines: 5_000)
        }

        /// The request the resolver put on the wire, parsed back off it.
        func decodeRequest() throws -> SidecarScreenRequest {
            let scanner = SidecarFrameScanner()
            let parsed = scanner.append(try #require(frames.first))
            let frame = try #require(parsed.first)
            #expect(SidecarFrameType(rawValue: frame.type) == .screenRequest)
            return try SidecarFrameCodec.decodeScreenRequest(payload: frame.payload)
        }
    }

    /// Unreachable in these tests — the store is only built when a screen is
    /// set — and named rather than left as a stray `CancellationError` so a
    /// failure that somehow reached it would say what it was.
    private struct NoPublishedReader: Error {}

    private static func screen(
        lines: [String], source: TerminalScreen.Source, age: Int = 0, observed: Bool = true
    ) throws -> TerminalScreen {
        try TerminalScreen(
            lines: lines, viewportStart: 0,
            cursor: TerminalScreen.Cursor(row: 0, column: 0, visible: true),
            size: TerminalScreen.Size(columns: 80, rows: 24),
            modes: TerminalScreen.ChildModes(
                bracketedPaste: false, applicationCursor: false, alternateScreen: false),
            modesObserved: observed, contentObserved: observed,
            source: source, ageMilliseconds: age)
    }

    private static func payload(
        lines: [String], age: Int = 7, bracketedPaste: Bool = true
    ) -> ViewerScreenPayload {
        ViewerScreenPayload(
            lines: lines, viewportStart: 0, cursorRow: 2, cursorColumn: 5,
            cursorVisible: true, cursorVisibleObserved: false,
            columns: 80, rows: 24,
            bracketedPaste: bracketedPaste, applicationCursor: false, alternateScreen: false,
            ageMilliseconds: age)
    }

    // MARK: - The three answers

    /// The ordinary fleet case, and the assertion that matters most here is the
    /// **negative** one: no frame is sent. A resolver that pulled for every
    /// read would work, and would put a sidecar round trip on every one of a
    /// thousand detached sessions.
    @Test("a detached session answers from the daemon's reader and sends no frame")
    func detachedSessionAnswersFromTheReaderWithNoFrame() async throws {
        let harness = Harness()
        harness.role = .daemon
        harness.daemonScreen = try Self.screen(lines: ["live"], source: .daemon)
        let pull = harness.makePull(clock: TestClock())
        let resolver = harness.makeResolver(pull: pull)

        let screen = try await resolver.screen(terminalID: UUID(), maxLines: 50)

        #expect(screen?.source == .daemon)
        #expect(screen?.lines == ["live"])
        #expect(harness.sendCount == 0, "a detached session must not go near the app")
    }

    @Test("an attached session whose viewer answers reports source viewer")
    func attachedSessionAnswersFromTheViewer() async throws {
        let harness = Harness()
        harness.role = .viewer(attach: 3)
        harness.daemonScreen = try Self.screen(lines: ["frozen"], source: .staleDaemon, age: 90_000)
        let pull = harness.makePull(clock: TestClock())
        let resolver = harness.makeResolver(pull: pull)
        let terminalID = UUID()

        let answer = Task { try await resolver.screen(terminalID: terminalID, maxLines: 50) }
        try await waitFor("the screen request to reach the sidecar") { harness.sendCount == 1 }

        let request = try harness.decodeRequest()
        #expect(request.terminalID == terminalID)
        pull.record(
            SidecarScreenReply(
                requestID: request.requestID, terminalID: terminalID,
                screen: Self.payload(lines: ["what the person sees"])),
            epoch: 1)

        let screen = try #require(try await answer.value)
        #expect(screen.source == .viewer)
        #expect(screen.lines == ["what the person sees"], "the viewer's lines, not the emulator's")
        #expect(screen.ageMilliseconds == 7, "the viewer's forwarded interval, not the reader's")
        #expect(screen.cursor.row == 2)
        #expect(screen.modes.bracketedPaste)
    }

    /// The alive-but-silent arm, which is the branch every consumer's policy
    /// was already written against. Driven to exactly the bound on virtual
    /// time, so nothing waits.
    @Test("an attached session whose viewer stays silent falls back after the bound")
    func silentViewerFallsBackToTheFrozenEmulator() async throws {
        let harness = Harness()
        harness.role = .viewer(attach: 3)
        harness.daemonScreen = try Self.screen(
            lines: ["as it stood at attach"], source: .staleDaemon, age: 90_000)
        let clock = TestClock<Duration>()
        let pull = harness.makePull(clock: clock)
        let resolver = harness.makeResolver(pull: pull)

        let answer = Task { try await resolver.screen(terminalID: UUID(), maxLines: 50) }
        try await waitFor("the screen request to reach the sidecar") { harness.sendCount == 1 }

        await clock.advanceWhenSuspended(by: HolderInputTiming.screenPullBound)

        let screen = try #require(try await answer.value)
        #expect(screen.source == .staleDaemon)
        #expect(screen.lines == ["as it stood at attach"])
        #expect(screen.ageMilliseconds == 90_000,
                "the age is the emulator's last byte, which is at or before the attach")
    }

    @Test("no published reader answers nil, so the caller can say which")
    func noReaderAnswersNil() async throws {
        let harness = Harness()
        harness.role = nil
        harness.daemonScreen = nil
        let resolver = harness.makeResolver(pull: harness.makePull(clock: TestClock()))

        #expect(try await resolver.screen(terminalID: UUID(), maxLines: 50) == nil)
        #expect(harness.sendCount == 0)
    }

    /// Nobody reading, but a reader published: a suspended emulator is still
    /// the best answer there is, and the reader is what calls it stale.
    @Test("a published reader nobody is reading from still answers")
    func publishedButUnreadSessionAnswersFromTheReader() async throws {
        let harness = Harness()
        harness.role = nil
        harness.daemonScreen = try Self.screen(lines: ["suspended"], source: .staleDaemon)
        let resolver = harness.makeResolver(pull: harness.makePull(clock: TestClock()))

        let screen = try await resolver.screen(terminalID: UUID(), maxLines: 50)

        #expect(screen?.source == .staleDaemon)
        #expect(harness.sendCount == 0, "nobody holds the pty, so there is nobody to ask")
    }

    // MARK: - The two rules a reader gets wrong

    /// The honest re-read. A viewer that detached while the pull was in flight
    /// has left the daemon draining again, and calling that `staleDaemon`
    /// would make the hibernation rail refuse a park it could safely take.
    ///
    /// Discriminating by construction: the reader answers `staleDaemon` the
    /// first time and `daemon` the second, so a resolver that cached the first
    /// answer or hard-coded the fallback's source fails.
    @Test("a pull that fails after the viewer detached answers daemon, not staleDaemon")
    func failedPullReReadsTheReaderHonestly() async throws {
        let harness = Harness()
        harness.role = .viewer(attach: 3)
        harness.daemonScreen = try Self.screen(lines: ["at attach"], source: .staleDaemon)
        harness.daemonScreenAfterPull = try Self.screen(
            lines: ["draining again"], source: .daemon)
        let pull = harness.makePull(clock: TestClock())
        let resolver = harness.makeResolver(pull: pull)
        let terminalID = UUID()

        let answer = Task { try await resolver.screen(terminalID: terminalID, maxLines: 50) }
        try await waitFor("the screen request to reach the sidecar") { harness.sendCount == 1 }

        let request = try harness.decodeRequest()
        pull.record(
            SidecarScreenReply(
                requestID: request.requestID, terminalID: terminalID, unavailable: .noPanel),
            epoch: 1)

        let screen = try #require(try await answer.value)
        #expect(screen.source == .daemon,
                "the reader resumed, and labelling a live emulator stale refuses a safe park")
        #expect(screen.lines == ["draining again"])
    }

    /// The provenance rule, in the case that makes it matter: a re-adopted
    /// session's reader says `false`, and a viewer answering for it earns no
    /// provenance the daemon never had. "The app answered, so the screen must
    /// be observed" is the plausible wrong reading.
    @Test("a viewer answer takes its provenance from the reader, not the reply")
    func viewerAnswerTakesProvenanceFromTheReader() async throws {
        let harness = Harness()
        harness.role = .viewer(attach: 3)
        harness.observedChildFromStart = false
        harness.daemonScreen = try Self.screen(
            lines: ["inherited"], source: .staleDaemon, observed: false)
        let pull = harness.makePull(clock: TestClock())
        let resolver = harness.makeResolver(pull: pull)
        let terminalID = UUID()

        let answer = Task { try await resolver.screen(terminalID: terminalID, maxLines: 50) }
        try await waitFor("the screen request to reach the sidecar") { harness.sendCount == 1 }
        let request = try harness.decodeRequest()
        pull.record(
            SidecarScreenReply(
                requestID: request.requestID, terminalID: terminalID,
                screen: Self.payload(lines: ["live from the viewer"])),
            epoch: 1)

        let screen = try #require(try await answer.value)
        #expect(screen.source == .viewer)
        #expect(!screen.modesObserved, "a re-adopted emulator's provenance survives the pull")
        #expect(!screen.contentObserved)
    }

    /// The other direction, so the test above cannot pass by returning a
    /// constant: a session the daemon spawned answers true on both axes.
    @Test("a viewer answer for a daemon-spawned session reports observed")
    func viewerAnswerForASpawnedSessionReportsObserved() async throws {
        let harness = Harness()
        harness.role = .viewer(attach: 3)
        harness.observedChildFromStart = true
        harness.daemonScreen = try Self.screen(lines: ["at attach"], source: .staleDaemon)
        let pull = harness.makePull(clock: TestClock())
        let resolver = harness.makeResolver(pull: pull)
        let terminalID = UUID()

        let answer = Task { try await resolver.screen(terminalID: terminalID, maxLines: 50) }
        try await waitFor("the screen request to reach the sidecar") { harness.sendCount == 1 }
        let request = try harness.decodeRequest()
        pull.record(
            SidecarScreenReply(
                requestID: request.requestID, terminalID: terminalID,
                screen: Self.payload(lines: ["live"])),
            epoch: 1)

        let screen = try #require(try await answer.value)
        #expect(screen.modesObserved)
        #expect(screen.contentObserved)
    }

    // MARK: - The depth, and a broken projection

    /// The cap is the daemon's, so `--lines N` means the same thing whoever is
    /// looking. Asserted on the frame, which is where it is enforced.
    @Test("a requested depth past the daemon's retained depth goes out clamped")
    func requestedDepthIsClamped() async throws {
        let harness = Harness()
        harness.role = .viewer(attach: 3)
        harness.daemonScreen = try Self.screen(lines: ["at attach"], source: .staleDaemon)
        let clock = TestClock<Duration>()
        let pull = harness.makePull(clock: clock)
        let resolver = harness.makeResolver(pull: pull)

        let answer = Task { try await resolver.screen(terminalID: UUID(), maxLines: 100_000) }
        try await waitFor("the screen request to reach the sidecar") { harness.sendCount == 1 }

        #expect(try harness.decodeRequest().lines == 5_000)

        await clock.advanceWhenSuspended(by: HolderInputTiming.screenPullBound)
        _ = try await answer.value
    }

    /// A payload carrying a control character is a projection bug on the app's
    /// side, and it surfaces as the screen type's error naming the offending
    /// line — which the handler turns into "Could not project terminal …" —
    /// rather than as a silent empty answer.
    @Test("a payload with a control character throws, naming the line")
    func controlCharacterInAPayloadThrows() async throws {
        let harness = Harness()
        harness.role = .viewer(attach: 3)
        harness.daemonScreen = try Self.screen(lines: ["at attach"], source: .staleDaemon)
        let pull = harness.makePull(clock: TestClock())
        let resolver = harness.makeResolver(pull: pull)
        let terminalID = UUID()

        let answer = Task { try await resolver.screen(terminalID: terminalID, maxLines: 50) }
        try await waitFor("the screen request to reach the sidecar") { harness.sendCount == 1 }
        let request = try harness.decodeRequest()
        pull.record(
            SidecarScreenReply(
                requestID: request.requestID, terminalID: terminalID,
                screen: Self.payload(lines: ["fine", "bad\u{7}line"])),
            epoch: 1)

        await #expect(throws: TerminalScreen.ValidationError.self) {
            _ = try await answer.value
        }
    }

    /// A daemon with no pull wired — the tmux-only configuration — resolves
    /// straight from the reader even for an attached session, which is what it
    /// did before the pull existed.
    @Test("a resolver with no pull answers from the reader")
    func noPullResolvesFromTheReader() async throws {
        let harness = Harness()
        harness.role = .viewer(attach: 3)
        harness.daemonScreen = try Self.screen(lines: ["at attach"], source: .staleDaemon)
        let resolver = harness.makeResolver(pull: nil)

        let screen = try await resolver.screen(terminalID: UUID(), maxLines: 50)

        #expect(screen?.source == .staleDaemon)
        #expect(harness.sendCount == 0)
    }
}
