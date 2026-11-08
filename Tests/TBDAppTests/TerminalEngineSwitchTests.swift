import AppKit
import Clocks
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import TBDApp
import TBDGhosttyTerminal
import TBDShared
import TestSupport

/// Switch Terminal Engine and the tab's engine label.
///
/// A switch hands a holder session back through the panel's own detach, waits
/// for the detach to return, and records the other engine in
/// `AppState.terminalEngineOverrides`; the changed identity rebuilds the panel
/// on that engine, which attaches as any new panel does. The panel tests drive
/// the coordinator the way `makeNSView` and `dismantleNSView` do, through the
/// same `registerEngineRecords` / `unregisterEngineRecords`, against a stub
/// daemon that vends one socketpair per attach and hands the second attach the
/// screen the first detach carried. Every store is an isolated suite.
@MainActor
@Suite("Switch Terminal Engine", .fastPassBounded)
struct TerminalEngineSwitchTests {

    // MARK: - The switch

    @Test("A switch hands the session back with its screen, then the rebuilt panel attaches on the other engine and shows that screen",
          .enabled(if: EngineTestSupport.canBuildGhostty, EngineTestSupport.noMetalDevice),
          arguments: TerminalEngineKind.allCases)
    func switchDetachesWithHandbackThenAttachesTheOtherEngine(from start: TerminalEngineKind) async throws {
        let fixture = SwitchFixture(label: "Handback.\(start.rawValue)", flag: true)
        defer { fixture.tearDown() }
        fixture.state.terminalEngineOverrides[fixture.terminalID] = start
        let first = fixture.makePanel()
        try #require(first.engine.kind == start, "the first panel was built on \(first.engine.kind), not \(start)")
        await first.coordinator.startHolderClient(engine: first.engine)
        try #require(fixture.daemon.events == ["attach", "ready"], "the first panel did not attach: \(fixture.daemon.events)")

        fixture.sessionWrites("BEFORE-THE-SWITCH\r\n", on: 0)
        let firstEngine = first.engine
        let painted = await EngineTestSupport.waitUntil(
            "the session's output to paint on \(start)",
            observed: { Self.screenText(firstEngine) }
        ) { Self.screenText(firstEngine).contains("BEFORE-THE-SWITCH") }
        try #require(painted)
        let identityBefore = fixture.identity

        await fixture.state.switchTerminalEngine(terminalID: fixture.terminalID)

        #expect(fixture.daemon.events == ["attach", "ready", "detach"],
                "the switch did not send exactly one detach: \(fixture.daemon.events)")
        let handedBack = try #require(fixture.daemon.detachPreambles.first)
        #expect(!handedBack.isEmpty, "the switch's detach carried no screen")
        #expect(fixture.ptys[0].isClosedAfterDraining,
                "the switch told the daemon it detached while this app was still on the descriptor")
        #expect(fixture.state.terminalEngineOverrides[fixture.terminalID] == start.other)
        #expect(fixture.identity != identityBefore,
                "the switch left the panel's identity alone, so SwiftUI would not rebuild it")

        // What SwiftUI does once the identity changes: the old panel goes and
        // a new one is made, asking AppState which engine to build.
        fixture.dismantle(first)
        let second = fixture.makePanel()
        #expect(second.engine.kind == start.other, "the rebuilt panel was built on \(second.engine.kind)")
        await second.coordinator.startHolderClient(engine: second.engine)
        #expect(fixture.daemon.events == ["attach", "ready", "detach", "attach", "ready"],
                "the rebuilt panel did not attach once, after the detach: \(fixture.daemon.events)")
        let secondEngine = second.engine
        await EngineTestSupport.waitUntil(
            "the handed-back screen to paint on \(start.other)",
            observed: { Self.screenText(secondEngine) }
        ) { Self.screenText(secondEngine).contains("BEFORE-THE-SWITCH") }

        await EngineTestSupport.mainQueueTurn()
        #expect(fixture.state.terminalEngineKindInUse(for: fixture.terminalID) == start.other,
                "the tab's label would still name the engine the panel left")
    }

    @Test("The override is kept across panel rebuilds, a fresh AppState has none, and it goes with the terminal")
    func overrideSurvivesRebuildAndIsGoneAfterRelaunch() async {
        let fixture = SwitchFixture(label: "Relaunch", flag: true)
        defer { fixture.tearDown() }
        let base = TerminalPanePresentation.attachIdentity(
            for: fixture.row, attachEpoch: 0, attachRetry: 0, engineOverride: nil)
        #expect(base == "\(fixture.terminalID)-\(fixture.row.tmuxWindowID)-0-0",
                "an override of nil changed the identity of a terminal nobody switched")

        // On SwiftTerm as if switched there before; never attached, so the
        // switch has nothing to hand back and only records the engine.
        fixture.state.terminalEngineOverrides[fixture.terminalID] = .swiftTerm
        let first = fixture.makePanel()
        #expect(first.engine.kind == .swiftTerm)
        await fixture.state.switchTerminalEngine(terminalID: fixture.terminalID)
        #expect(fixture.daemon.events.isEmpty, "a panel with no attach sent \(fixture.daemon.events)")
        #expect(fixture.state.terminalEngineOverrides[fixture.terminalID] == .ghostty)
        let switched = fixture.identity
        #expect(switched == "\(base)-engine-ghostty")

        // Two rebuilds, as a layout change makes: the override holds, and so
        // does the identity, which would otherwise rebuild the panel again.
        fixture.dismantle(first)
        let second = fixture.makePanel()
        #expect(fixture.state.terminalEngineKind(for: fixture.terminalID) == .ghostty)
        fixture.dismantle(second)
        _ = fixture.makePanel()
        #expect(fixture.state.terminalEngineOverrides[fixture.terminalID] == .ghostty, "a rebuild dropped the override")
        #expect(fixture.identity == switched, "a rebuild moved the identity")

        // A relaunch: a fresh AppState over the same store.
        let relaunched = AppState(userDefaults: fixture.suite.defaults)
        relaunched.terminals[fixture.worktreeID] = [fixture.row]
        #expect(relaunched.terminalEngineOverrides.isEmpty, "an override outlived the app")
        #expect(TerminalPanePresentation.attachIdentity(
            for: fixture.row, attachEpoch: 0, attachRetry: 0,
            engineOverride: relaunched.terminalEngineOverrides[fixture.terminalID]) == base)
        #expect(relaunched.terminalEngineKind(for: fixture.terminalID)
                == TerminalEngineFactory.requestedKind(flagEnabled: true, host: .panel(.holder)))

        fixture.state.recordTerminalRemoval(terminalID: fixture.terminalID)
        #expect(fixture.state.terminalEngineOverrides[fixture.terminalID] == nil,
                "a removed terminal's override was kept")
    }

    // MARK: - The command

    @Test("The command is hidden while the experiment is off, and a switch that reaches a panel then does nothing")
    func switchCommandHiddenWhenExperimentOff() async {
        #expect(!TerminalEngineSwitchCommand.isVisible(experimentEnabled: false))
        #expect(TerminalEngineSwitchCommand.isVisible(experimentEnabled: true))
        // As the menu reads the stored flag: unset and false hide it.
        #expect(!TerminalEngineSwitchCommand.isVisible(
            experimentEnabled: AppState.ghosttyTerminalEngineEnabled(stored: nil)))
        #expect(!TerminalEngineSwitchCommand.isVisible(
            experimentEnabled: AppState.ghosttyTerminalEngineEnabled(stored: false)))
        #expect(TerminalEngineSwitchCommand.isVisible(
            experimentEnabled: AppState.ghosttyTerminalEngineEnabled(stored: true)))
        #expect(!TerminalEngineSwitchCommand.isEnabled(experimentEnabled: false, focusedHost: .panel(.holder)))

        // Both branches of the panel's own check, on a live holder attach:
        // unset and false switch nothing, and the control below, flag on,
        // does switch.
        for flag in [nil, false] as [Bool?] {
            let name = flag.map { "\($0)" } ?? "unset"
            let fixture = SwitchFixture(label: "Hidden.\(name)", flag: flag)
            defer { fixture.tearDown() }
            let panel = fixture.makePanel()
            #expect(panel.engine.kind == .swiftTerm)
            await panel.coordinator.startHolderClient(engine: panel.engine)
            let identity = fixture.identity
            await fixture.state.switchTerminalEngine(terminalID: fixture.terminalID)
            #expect(fixture.daemon.events == ["attach", "ready"],
                    "a switch with the flag \(name) touched the session: \(fixture.daemon.events)")
            #expect(fixture.state.terminalEngineOverrides[fixture.terminalID] == nil)
            #expect(fixture.identity == identity, "a switch with the flag \(name) would rebuild the panel")
        }

        // The control: flag on, a holder panel on SwiftTerm switches.
        let fixture = SwitchFixture(label: "Hidden.control", flag: true)
        defer { fixture.tearDown() }
        fixture.state.terminalEngineOverrides[fixture.terminalID] = .swiftTerm
        let panel = fixture.makePanel()
        await panel.coordinator.startHolderClient(engine: panel.engine)
        await fixture.state.switchTerminalEngine(terminalID: fixture.terminalID)
        #expect(fixture.daemon.events == ["attach", "ready", "detach"], "\(fixture.daemon.events)")
        #expect(fixture.state.terminalEngineOverrides[fixture.terminalID] == .ghostty)
    }

    @Test("The command is enabled for a focused holder panel only: not a tmux panel, a remote attach terminal, or a remote sign-in terminal")
    func switchCommandDisabledOnRemoteAndAuthTerminals() {
        withTestDefaults("TerminalEngineSwitch.Disabled") { defaults in
            defaults.set(true, forKey: AppState.useGhosttyTerminalEngineKey)
            let state = AppState(userDefaults: defaults)
            let appearance = AppearanceSettings(defaults: defaults)
            let worktreeID = UUID()
            let holderID = UUID()
            let tmuxID = UUID()
            state.terminals[worktreeID] = [
                Self.row(holderID, worktreeID: worktreeID, transport: .holder),
                Self.row(tmuxID, worktreeID: worktreeID, transport: .tmux),
            ]
            let holderView = Self.makeView(appearance)
            let tmuxView = Self.makeView(appearance)
            let remoteView = Self.makeView(appearance)
            // A remote sign-in terminal registers in neither registry.
            let signInView = Self.makeView(appearance)
            state.registerTerminalView(holderView, for: holderID)
            state.registerTerminalView(tmuxView, for: tmuxID)
            let selection = RemoteSessionSelection(provider: "acme", sessionID: "s-1")
            state.registerRemoteTerminalView(remoteView, for: selection)
            defer { state.unregisterRemoteTerminalView(remoteView, for: selection) }

            #expect(state.terminalEngineHost(ofFocusedView: holderView) == .panel(.holder))
            #expect(state.terminalEngineHost(ofFocusedView: tmuxView) == .panel(.tmux))
            #expect(state.terminalEngineHost(ofFocusedView: remoteView) == .localPTY)
            #expect(state.terminalEngineHost(ofFocusedView: signInView) == nil)

            let enabled = state.ghosttyTerminalEngineEnabled
            #expect(TerminalEngineSwitchCommand.isEnabled(
                experimentEnabled: enabled, focusedHost: state.terminalEngineHost(ofFocusedView: holderView)))
            #expect(!TerminalEngineSwitchCommand.isEnabled(
                experimentEnabled: enabled, focusedHost: state.terminalEngineHost(ofFocusedView: tmuxView)))
            #expect(!TerminalEngineSwitchCommand.isEnabled(
                experimentEnabled: enabled, focusedHost: state.terminalEngineHost(ofFocusedView: remoteView)),
                    "a remote attach terminal has no daemon session to hand back")
            #expect(!TerminalEngineSwitchCommand.isEnabled(
                experimentEnabled: enabled, focusedHost: state.terminalEngineHost(ofFocusedView: signInView)),
                    "a remote sign-in terminal has no daemon session to hand back")
            #expect(TerminalEngineSwitchCommand.title == "Switch Terminal Engine")
            #expect(TerminalEngineSwitchCommand.key == "e")
            #expect(TerminalEngineSwitchCommand.modifiers == [.command, .control])
        }
    }

    // MARK: - A failed start

    @Test("A libghostty start that fails during a switch lands on SwiftTerm, the session opens again, and another press does nothing")
    func failedEngineStartDuringSwitchLandsOnSwiftTerm() async throws {
        let fixture = SwitchFixture(label: "Fallback", flag: true)
        defer { fixture.tearDown() }
        fixture.state.terminalEngineOverrides[fixture.terminalID] = .swiftTerm
        let first = fixture.makePanel()
        await first.coordinator.startHolderClient(engine: first.engine)
        try #require(fixture.daemon.events == ["attach", "ready"], "\(fixture.daemon.events)")

        await fixture.state.switchTerminalEngine(terminalID: fixture.terminalID)
        #expect(fixture.daemon.events == ["attach", "ready", "detach"], "\(fixture.daemon.events)")
        #expect(fixture.state.terminalEngineOverrides[fixture.terminalID] == .ghostty)

        fixture.dismantle(first)
        let attempts = MakerAttemptLog()
        let second = fixture.makePanel(
            makeGhostty: { _, _, _ in
                attempts.count += 1
                throw GhosttyError.metalUnavailable
            },
            fallbacks: attempts)
        #expect(attempts.count == 1, "the libghostty maker ran \(attempts.count) times")
        #expect(attempts.fallbacks == [.ghostty])
        #expect(second.engine.kind == .swiftTerm)
        await second.coordinator.startHolderClient(engine: second.engine)
        #expect(fixture.daemon.events == ["attach", "ready", "detach", "attach", "ready"],
                "the session did not open again on SwiftTerm: \(fixture.daemon.events)")

        await EngineTestSupport.mainQueueTurn()
        #expect(fixture.state.terminalEngineKindInUse(for: fixture.terminalID) == .swiftTerm)
        #expect(TerminalEngineLabel.text(
            experimentEnabled: true,
            kind: fixture.state.terminalEngineKindInUse(for: fixture.terminalID)) == "SwiftTerm",
                "the label named the engine that was asked for, not the one the panel runs on")

        // Another press would ask for libghostty again, which did not start:
        // nothing would rebuild the panel, so nothing is handed back.
        let identity = fixture.identity
        await fixture.state.switchTerminalEngine(terminalID: fixture.terminalID)
        #expect(fixture.daemon.events.count == 5,
                "a switch to the engine that failed detached the session: \(fixture.daemon.events)")
        #expect(fixture.identity == identity)
        #expect(fixture.state.terminalEngineOverrides[fixture.terminalID] == .ghostty)
    }

    // MARK: - The label

    @Test("The label names the panel's engine while the experiment is on, hides while it is off, and follows the newest panel")
    func engineLabelNamesTheEngineAndHidesWhenOff() async {
        #expect(TerminalEngineLabel.text(experimentEnabled: true, kind: .ghostty) == "libghostty")
        #expect(TerminalEngineLabel.text(experimentEnabled: true, kind: .swiftTerm) == "SwiftTerm")
        #expect(TerminalEngineLabel.text(experimentEnabled: true, kind: nil) == nil, "a label for an unmounted terminal")
        for kind in TerminalEngineKind.allCases {
            #expect(TerminalEngineLabel.text(experimentEnabled: false, kind: kind) == nil,
                    "a \(kind) label with the experiment off")
            #expect(TerminalEngineLabel.text(
                experimentEnabled: AppState.ghosttyTerminalEngineEnabled(stored: nil), kind: kind) == nil,
                    "a \(kind) label with the flag unset")
        }

        // The record behind it, through the panel's own entry points. A
        // successor made before its predecessor is dismantled keeps its entry
        // whichever order the two run in.
        let fixture = SwitchFixture(label: "Label", flag: true)
        defer { fixture.tearDown() }
        fixture.state.terminalEngineOverrides[fixture.terminalID] = .swiftTerm
        let first = fixture.makePanel()
        #expect(fixture.state.terminalEngineKindInUse(for: fixture.terminalID) == nil,
                "the record was written inside the view update")
        await EngineTestSupport.mainQueueTurn()
        #expect(fixture.state.terminalEngineKindInUse(for: fixture.terminalID) == .swiftTerm)

        let second = fixture.makePanel()
        fixture.dismantle(first)
        await EngineTestSupport.mainQueueTurn()
        #expect(fixture.state.terminalEngineKindInUse(for: fixture.terminalID) == .swiftTerm,
                "a predecessor's teardown erased its successor's record")
        #expect(fixture.state.terminalEngineSwitchers[fixture.terminalID]?.owner
                == second.coordinator.engineSwitchToken,
                "a predecessor's teardown unregistered its successor's switch")

        fixture.dismantle(second)
        await EngineTestSupport.mainQueueTurn()
        #expect(fixture.state.terminalEngineKindInUse(for: fixture.terminalID) == nil,
                "a dismantled panel's engine is still named")
        #expect(fixture.state.terminalEngineSwitchers[fixture.terminalID] == nil)
    }

    // MARK: - Helpers

    /// Every visible row of `engine`'s screen. The size is read first: the
    /// libghostty engine reads it under the lock `withScreen` holds.
    static func screenText(_ engine: any TerminalEngine) -> String {
        let rows = engine.gridSize.rows
        return engine.withScreen { screen in
            (0..<rows).compactMap { screen.lineText(row: $0) }.joined(separator: "\n")
        }
    }

    nonisolated static func row(
        _ id: UUID, worktreeID: UUID, transport: TerminalTransport
    ) -> TBDShared.Terminal {
        TBDShared.Terminal(
            id: id, worktreeID: worktreeID, tmuxWindowID: "", tmuxPaneID: "",
            label: "Shell", kind: .shell, transport: transport)
    }

    static func makeView(_ appearance: AppearanceSettings) -> TBDTerminalView {
        TBDTerminalView(
            frame: CGRect(x: 0, y: 0, width: 600, height: 300),
            font: TBDTerminalView.defaultMonospaceFont,
            appearance: appearance)
    }
}

