import Foundation
import Testing
@testable import TBDApp

/// Tests for terminal viewer environment scrubbing.
///
/// The SwiftTerm PTY that displays terminal tabs must run `tmux attach`
/// with a clean environment — specifically, TMUX and TMUX_PANE must be removed
/// to prevent "sessions should be nested with care, unset $TMUX to force" errors
/// when TBD.app itself was launched from within a tmux session.
@Suite("Terminal viewer environment")
struct TerminalViewerEnvironmentTests {

    @Test func removeTMUXWhenPresent() {
        let baseEnv = [
            "TMUX": "/tmp/tmux-501/default",
            "TMUX_PANE": "%0",
            "PATH": "/usr/local/bin:/usr/bin",
            "HOME": "/Users/test"
        ]

        let result = TerminalPanelView.makeViewerEnvironment(base: baseEnv)

        #expect(result["TMUX"] == nil)
        #expect(result["TMUX_PANE"] == nil)
    }

    @Test func setsTERMToXterm256color() {
        let baseEnv = [
            "PATH": "/usr/local/bin:/usr/bin",
            "HOME": "/Users/test"
        ]

        let result = TerminalPanelView.makeViewerEnvironment(base: baseEnv)

        #expect(result["TERM"] == "xterm-256color")
    }

    @Test func overridesTERMIfPresent() {
        let baseEnv = [
            "TERM": "screen",
            "PATH": "/usr/local/bin:/usr/bin"
        ]

        let result = TerminalPanelView.makeViewerEnvironment(base: baseEnv)

        #expect(result["TERM"] == "xterm-256color")
    }

    @Test func passesUnrelatedKeysThrough() {
        let baseEnv = [
            "PATH": "/usr/local/bin:/usr/bin",
            "HOME": "/Users/test",
            "LANG": "en_US.UTF-8",
            "USER": "test"
        ]

        let result = TerminalPanelView.makeViewerEnvironment(base: baseEnv)

        #expect(result["PATH"] == "/usr/local/bin:/usr/bin")
        #expect(result["HOME"] == "/Users/test")
        #expect(result["LANG"] == "en_US.UTF-8")
        #expect(result["USER"] == "test")
    }

    @Test func handlesEmptyEnvironment() {
        let baseEnv: [String: String] = [:]

        let result = TerminalPanelView.makeViewerEnvironment(base: baseEnv)

        #expect(result["TERM"] == "xterm-256color")
        #expect(result.count == 1)
    }

    @Test func removeBothTMUXAndTMUXPaneWhenBothPresent() {
        let baseEnv = [
            "TMUX": "/tmp/tmux-501/default",
            "TMUX_PANE": "%0",
            "PATH": "/usr/local/bin",
            "SHELL": "/bin/zsh"
        ]

        let result = TerminalPanelView.makeViewerEnvironment(base: baseEnv)

        #expect(result["TMUX"] == nil)
        #expect(result["TMUX_PANE"] == nil)
        #expect(result["PATH"] == "/usr/local/bin")
        #expect(result["SHELL"] == "/bin/zsh")
        #expect(result["TERM"] == "xterm-256color")
    }
}
