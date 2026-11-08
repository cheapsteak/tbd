import AppKit
import Clocks
import Darwin
import Foundation
import Observation
import SwiftUI
import Testing
@testable import TBDApp
import TBDGhosttyTerminal
import TBDShared
import TestSupport

/// Switch Terminal Engine and the tab's engine label.
///
/// A switch only records the other engine in
/// `AppState.terminalEngineOverrides`. The changed identity rebuilds the
/// panel: the old one's teardown hands the holder session back, with its
/// screen, as any teardown does, and the new one, built on the other engine,
/// waits for that handback and attaches as any new panel does. The panel
/// tests drive the coordinator the way `makeNSView` and `dismantleNSView` do,
/// through the same `registerEngineRecords` / `unregisterEngineRecords`,
/// against a stub daemon that vends one socketpair per attach and hands the
/// second attach the screen the first detach carried. Every store is an
/// isolated suite.
@MainActor
@Suite("Switch Terminal Engine", .fastPassBounded)
struct TerminalEngineSwitchTests {

    // MARK: - The switch

    /// The switch itself leaves the session alone, so the panel keeps reading
    /// it until SwiftUI tears the panel down. That teardown is the one
    /// handback, and it is the whole of one: the reader reads on to the end of
    /// a sequence the session is part-way through, the write side stays open
    /// until the reader has closed, so a query read on the way out is
    /// answered, and the screen the detach carries reaches the panel built on
    /// the other engine. The reader's wait is on a clock that never moves, so
    /// it ends by the sequence ending, however long a loaded machine keeps the
    /// reader thread from its first look.
    @Test("A switch leaves the session alone, and the teardown it causes is the one handback: it finishes an open sequence, answers a query read on the way out, and carries the screen to the other engine",
          .enabled(if: EngineTestSupport.canBuildGhostty, EngineTestSupport.noMetalDevice),
          arguments: TerminalEngineKind.allCases)
    func switchLeavesTheSessionToTheTeardownsOneHandback(from start: TerminalEngineKind) async throws {
        let fixture = SwitchFixture(label: "Handback.\(start.rawValue)", flag: true)
        defer { fixture.tearDown() }
        fixture.state.terminalEngineOverrides[fixture.terminalID] = start
        // What the session writes the moment the first panel's reader stops:
        // the end of the title it is part-way through, a line, and a query.
        let first = fixture.makePanel(
            clock: ImmediateClock<Duration>(),
            readerBeforeClose: fixture.sessionWritesOnceTheReaderStops(
                "TITLE-PAYLOAD\u{07}AFTER-THE-SWITCH\r\n\u{1b}[6n", on: 0))
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
        let identityChanged = HolderTestLatch()
        withObservationTracking {
            _ = fixture.identity
        } onChange: {
            identityChanged.set()
        }

        fixture.state.switchTerminalEngine(terminalID: fixture.terminalID)

        #expect(identityChanged.isSet,
                "the switch changed nothing the panel's identity reads, so SwiftUI would not rebuild the panel")
        #expect(fixture.identity != identityBefore)
        #expect(fixture.state.terminalEngineOverrides[fixture.terminalID] == start.other)
        #expect(fixture.daemon.events == ["attach", "ready"],
                "the switch touched the session itself, ahead of the teardown: \(fixture.daemon.events)")
        #expect(!fixture.ptys[0].isClosedAfterDraining, "the switch closed the panel's descriptors")

        // Until the teardown, the session is still this panel's: output after
        // the switch paints here, and this output stops part-way through a
        // title.
        fixture.sessionWrites("BETWEEN\r\n\u{1b}]0;HALF-OF-A-", on: 0)
        let stillReading = await EngineTestSupport.waitUntil(
            "output written after the switch to reach the first panel, part-way through a title",
            observed: { "\(Self.screenText(firstEngine)) between sequences=\(firstEngine.isAtSequenceBoundary)" }
        ) { Self.screenText(firstEngine).contains("BETWEEN") && !firstEngine.isAtSequenceBoundary }
        try #require(stillReading)

        // What SwiftUI does once the identity has changed: the old panel goes
        // and a new one is made, asking AppState which engine to build. The
        // new one's attach waits for the old one's handback.
        fixture.dismantle(first)
        let second = fixture.makePanel()
        #expect(second.engine.kind == start.other, "the rebuilt panel was built on \(second.engine.kind)")
        await second.coordinator.startHolderClient(engine: second.engine)
        #expect(fixture.daemon.events == ["attach", "ready", "detach", "attach", "ready"],
                "the switch did not come to exactly one detach, then the rebuilt panel's attach: \(fixture.daemon.events)")

        let answered = fixture.sessionReads(on: 0)
        #expect(answered.range(of: "\u{1b}\\[[0-9]+;1R", options: .regularExpression) != nil, """
            the session asked where the cursor was as the first panel closed, and no answer reached it: \
            \(answered.debugDescription)
            """)
        let handedBack = try #require(fixture.daemon.detachPreambles.first)
        #expect(!handedBack.isEmpty, "the teardown's detach carried no screen")

        let secondEngine = second.engine
        let shown = await EngineTestSupport.waitUntil(
            "the handed-back screen to paint on \(start.other)",
            observed: { Self.screenText(secondEngine) }
        ) { Self.screenText(secondEngine).contains("AFTER-THE-SWITCH") }
        try #require(shown, "output the first panel read after its stop did not reach the handback")
        let screen = Self.screenText(secondEngine)
        #expect(screen.contains("BEFORE-THE-SWITCH") && screen.contains("BETWEEN"), "the rebuilt panel shows \(screen)")
        #expect(!screen.contains("PAYLOAD"), "the title's rest painted as text: \(screen)")

        await EngineTestSupport.mainQueueTurn()
        #expect(fixture.state.terminalEngineKindInUse(for: fixture.terminalID) == start.other,
                "the tab's label would still name the engine the panel left")
    }

    /// The switch awaits nothing, so nothing it does can land after the tab
    /// closes. A terminal closed while the teardown the switch caused is
    /// still handing the session back keeps no override, and a row that comes
    /// back under the same id starts on the engine the flag gives it.
    @Test("A terminal closed while the switch's teardown hands it back keeps no override, and a row that returns under its id starts on the flag's engine")
    func aTerminalClosedDuringTheHandbackKeepsNoOverride() async throws {
        let fixture = SwitchFixture(label: "ClosedDuringHandback", flag: true)
        defer { fixture.tearDown() }
        let base = TerminalPanePresentation.attachIdentity(
            for: fixture.row, attachEpoch: 0, attachRetry: 0, engineOverride: nil)
        fixture.state.terminalEngineOverrides[fixture.terminalID] = .swiftTerm
        let first = fixture.makePanel()
        await first.coordinator.startHolderClient(engine: first.engine)
        try #require(fixture.daemon.events == ["attach", "ready"], "\(fixture.daemon.events)")

        fixture.state.switchTerminalEngine(terminalID: fixture.terminalID)
        #expect(fixture.state.terminalEngineOverrides[fixture.terminalID] == .ghostty)

        // The rebuild's teardown starts the handback, and the tab closes
        // before the handback can run: nothing suspends in between.
        fixture.dismantle(first)
        fixture.state.terminals[fixture.worktreeID] = []
        fixture.state.recordTerminalRemoval(terminalID: fixture.terminalID)
        await fixture.state.holderHandbackLedger.awaitSettled(terminalID: fixture.terminalID)
        await EngineTestSupport.mainQueueTurn()

        #expect(fixture.daemon.events == ["attach", "ready", "detach"],
                "the closed terminal was not handed back once: \(fixture.daemon.events)")
        #expect(fixture.state.terminalEngineOverrides[fixture.terminalID] == nil,
                "the closed terminal's override came back after its handback")
        #expect(fixture.state.terminalEngineKindInUse(for: fixture.terminalID) == nil)
        #expect(fixture.state.terminalEngineSwitchers[fixture.terminalID] == nil)

        fixture.state.terminals[fixture.worktreeID] = [fixture.row]
        #expect(fixture.state.terminalEngineKind(for: fixture.terminalID)
                == TerminalEngineFactory.requestedKind(flagEnabled: true, host: .panel(.holder)))
        #expect(fixture.identity == base, "a returning row's panel carries the closed terminal's override")
    }

    /// A holder terminal opened while the experiment was off runs on
    /// SwiftTerm with no override. Once the flag is on it already resolves to
    /// libghostty, so a switch that compared its target with that would do
    /// nothing; the switch moves the panel off the engine it is actually on.
    /// The rebuilt panel is libghostty wherever this machine can draw with it,
    /// and elsewhere its start falls back as any would, so what is checked on
    /// every runner is that it asked for libghostty.
    @Test("A holder terminal opened while the flag was off switches to libghostty once the flag is on, and its tab then names the engine")
    func switchMovesATerminalOpenedBeforeTheFlagWasOn() async throws {
        let fixture = SwitchFixture(label: "OpenedBeforeTheFlag", flag: false)
        defer { fixture.tearDown() }
        let first = fixture.makePanel()
        try #require(first.engine.kind == .swiftTerm, "with the flag off the panel was built on \(first.engine.kind)")
        await first.coordinator.startHolderClient(engine: first.engine)
        try #require(fixture.daemon.events == ["attach", "ready"], "\(fixture.daemon.events)")

        fixture.suite.defaults.set(true, forKey: AppState.useGhosttyTerminalEngineKey)
        try #require(fixture.state.terminalEngineKind(for: fixture.terminalID) == .ghostty,
                     "with the flag on a holder terminal does not ask for libghostty, so this tests nothing")
        let identity = fixture.identity
        fixture.state.switchTerminalEngine(terminalID: fixture.terminalID)
        #expect(fixture.identity != identity,
                "the switch left the identity alone, so the panel would stay on SwiftTerm")
        #expect(fixture.state.terminalEngineOverrides[fixture.terminalID] == .ghostty)
        #expect(fixture.daemon.events == ["attach", "ready"], "\(fixture.daemon.events)")

        fixture.dismantle(first)
        let attempts = MakerAttemptLog()
        let second = fixture.makePanel(
            makeGhostty: { font, appearance, configuration in
                attempts.count += 1
                return try TerminalEngineFactory.makeGhosttyEngine(
                    font: font, appearance: appearance, configuration: configuration)
            },
            fallbacks: attempts)
        #expect(attempts.count == 1, "the rebuilt panel did not ask for libghostty")
        let expected: TerminalEngineKind = EngineTestSupport.canBuildGhostty ? .ghostty : .swiftTerm
        #expect(second.engine.kind == expected, "the rebuilt panel was built on \(second.engine.kind)")
        await second.coordinator.startHolderClient(engine: second.engine)
        #expect(fixture.daemon.events == ["attach", "ready", "detach", "attach", "ready"],
                "\(fixture.daemon.events)")

        await EngineTestSupport.mainQueueTurn()
        let label = TerminalEngineLabel.text(
            experimentEnabled: fixture.state.ghosttyTerminalEngineEnabled,
            kind: fixture.state.terminalEngineKindInUse(for: fixture.terminalID))
        #expect(label != nil, "the switched terminal's tab names no engine")
        #expect(label == TerminalEngineLabel.text(experimentEnabled: true, kind: expected))
    }

    /// A panel built before AppState loaded its row resolves as tmux, so it is
    /// SwiftTerm; once the row is seen as holder, the terminal resolves to
    /// libghostty, and the switch must still move the panel.
    @Test("A panel built before its holder row loaded switches to libghostty once the row is in")
    func switchMovesAPanelBuiltBeforeItsRowLoaded() {
        let fixture = SwitchFixture(label: "BuiltBeforeItsRow", flag: true)
        defer { fixture.tearDown() }
        fixture.state.terminals[fixture.worktreeID] = []
        let panel = fixture.makePanel()
        #expect(panel.engine.kind == .swiftTerm, "a panel with no row was built on \(panel.engine.kind)")

        fixture.state.terminals[fixture.worktreeID] = [fixture.row]
        #expect(fixture.state.terminalEngineKind(for: fixture.terminalID) == .ghostty)
        let identity = fixture.identity
        fixture.state.switchTerminalEngine(terminalID: fixture.terminalID)
        #expect(fixture.identity != identity,
                "the switch left the identity alone, so the panel would stay on SwiftTerm")
        #expect(fixture.state.terminalEngineOverrides[fixture.terminalID] == .ghostty)
        #expect(fixture.state.terminalEngineKind(for: fixture.terminalID) == .ghostty)
    }

    /// Every branch of the decision, including the one where the override
    /// already names the target but the panel was built on the other engine:
    /// writing it again would change nothing, so the override goes and the
    /// default, libghostty, rebuilds the panel.
    @Test("A switch writes the override that moves the panel off the engine it is on, and skips only a fallback, a pending rebuild and a state nothing moves")
    func switchPlanMovesThePanelOffItsEngine() {
        typealias Plan = TerminalEngineSwitchPlan
        func plan(
            requested: TerminalEngineKind, builtOn: TerminalEngineKind,
            builtWith: TerminalEngineKind?, now: TerminalEngineKind?
        ) -> Plan {
            Plan.plan(
                build: TerminalEngineBuild(requested: requested, override: builtWith),
                builtOn: builtOn, currentOverride: now)
        }

        // Opened while the flag was off, or before its row loaded.
        #expect(plan(requested: .swiftTerm, builtOn: .swiftTerm, builtWith: nil, now: nil) == .setOverride(.ghostty))
        #expect(plan(requested: .ghostty, builtOn: .ghostty, builtWith: nil, now: nil) == .setOverride(.swiftTerm))
        #expect(plan(requested: .swiftTerm, builtOn: .swiftTerm, builtWith: .swiftTerm, now: .swiftTerm)
                == .setOverride(.ghostty))
        #expect(plan(requested: .ghostty, builtOn: .ghostty, builtWith: .ghostty, now: .ghostty)
                == .setOverride(.swiftTerm))
        // Built on SwiftTerm while the flag was off, under a libghostty
        // override left from before: the override already names the target.
        #expect(plan(requested: .swiftTerm, builtOn: .swiftTerm, builtWith: .ghostty, now: .ghostty)
                == .setOverride(nil))
        #expect(TerminalEngineFactory.requestedKind(flagEnabled: true, host: .panel(.holder), override: nil) == .ghostty,
                "removing the override no longer asks for libghostty, so the case above would not move the panel")

        #expect(plan(requested: .ghostty, builtOn: .swiftTerm, builtWith: nil, now: nil) == .skipFellBack)
        #expect(plan(requested: .ghostty, builtOn: .swiftTerm, builtWith: .ghostty, now: .ghostty) == .skipFellBack)
        #expect(plan(requested: .swiftTerm, builtOn: .swiftTerm, builtWith: nil, now: .ghostty) == .skipRebuildPending)
        #expect(plan(requested: .ghostty, builtOn: .ghostty, builtWith: nil, now: .swiftTerm) == .skipRebuildPending)
        #expect(plan(requested: .ghostty, builtOn: .ghostty, builtWith: .swiftTerm, now: .swiftTerm) == .skipNothingMoves)
    }

    @Test("The override is kept across panel rebuilds, a fresh AppState has none, and it goes with the terminal")
    func overrideSurvivesRebuildAndIsGoneAfterRelaunch() {
        let fixture = SwitchFixture(label: "Relaunch", flag: true)
        defer { fixture.tearDown() }
        let base = TerminalPanePresentation.attachIdentity(
            for: fixture.row, attachEpoch: 0, attachRetry: 0, engineOverride: nil)
        #expect(base == "\(fixture.terminalID)-\(fixture.row.tmuxWindowID)-0-0",
                "an override of nil changed the identity of a terminal nobody switched")

        // On SwiftTerm as if switched there before, and never attached.
        fixture.state.terminalEngineOverrides[fixture.terminalID] = .swiftTerm
        let first = fixture.makePanel()
        #expect(first.engine.kind == .swiftTerm)
        fixture.state.switchTerminalEngine(terminalID: fixture.terminalID)
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
            fixture.state.switchTerminalEngine(terminalID: fixture.terminalID)
            #expect(fixture.daemon.events == ["attach", "ready"],
                    "a switch with the flag \(name) touched the session: \(fixture.daemon.events)")
            #expect(fixture.state.terminalEngineOverrides[fixture.terminalID] == nil)
            #expect(fixture.identity == identity, "a switch with the flag \(name) would rebuild the panel")
        }

        // The control: flag on, a holder panel on SwiftTerm switches. The
        // switch records the engine and leaves the session to the teardown.
        let fixture = SwitchFixture(label: "Hidden.control", flag: true)
        defer { fixture.tearDown() }
        fixture.state.terminalEngineOverrides[fixture.terminalID] = .swiftTerm
        let panel = fixture.makePanel()
        await panel.coordinator.startHolderClient(engine: panel.engine)
        let identity = fixture.identity
        fixture.state.switchTerminalEngine(terminalID: fixture.terminalID)
        #expect(fixture.daemon.events == ["attach", "ready"], "\(fixture.daemon.events)")
        #expect(fixture.state.terminalEngineOverrides[fixture.terminalID] == .ghostty)
        #expect(fixture.identity != identity, "a switch with the flag on would not rebuild the panel")
    }

    /// The command is disabled on a tmux panel, and the panel's own check
    /// holds as well: a switch that reaches a tmux panel with the flag on
    /// records nothing and touches no session. Without that check the switch
    /// would record libghostty for a panel the factory keeps on SwiftTerm.
    @Test("A switch that reaches a tmux panel with the flag on records no override and touches no session")
    func switchDoesNothingForATmuxPanel() {
        let fixture = SwitchFixture(label: "Tmux", flag: true, transport: .tmux)
        defer { fixture.tearDown() }
        let panel = fixture.makePanel()
        #expect(panel.engine.kind == .swiftTerm, "a tmux panel was built on \(panel.engine.kind)")
        #expect(fixture.state.terminalEngineSwitchers[fixture.terminalID] != nil,
                "the panel registered no switch, so this would pass without the panel's check")
        let identity = fixture.identity

        fixture.state.switchTerminalEngine(terminalID: fixture.terminalID)

        #expect(fixture.state.terminalEngineOverrides[fixture.terminalID] == nil,
                "a switch recorded an engine for a tmux panel")
        #expect(fixture.identity == identity, "a switch would rebuild a tmux panel")
        #expect(fixture.daemon.events.isEmpty, "a switch on a tmux panel sent \(fixture.daemon.events)")
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

        fixture.state.switchTerminalEngine(terminalID: fixture.terminalID)
        #expect(fixture.daemon.events == ["attach", "ready"], "\(fixture.daemon.events)")
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
        // nothing would rebuild the panel, so nothing is recorded.
        let identity = fixture.identity
        fixture.state.switchTerminalEngine(terminalID: fixture.terminalID)
        #expect(fixture.daemon.events.count == 5,
                "a switch to the engine that failed touched the session: \(fixture.daemon.events)")
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

    /// Every terminal tab item reads the engine record for its label, so a
    /// write to it redraws them all. With the experiment off no label shows,
    /// so a panel's mount and teardown must not write it at all; the control,
    /// flag on, must.
    @Test("With the experiment off, a panel's mount and teardown write no engine record; with it on, they do")
    func engineRecordIsNotWrittenWhileTheExperimentIsOff() async {
        for flag in [nil, false, true] as [Bool?] {
            let name = flag.map { "\($0)" } ?? "unset"
            let fixture = SwitchFixture(label: "QuietRecord.\(name)", flag: flag)
            defer { fixture.tearDown() }
            // An override counts only while the flag is on, and keeps the
            // control's panel on SwiftTerm.
            fixture.state.terminalEngineOverrides[fixture.terminalID] = .swiftTerm
            let state = fixture.state
            let written = HolderTestLatch()
            withObservationTracking {
                _ = state.terminalEnginesInUse
            } onChange: {
                written.set()
            }

            let panel = fixture.makePanel()
            await EngineTestSupport.mainQueueTurn()
            fixture.dismantle(panel)
            await EngineTestSupport.mainQueueTurn()

            let wasWritten = written.isSet
            if flag == true {
                #expect(wasWritten, "control: with the experiment on, the panel's mount wrote no engine record")
            } else {
                #expect(!wasWritten,
                        "with the flag \(name), a panel's mount or teardown wrote the engine record every tab item reads")
                #expect(state.terminalEnginesInUse.isEmpty)
            }
        }
    }

    /// The tab's label reads the record through `TerminalEngineLabel.text`,
    /// which reads it only while the experiment is on, so with the flag off a
    /// tab does not depend on the record and a write to it does not redraw
    /// the tab.
    @Test("With the experiment off, the tab's label does not read the engine record; with it on, it does")
    func engineLabelReadsTheRecordOnlyWhileTheExperimentIsOn() {
        withTestDefaults("TerminalEngineSwitch.LabelRead") { defaults in
            let state = AppState(userDefaults: defaults)
            let terminalID = UUID()
            for enabled in [false, true] {
                let changed = HolderTestLatch()
                withObservationTracking {
                    _ = TerminalEngineLabel.text(
                        experimentEnabled: enabled, kind: state.terminalEngineKindInUse(for: terminalID))
                } onChange: {
                    changed.set()
                }
                state.noteTerminalEngineInUse(.swiftTerm, terminalID: terminalID, owner: UUID())
                let redrawn = changed.isSet
                if enabled {
                    #expect(redrawn, "control: with the experiment on, the label did not read the record")
                } else {
                    #expect(!redrawn, "with the experiment off, a record write would redraw the tab")
                }
            }
        }
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

/// One terminal, a holder one unless asked otherwise, on an AppState with an
/// isolated store, a stub daemon, and the panels made for it.
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
    init(label: String, flag: Bool?, transport: TerminalTransport = .holder) {
        let suite = TestDefaultsSuite("TBDAppTests.TerminalEngineSwitch.\(label)")
        if let flag {
            suite.defaults.set(flag, forKey: AppState.useGhosttyTerminalEngineKey)
        }
        let worktreeID = UUID()
        let terminalID = UUID()
        let row = TerminalEngineSwitchTests.row(terminalID, worktreeID: worktreeID, transport: transport)
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
    ///
    /// - Parameters:
    ///   - clock: the coordinator's, which its holder reader bounds the wait
    ///     for an open sequence on.
    ///   - readerBeforeClose: the holder reader's hook, run once its loop has
    ///     stopped and before it reads on to the end of an open sequence.
    func makePanel(
        makeGhostty: TerminalEngineFactory.GhosttyMaker = TerminalEngineFactory.makeGhosttyEngine,
        fallbacks: MakerAttemptLog? = nil,
        clock: any Clock<Duration> = ContinuousClock(),
        readerBeforeClose: (@Sendable (HolderStreamReader) -> Void)? = nil
    ) -> SwitchPanel {
        let requested = state.terminalEngineKind(for: terminalID)
        let engine = TerminalEngineFactory.make(
            kind: requested,
            font: appearance.font,
            appearance: appearance,
            configuration: TerminalEngineConfiguration(terminalID: terminalID),
            makeGhostty: makeGhostty,
            onFallback: { requested, _ in fallbacks?.fallbacks.append(requested) })
        let coordinator = TerminalPanelRepresentable.Coordinator(clock: clock)
        coordinator.appState = state
        coordinator.panelID = terminalID
        coordinator.holderAttachClient = daemon
        coordinator.holderReaderBeforeClose = readerBeforeClose
        // One attempt per attach: each attach here is vended exactly once.
        coordinator.holderAttachRetryDelays = []
        coordinator.engine = engine
        engine.delegate = coordinator
        TerminalPanelRepresentable.registerEngineRecords(
            of: coordinator, requested: requested, builtOn: engine.kind, in: state, terminalID: terminalID)
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

    /// A reader hook for `makePanel` that plays the session writing `text` on
    /// attach `index`'s pty the moment the reader has stopped: bytes only a
    /// reader that reads on after its stop can see.
    func sessionWritesOnceTheReaderStops(
        _ text: String, on index: Int
    ) -> @Sendable (HolderStreamReader) -> Void {
        let far = ptys[index].far
        let bytes = Array(text.utf8)
        return { _ in
            _ = bytes.withUnsafeBytes { Darwin.write(far, $0.baseAddress, $0.count) }
        }
    }

    /// Everything the panel has written to attach `index`'s session and
    /// nobody has read yet. The far end is non-blocking, so this stops at the
    /// first read that finds nothing, or at the end once the panel has closed.
    func sessionReads(on index: Int) -> String {
        var collected: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(ptys[index].far, $0.baseAddress, $0.count) }
            guard count > 0 else { break }
            collected.append(contentsOf: buffer[0..<count])
        }
        return String(bytes: collected, encoding: .utf8) ?? "<not UTF-8: \(collected)>"
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