// MARK: - Fixture

/// One holder terminal on an AppState with an isolated store, a stub daemon,
/// and the panels made for it.
@MainActor
private final class SwitchFixture {
    let suite: TestDefaultsSuite
    let state: AppState
    let appearance: AppearanceSettings
    let worktreeID: UUID
    let terminalID: UUID
    let row: TBDShared.Terminal
    /// One per attach the daemon can vend.
    let ptys: [HolderTestPTY]
    let daemon: SwitchingHolderDaemon
    private var panels: [SwitchPanel] = []

    /// `flag` is the stored `useGhosttyTerminalEngine`, nil for unset.
    init(label: String, flag: Bool?) {
        let suite = TestDefaultsSuite("TBDAppTests.TerminalEngineSwitch.\(label)")
        if let flag {
            suite.defaults.set(flag, forKey: AppState.useGhosttyTerminalEngineKey)
        }
        let worktreeID = UUID()
        let terminalID = UUID()
        let row = TerminalEngineSwitchTests.row(terminalID, worktreeID: worktreeID, transport: .holder)
        let ptys = [HolderTestPTY(), HolderTestPTY()]
        let state = AppState(userDefaults: suite.defaults)
        state.terminals[worktreeID] = [row]
        self.suite = suite
        self.state = state
        self.appearance = AppearanceSettings(defaults: suite.defaults)
        self.worktreeID = worktreeID
        self.terminalID = terminalID
        self.row = row
        self.ptys = ptys
        self.daemon = SwitchingHolderDaemon(vending: ptys.map(\.vended))
    }

