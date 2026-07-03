import Testing
@testable import TBDDaemonLib

@Suite("ControlModeGate")
struct ControlModeGateTests {
    @Test("optedIn recognizes truthy values")
    func optedInTruthy() {
        #expect(ControlModeGate.optedIn(environment: ["TBD_TMUX_CONTROL_MODE": "1"]))
        #expect(ControlModeGate.optedIn(environment: ["TBD_TMUX_CONTROL_MODE": "true"]))
        #expect(ControlModeGate.optedIn(environment: ["TBD_TMUX_CONTROL_MODE": "YES"]))
    }

    @Test("optedIn rejects falsy or absent values")
    func optedInFalsy() {
        #expect(!ControlModeGate.optedIn(environment: ["TBD_TMUX_CONTROL_MODE": "0"]))
        #expect(!ControlModeGate.optedIn(environment: ["TBD_TMUX_CONTROL_MODE": ""]))
        #expect(!ControlModeGate.optedIn(environment: [:]))
    }

    @Test("shouldEnable requires opt-in AND a sufficient tmux version")
    func shouldEnable() {
        let on = ["TBD_TMUX_CONTROL_MODE": "1"]
        #expect(ControlModeGate.shouldEnable(environment: on,
                                             tmuxVersion: TmuxVersion(major: 3, minor: 2)))
        #expect(ControlModeGate.shouldEnable(environment: on,
                                             tmuxVersion: TmuxVersion(major: 3, minor: 6)))
        #expect(!ControlModeGate.shouldEnable(environment: on,
                                              tmuxVersion: TmuxVersion(major: 3, minor: 1)))
        #expect(!ControlModeGate.shouldEnable(environment: on, tmuxVersion: nil))
        #expect(!ControlModeGate.shouldEnable(environment: [:],
                                              tmuxVersion: TmuxVersion(major: 3, minor: 6)))
    }

    @Test("persisted flag alone (env off) opens the gate")
    func persistedFlagOpensGate() {
        #expect(ControlModeGate.shouldEnable(
            environment: [:], persistedFlag: true,
            tmuxVersion: TmuxVersion(major: 3, minor: 6)))
    }

    @Test("flag off and env off keeps the gate closed")
    func flagOffEnvOffClosed() {
        #expect(!ControlModeGate.shouldEnable(
            environment: [:], persistedFlag: false,
            tmuxVersion: TmuxVersion(major: 3, minor: 6)))
    }

    @Test("truthy env forces the gate on even with the flag off (developer override)")
    func envOverridesFlagOff() {
        #expect(ControlModeGate.shouldEnable(
            environment: ["TBD_TMUX_CONTROL_MODE": "1"], persistedFlag: false,
            tmuxVersion: TmuxVersion(major: 3, minor: 6)))
    }

    @Test("gate = env || flag: falsy env does not veto a persisted flag")
    func falsyEnvDoesNotVetoFlag() {
        #expect(ControlModeGate.shouldEnable(
            environment: ["TBD_TMUX_CONTROL_MODE": "0"], persistedFlag: true,
            tmuxVersion: TmuxVersion(major: 3, minor: 6)))
    }

    @Test("persisted flag still requires tmux >= 3.2")
    func persistedFlagStillNeedsVersion() {
        #expect(!ControlModeGate.shouldEnable(
            environment: [:], persistedFlag: true,
            tmuxVersion: TmuxVersion(major: 3, minor: 1)))
        #expect(!ControlModeGate.shouldEnable(
            environment: [:], persistedFlag: true, tmuxVersion: nil))
    }
}
