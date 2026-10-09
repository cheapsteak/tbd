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
            holderEnabled: true, holderSupported: true))
        #expect(!NightwatchHolderGate.watchModesBlocked(
            holderEnabled: true, holderSupported: false),
                "no helper means no holder session, so no hazard to refuse")
        #expect(!NightwatchHolderGate.watchModesBlocked(
            holderEnabled: false, holderSupported: true))
        #expect(!NightwatchHolderGate.watchModesBlocked(
            holderEnabled: false, holderSupported: false))
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
            holderEnabled: config.ptyHolderEnabled, holderSupported: false)
        #expect(!NightwatchHolderGate.refusesMode(mode, whileBlocked: blocked))

        var withMode = config
        withMode.nightwatchMode = mode
        #expect(!NightwatchHolderGate.bootMustTurnModeOff(withMode, holderSupported: false),
                "boot must leave a watch mode running on a daemon that cannot start a holder")
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
        #expect(NightwatchHolderGate.bootMustTurnModeOff(nullColumn, holderSupported: true))

        var explicitOff = ConfigRecord(id: "unstored", pty_holder_enabled: false)
            .toModel(ptyHolderDefault: true)
        explicitOff.nightwatchMode = .nightwatch
        #expect(!NightwatchHolderGate.bootMustTurnModeOff(explicitOff, holderSupported: true))
    }

    @Test func bootReconcileIsANoOpUnlessBothAreOn() {
        var config = ConfigRecord(id: "unstored", pty_holder_enabled: true).toModel()
        config.nightwatchMode = .off
        #expect(!NightwatchHolderGate.bootMustTurnModeOff(config, holderSupported: true))
        config.ptyHolderEnabled = false
        config.nightwatchMode = .daywatch
        #expect(!NightwatchHolderGate.bootMustTurnModeOff(config, holderSupported: true))
        config.ptyHolderEnabled = true
        #expect(NightwatchHolderGate.bootMustTurnModeOff(config, holderSupported: true))
    }

    @Test func copyNamesTheFlagTheReplacementAndTheFirstStep() {
        #expect(NightwatchHolderGate.modeRefusal.contains("pty-holder"))
        #expect(NightwatchHolderGate.modeRefusal.contains("deprecated"))
        #expect(NightwatchHolderGate.modeRefusal.contains("fleet supervision"))
        #expect(NightwatchHolderGate.holderRefusal.contains("Turn Nightwatch off first"))
        #expect(NightwatchHolderGate.deprecationNotice.contains("deprecated"))
    }
}