    /// A panel as `makeNSView` makes one: the engine AppState asks for, the
    /// coordinator wired to it, and the panel's engine records entered.
    func makePanel(
        makeGhostty: TerminalEngineFactory.GhosttyMaker = TerminalEngineFactory.makeGhosttyEngine,
        fallbacks: MakerAttemptLog? = nil
    ) -> SwitchPanel {
        let engine = TerminalEngineFactory.make(
            kind: state.terminalEngineKind(for: terminalID),
            font: appearance.font,
            appearance: appearance,
            configuration: TerminalEngineConfiguration(terminalID: terminalID),
            makeGhostty: makeGhostty,
            onFallback: { requested, _ in fallbacks?.fallbacks.append(requested) })
        let coordinator = TerminalPanelRepresentable.Coordinator()
        coordinator.appState = state
        coordinator.panelID = terminalID
        coordinator.holderAttachClient = daemon
        // One attempt per attach: each attach here is vended exactly once.
        coordinator.holderAttachRetryDelays = []
        coordinator.engine = engine
        engine.delegate = coordinator
        TerminalPanelRepresentable.registerEngineRecords(
            of: coordinator, builtOn: engine.kind, in: state, terminalID: terminalID)
        let panel = SwitchPanel(coordinator: coordinator, engine: engine)
        panels.append(panel)
        return panel
    }

