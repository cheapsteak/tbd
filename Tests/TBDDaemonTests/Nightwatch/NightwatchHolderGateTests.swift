import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("NightwatchHolderGate")
struct NightwatchHolderGateTests {
    @Test(arguments: NightwatchMode.allCases)
    func holderOffAcceptsEveryMode(mode: NightwatchMode) {
        #expect(!NightwatchHolderGate.refusesMode(mode, holderEnabled: false))
    }

    @Test func holderOnRefusesOnlyWatchModes() {
        #expect(!NightwatchHolderGate.refusesMode(.off, holderEnabled: true))
        #expect(NightwatchHolderGate.refusesMode(.daywatch, holderEnabled: true))
        #expect(NightwatchHolderGate.refusesMode(.nightwatch, holderEnabled: true))
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
        #expect(NightwatchHolderGate.bootMustTurnModeOff(nullColumn))

        var explicitOff = ConfigRecord(id: "unstored", pty_holder_enabled: false)
            .toModel(ptyHolderDefault: true)
        explicitOff.nightwatchMode = .nightwatch
        #expect(!NightwatchHolderGate.bootMustTurnModeOff(explicitOff))
    }

    @Test func bootReconcileIsANoOpUnlessBothAreOn() {
        var config = ConfigRecord(id: "unstored", pty_holder_enabled: true).toModel()
        config.nightwatchMode = .off
        #expect(!NightwatchHolderGate.bootMustTurnModeOff(config))
        config.ptyHolderEnabled = false
        config.nightwatchMode = .daywatch
        #expect(!NightwatchHolderGate.bootMustTurnModeOff(config))
        config.ptyHolderEnabled = true
        #expect(NightwatchHolderGate.bootMustTurnModeOff(config))
    }

    @Test func copyNamesTheFlagTheReplacementAndTheFirstStep() {
        #expect(NightwatchHolderGate.modeRefusal.contains("pty-holder"))
        #expect(NightwatchHolderGate.modeRefusal.contains("deprecated"))
        #expect(NightwatchHolderGate.modeRefusal.contains("fleet supervision"))
        #expect(NightwatchHolderGate.holderRefusal.contains("Turn Nightwatch off first"))
        #expect(NightwatchHolderGate.deprecationNotice.contains("deprecated"))
    }
}
