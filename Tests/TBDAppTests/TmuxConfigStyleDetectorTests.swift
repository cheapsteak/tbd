import Testing
@testable import TBDApp

@Suite("TmuxConfigStyleDetector")
struct TmuxConfigStyleDetectorTests {
    @Test("empty input is not an override")
    func empty() {
        #expect(TmuxConfigStyleDetector.declaresStyleOverride(in: "") == false)
    }

    @Test("baseline: set -g window-style is an override")
    func setG() {
        #expect(TmuxConfigStyleDetector.declaresStyleOverride(in: "set -g window-style 'fg=red'") == true)
    }

    @Test("regression: bare `set` with no flags is still an override")
    func setBare() {
        // The previous capture-based implementation treated `NSRange(NSNotFound)`
        // (missing flag group) as "skip", silently missing this case.
        #expect(TmuxConfigStyleDetector.declaresStyleOverride(in: "set window-style 'fg=red'") == true)
    }

    @Test("regression: -gu unset is the recommended fix, not an override")
    func setGUUnset() {
        #expect(TmuxConfigStyleDetector.declaresStyleOverride(in: "set -gu window-style") == false)
    }

    @Test("regression: -u not last in flag list is still an unset")
    func setUnusualOrder() {
        // `*` quantifier on a capture group only retains the LAST iteration,
        // so naïvely capturing flag tokens makes `-u` invisible when `-g`
        // follows. Scanning the whole matched range catches it.
        #expect(TmuxConfigStyleDetector.declaresStyleOverride(in: "set -u -g window-style") == false)
    }

    @Test("setw -g window-active-style is an override")
    func setwG() {
        #expect(TmuxConfigStyleDetector.declaresStyleOverride(in: "setw -g window-active-style 'fg=red'") == true)
    }

    @Test("pane-style is an override")
    func paneStyle() {
        #expect(TmuxConfigStyleDetector.declaresStyleOverride(in: "set -g pane-style 'bg=blue'") == true)
    }

    @Test("default-style is an override")
    func defaultStyle() {
        #expect(TmuxConfigStyleDetector.declaresStyleOverride(in: "set -g default-style 'fg=white'") == true)
    }

    @Test("set-option long form is an override")
    func setOptionLong() {
        #expect(TmuxConfigStyleDetector.declaresStyleOverride(in: "set-option -g window-style 'fg=red'") == true)
    }

    @Test("set-window-option long form is an override")
    func setWindowOptionLong() {
        #expect(TmuxConfigStyleDetector.declaresStyleOverride(in: "set-window-option -g window-active-style 'fg=red'") == true)
    }

    @Test("commented-out lines are not overrides")
    func commented() {
        #expect(TmuxConfigStyleDetector.declaresStyleOverride(in: "# set -g window-style 'fg=red'") == false)
    }

    @Test("look-alike option name `status-style` is not an override")
    func lookAlikeStatusStyle() {
        #expect(TmuxConfigStyleDetector.declaresStyleOverride(in: "set -g status-style 'fg=red'") == false)
    }

    @Test("option name appearing as substring inside a quoted value is not an override")
    func quotedSubstring() {
        #expect(TmuxConfigStyleDetector.declaresStyleOverride(in: "set -g status-left 'window-style is great'") == false)
    }

    @Test("multi-line: first line negative, second line positive")
    func multilineFirstNegativeSecondPositive() {
        let config = """
        set -g status-style 'fg=red'
        set -g window-style 'fg=red'
        """
        #expect(TmuxConfigStyleDetector.declaresStyleOverride(in: config) == true)
    }

    @Test("multi-line: override followed by unset still reports presence")
    func multilineOverrideThenUnset() {
        // NOTE: This is a documented limitation. We detect *presence* of
        // override directives, not *effective* state. A later `-gu` unset
        // would in fact neutralize the earlier override at runtime, but
        // tracking last-write-wins (and `source-file`/`if-shell`/`%if`
        // conditionals) is out of scope for this best-effort regex.
        let config = """
        set -g window-style 'fg=red'
        set -gu window-style
        """
        #expect(TmuxConfigStyleDetector.declaresStyleOverride(in: config) == true)
    }
}