    /// A panel as `dismantleNSView` takes one down.
    func dismantle(_ panel: SwitchPanel) {
        TerminalPanelRepresentable.unregisterEngineRecords(of: panel.coordinator, terminalID: terminalID)
        panel.coordinator.cleanup()
    }

    /// The identity the pinned dock gives this terminal's panel, as SwiftUI
    /// would compute it now.
    var identity: String {
        TerminalPanePresentation.attachIdentity(
            for: row, attachEpoch: 0, attachRetry: 0,
            engineOverride: state.terminalEngineOverrides[terminalID])
    }

    /// Plays the session: bytes the child writes on attach `index`'s pty.
    func sessionWrites(_ text: String, on index: Int) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(ptys[index].far, $0.baseAddress, $0.count) }
    }

    func tearDown() {
        for panel in panels { panel.coordinator.cleanup() }
        // A pty never vended is still this fixture's to close; a vended one
        // is its reader's.
        for (index, pty) in ptys.enumerated() {
            if index >= daemon.vendCount { Darwin.close(pty.vended) }
            pty.closeFar()
        }
        suite.tearDown()
    }
}

/// A made panel: its coordinator and the engine it was built on.
@MainActor
private final class SwitchPanel {
    let coordinator: TerminalPanelRepresentable.Coordinator
    let engine: any TerminalEngine

