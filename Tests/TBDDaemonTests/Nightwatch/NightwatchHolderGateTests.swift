import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("NightwatchHolderGate")
struct NightwatchHolderGateTests {
    @Test(arguments: NightwatchMode.allCases)
    func holderOffAcceptsEveryMode(mode: NightwatchMode) {
        #expect(!NightwatchHolderGate.refusesMode(mode, whileBlocked: false))
    }

    @Test func holderOnRefusesOnlyWatchModes() {
        #expect(!NightwatchHolderGate.refusesMode(.off, whileBlocked: true))
        #expect(NightwatchHolderGate.refusesMode(.daywatch, whileBlocked: true))
        #expect(NightwatchHolderGate.refusesMode(.nightwatch, whileBlocked: true))
    }

    /// **The hazard is both halves.** A daemon that cannot find the `TBDHolder`
    /// helper spawns no holder-backed session however the flag reads, so there
    /// is nothing for the gate to refuse — and with the flag now ON by default
    /// this is the state an ordinary install lands in after an upgrade that
    /// mislaid the helper. Blocking there would take Nightwatch away from an
    /// install that can still run it and name a transport change as the remedy
    /// that would change nothing.
    @Test func theHazardNeedsTheHelperAsWellAsTheFlag() {
        #expect(NightwatchHolderGate.watchModesBlocked(
            holderEnabled: true, holderSupported: true, holderSessionsLive: false))
        #expect(!NightwatchHolderGate.watchModesBlocked(
            holderEnabled: true, holderSupported: false, holderSessionsLive: false),
                "no helper and no live holder means nothing to refuse")
        #expect(!NightwatchHolderGate.watchModesBlocked(
            holderEnabled: false, holderSupported: true, holderSessionsLive: false))
        #expect(!NightwatchHolderGate.watchModesBlocked(
            holderEnabled: false, holderSupported: false, holderSessionsLive: false))
    }

    /// **A live holder session blocks on its own.** `canSpawn == false` is not
    /// "holder-free": the registry is still built when the `TBDHolder` binary
    /// is missing, because adoption reaches an already-running holder through
    /// its socket, so an upgrade that mislaid the helper while holders were
    /// running leaves live holder rows on a daemon that cannot spawn another.
    /// That is the state the desk's liveness check leaks a session per tick in,
    /// so it must block however the other two terms read.
    @Test func aLiveHolderSessionBlocksEvenWhenNothingCanSpawnOne() {
        #expect(NightwatchHolderGate.watchModesBlocked(
            holderEnabled: true, holderSupported: false, holderSessionsLive: true),
                "a helper that went missing does not retire the holders it adopted")
        #expect(NightwatchHolderGate.watchModesBlocked(
            holderEnabled: false, holderSupported: false, holderSessionsLive: true),
                "an explicit opt-out does not retire sessions already on a holder")
        #expect(NightwatchHolderGate.watchModesBlocked(
            holderEnabled: false, holderSupported: true, holderSessionsLive: true))
    }

    /// The never-touched install on a daemon with no helper: the effective flag
    /// reads on through the graduated default, and every watch mode is still
    /// accepted. Written against a `ConfigRecord` with a NULL column resolved
    /// through `ptyHolderDefault: true`, so it is the graduated state under
    /// test rather than a hand-set `true`.
    @Test(arguments: NightwatchMode.allCases)
    func anUnsupportedDaemonIsNotRefusedAWatchMode(mode: NightwatchMode) {
        let config = ConfigRecord(id: "unstored", pty_holder_enabled: nil)
            .toModel(ptyHolderDefault: true)
        #expect(config.ptyHolderEnabled, "the fixture must exercise the graduated default")
        let blocked = NightwatchHolderGate.watchModesBlocked(
            holderEnabled: config.ptyHolderEnabled,
            holderSupported: false, holderSessionsLive: false)
        #expect(!NightwatchHolderGate.refusesMode(mode, whileBlocked: blocked))

        var withMode = config
        withMode.nightwatchMode = mode
        #expect(!NightwatchHolderGate.bootMustTurnModeOff(
            withMode, holderSupported: false, holderSessionsLive: false),
                "boot must leave a watch mode running on a daemon that cannot start a holder")

        // ...but a live holder row on that same daemon blocks it again.
        #expect(mode == .off || NightwatchHolderGate.bootMustTurnModeOff(
            withMode, holderSupported: false, holderSessionsLive: true),
                "an adopted holder session is the hazard, helper or no helper")
    }

    @Test(arguments: NightwatchMode.allCases)
    func turningHolderOffIsNeverRefused(mode: NightwatchMode) {
        #expect(!NightwatchHolderGate.refusesHolder(enabling: false, currentMode: mode))
    }

    @Test func turningHolderOnIsRefusedOnlyWhileAModeIsActive() {
        #expect(!NightwatchHolderGate.refusesHolder(enabling: true, currentMode: .off))
        #expect(NightwatchHolderGate.refusesHolder(enabling: true, currentMode: .daywatch))
        #expect(NightwatchHolderGate.refusesHolder(enabling: true, currentMode: .nightwatch))
    }

    /// The gate reads the EFFECTIVE holder value: a NULL column follows a
    /// flipped shipped default; an explicit 0 does not.
    @Test func bootReconcileReadsTheEffectiveHolderValue() {
        var nullColumn = ConfigRecord(id: "unstored", pty_holder_enabled: nil)
            .toModel(ptyHolderDefault: true)
        nullColumn.nightwatchMode = .nightwatch
        #expect(NightwatchHolderGate.bootMustTurnModeOff(
            nullColumn, holderSupported: true, holderSessionsLive: false))

        var explicitOff = ConfigRecord(id: "unstored", pty_holder_enabled: false)
            .toModel(ptyHolderDefault: true)
        explicitOff.nightwatchMode = .nightwatch
        #expect(!NightwatchHolderGate.bootMustTurnModeOff(
            explicitOff, holderSupported: true, holderSessionsLive: false))
    }

    @Test func bootReconcileIsANoOpUnlessBothAreOn() {
        var config = ConfigRecord(id: "unstored", pty_holder_enabled: true).toModel()
        config.nightwatchMode = .off
        #expect(!NightwatchHolderGate.bootMustTurnModeOff(
            config, holderSupported: true, holderSessionsLive: false))
        config.ptyHolderEnabled = false
        config.nightwatchMode = .daywatch
        #expect(!NightwatchHolderGate.bootMustTurnModeOff(
            config, holderSupported: true, holderSessionsLive: false))
        config.ptyHolderEnabled = true
        #expect(NightwatchHolderGate.bootMustTurnModeOff(
            config, holderSupported: true, holderSessionsLive: false))
    }

    /// `.off` is never turned off again, whatever the hazard reads — the
    /// reconcile has nothing to do for a mode that is already off.
    @Test func modeOffIsNeverReconciled() {
        var config = ConfigRecord(id: "unstored", pty_holder_enabled: true).toModel()
        config.nightwatchMode = .off
        #expect(!NightwatchHolderGate.bootMustTurnModeOff(
            config, holderSupported: true, holderSessionsLive: true))
    }

    @Test func copyNamesTheFlagTheReplacementAndTheFirstStep() {
        #expect(NightwatchHolderGate.modeRefusal.contains("pty-holder"))
        #expect(NightwatchHolderGate.modeRefusal.contains("deprecated"))
        #expect(NightwatchHolderGate.modeRefusal.contains("fleet supervision"))
        // The refusal must name BOTH terms of the hazard. Turning the flag off
        // does not lift it while holder-backed sessions are still alive, and a
        // message that promised otherwise would send that user back to a switch
        // they have already flipped.
        #expect(
            NightwatchHolderGate.modeRefusal.contains("already running on a holder"),
            "the live-session term has to be in the copy, not only in the gate")
        #expect(
            NightwatchHolderGate.modeRefusal.contains("parked"),
            "a parked holder row counts as alive, which is the surprising half")
        #expect(NightwatchHolderGate.holderRefusal.contains("Turn Nightwatch off first"))
        #expect(NightwatchHolderGate.deprecationNotice.contains("deprecated"))
    }
}
