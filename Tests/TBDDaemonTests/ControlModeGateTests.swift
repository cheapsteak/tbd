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
}