    init(coordinator: TerminalPanelRepresentable.Coordinator, engine: any TerminalEngine) {
        self.coordinator = coordinator
        self.engine = engine
    }
}

/// What an injected libghostty maker did. Main-actor, so the maker, a
/// main-actor closure, counts without capturing a mutable local.
@MainActor
private final class MakerAttemptLog {
    var count = 0
    var fallbacks: [TerminalEngineKind] = []
}

/// Plays the daemon's holder RPCs across a switch: each attach vends the next
/// socketpair, carrying the screen the last detach handed back, as the
/// daemon's reader resumes from it.
private final class SwitchingHolderDaemon: HolderAttaching, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var handedBack: [Data] = []
    private var vended = 0
    private let descriptors: [Int32]
    let resendDelays: [Duration] = HolderAttachRetry.handbackResendDelays
    let clock: any Clock<Duration> = ImmediateClock<Duration>()

    init(vending descriptors: [Int32]) {
        self.descriptors = descriptors
    }

    var events: [String] { lock.withLock { log } }
    var detachPreambles: [Data] { lock.withLock { handedBack } }
    var vendCount: Int { lock.withLock { vended } }

    func attach(
        worktreeID: UUID, paneID: String, terminalID: UUID, attachSeq: UInt64
    ) async throws -> HolderAttachment {
        let next: (fd: Int32, generation: UInt64, preamble: Data)? = lock.withLock {
            log.append("attach")
            guard vended < descriptors.count else { return nil }
            vended += 1
            return (descriptors[vended - 1], UInt64(vended), handedBack.last ?? Data())
        }
        guard let next else {
            throw DaemonClientError.attachUnavailable("no session left to vend")
        }
        return HolderAttachment(ptyFD: next.fd, generation: next.generation, snapshotPreamble: next.preamble)
    }

    func ready(
        worktreeID: UUID, paneID: String, terminalID: UUID, generation: UInt64
    ) async throws {
        lock.withLock { log.append("ready") }
    }

    func detach(
        worktreeID: UUID, paneID: String, terminalID: UUID, generation: UInt64,
        snapshotPreamble: Data
    ) async throws {
        lock.withLock {
            log.append("detach")
            handedBack.append(snapshotPreamble)
        }
    }
}

private extension HolderTestPTY {
    /// Whether every copy of `vended` in this process is closed, after
    /// reading away anything the panel wrote to the session first.
    var isClosedAfterDraining: Bool {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(far, $0.baseAddress, $0.count) }
            if count > 0 { continue }
            return count == 0
        }
    }
}
