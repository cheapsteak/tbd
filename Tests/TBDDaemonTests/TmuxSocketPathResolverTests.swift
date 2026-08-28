import Foundation
import Testing
@testable import TBDDaemonLib

/// `tmux -L <name>` resolves `${TMUX_TMPDIR:-/tmp}/tmux-<uid>/<name>`, and the
/// external-attach command pins that absolute path with `-S` rather than
/// re-deriving it in the caller's shell. Both inputs are injected, so these run
/// without `setenv` — which `Tests/CLAUDE.md` forbids outside
/// `TBDHomeSerialized`.
@Suite("TmuxSocketPathResolver")
struct TmuxSocketPathResolverTests {

    @Test("an unset TMUX_TMPDIR resolves under /tmp, which is tmux's own default")
    func unsetFallsBackToTmp() {
        let resolver = TmuxSocketPathResolver(environment: [:], uid: 501)
        #expect(resolver.socketPath(server: "tbd-1a2b3c4d") == "/tmp/tmux-501/tbd-1a2b3c4d")
    }

    @Test("a set TMUX_TMPDIR is honored — the fence the test harness itself installs")
    func setValueIsHonored() {
        let resolver = TmuxSocketPathResolver(
            environment: ["TMUX_TMPDIR": "/tmp/tbd-fence"], uid: 501)
        #expect(resolver.socketPath(server: "tbd-1a2b3c4d")
            == "/tmp/tbd-fence/tmux-501/tbd-1a2b3c4d")
    }

    @Test("an EMPTY TMUX_TMPDIR falls back like an unset one, matching the shell's :- rule")
    func emptyValueFallsBack() {
        // `${TMUX_TMPDIR:-/tmp}` — the colon form, so empty and unset are the
        // same. A resolver that honored the empty string would compose
        // `/tmux-501/…` and name a socket that cannot exist.
        let resolver = TmuxSocketPathResolver(environment: ["TMUX_TMPDIR": ""], uid: 501)
        #expect(resolver.socketPath(server: "tbd-1a2b3c4d") == "/tmp/tmux-501/tbd-1a2b3c4d")
    }

    @Test("the uid is the injected one, not the running process's")
    func uidIsInjected() {
        let resolver = TmuxSocketPathResolver(environment: [:], uid: 4242)
        #expect(resolver.socketDirectory == "/tmp/tmux-4242")
        #expect(getuid() != 4242, "the fixture uid must not be the real one, or this proves nothing")
    }

    @Test("a trailing slash does not double up in the composed path")
    func trailingSlashIsNormalized() {
        let resolver = TmuxSocketPathResolver(
            environment: ["TMUX_TMPDIR": "/tmp/tbd-fence/"], uid: 501)
        #expect(resolver.socketPath(server: "tbd-x") == "/tmp/tbd-fence/tmux-501/tbd-x")
    }

    @Test("a bare / does not normalize away to an empty prefix")
    func rootIsNotEatenByNormalization() {
        let resolver = TmuxSocketPathResolver(environment: ["TMUX_TMPDIR": "/"], uid: 501)
        #expect(resolver.socketPath(server: "tbd-x").hasPrefix("/tmux-501/"))
    }
}
