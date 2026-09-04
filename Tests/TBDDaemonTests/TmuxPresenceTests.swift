import Foundation
import Testing
@testable import TBDDaemonLib

/// Tri-state tmux probes: "tmux says it is gone" must stay distinguishable
/// from "tmux never answered".
///
/// The classifier is a whitelist, so the assertions worth having are the ones
/// that fall OFF the whitelist: a timeout, a spawn failure, and a failure
/// message nobody recognised all have to read as `unknown`. Those are the
/// values that used to arrive as `false` and get a live session parked.
@Suite("Tmux presence probes")
struct TmuxPresenceTests {

    // MARK: - Classifier

    @Test func serverProbeReadsTmuxNoServerAsAbsent() {
        let error = TmuxError.commandFailed(
            command: "tmux -L tbd-abc list-sessions", status: 1,
            output: "no server running on /private/tmp/tmux-501/tbd-abc")
        #expect(TmuxPresenceClassifier.serverPresence(for: error) == .absent)
    }

    /// tmux says "no server running on" only for ECONNREFUSED and falls back to
    /// "error connecting to <socket> (<errno>)" for everything else, so the
    /// prefix is read together with the errno text. ENOENT is absence: the
    /// socket file itself is not there.
    @Test func serverProbeReadsAMissingSocketAsAbsent() {
        let error = TmuxError.commandFailed(
            command: "tmux -L tbd-abc list-sessions", status: 1,
            output: "error connecting to /private/tmp/tmux-501/tbd-abc (No such file or directory)")
        #expect(TmuxPresenceClassifier.serverPresence(for: error) == .absent)
        #expect(TmuxPresenceClassifier.windowPresence(for: error) == .absent)
    }

    /// The same prefix, a different errno, and the opposite meaning. A socket
    /// we may not open is a server we cannot reach, not one that is gone —
    /// reading it as absence would park and delete a live fleet's rows.
    @Test func serverProbeReadsAnUnreachableSocketAsUnknown() {
        for errnoText in ["Permission denied", "Connection reset by peer", "Operation timed out"] {
            let error = TmuxError.commandFailed(
                command: "tmux -L tbd-abc list-sessions", status: 1,
                output: "error connecting to /private/tmp/tmux-501/tbd-abc (\(errnoText))")
            #expect(TmuxPresenceClassifier.serverPresence(for: error) == .unknown,
                    "a socket error of \(errnoText) was read as proof the server is gone")
            #expect(TmuxPresenceClassifier.windowPresence(for: error) == .unknown,
                    "a socket error of \(errnoText) was read as proof the window is gone")
        }
    }

    @Test func windowProbeReadsTmuxCantFindWindowAsAbsent() {
        let error = TmuxError.commandFailed(
            command: "tmux -L tbd-abc list-panes -t @7", status: 1,
            output: "can't find window: @7")
        #expect(TmuxPresenceClassifier.windowPresence(for: error) == .absent)
    }

    /// No server means positively no window on it. The reverse does not hold,
    /// which is why the two marker lists are separate.
    @Test func windowProbeInheritsServerAbsence() {
        let error = TmuxError.commandFailed(
            command: "tmux -L tbd-abc list-panes -t @7", status: 1,
            output: "no server running on /private/tmp/tmux-501/tbd-abc")
        #expect(TmuxPresenceClassifier.windowPresence(for: error) == .absent)
    }

    /// A server probe must NOT accept a window message as evidence about the
    /// server — the server was plainly up to have said it.
    @Test func serverProbeDoesNotAcceptWindowMessage() {
        let error = TmuxError.commandFailed(
            command: "tmux -L tbd-abc list-sessions", status: 1,
            output: "can't find window: @7")
        #expect(TmuxPresenceClassifier.serverPresence(for: error) == .unknown)
    }

    /// The regression this whole type exists for: the 15 s ceiling firing on a
    /// busy machine is ignorance, and it used to be spelled `false`.
    @Test func timeoutIsUnknownNotAbsent() {
        let error = TmuxError.timedOut(
            command: "tmux -L tbd-abc list-panes -t @7", timeout: .seconds(15))
        #expect(TmuxPresenceClassifier.windowPresence(for: error) == .unknown)
        #expect(TmuxPresenceClassifier.serverPresence(for: error) == .unknown)
    }

    @Test func missingTmuxExecutableIsUnknown() {
        let error = TmuxError.commandFailed(
            command: "tmux -L tbd-abc list-panes -t @7", status: 127,
            output: "tmux executable is unavailable")
        #expect(TmuxPresenceClassifier.windowPresence(for: error) == .unknown)
    }

    @Test func unrecognisedFailureIsUnknown() {
        let error = TmuxError.commandFailed(
            command: "tmux -L tbd-abc list-panes -t @7", status: 1,
            output: "lost server")
        #expect(TmuxPresenceClassifier.windowPresence(for: error) == .unknown)
        #expect(TmuxPresenceClassifier.serverPresence(for: error) == .unknown)
    }

    @Test func unexpectedOutputIsUnknown() {
        #expect(
            TmuxPresenceClassifier.windowPresence(for: TmuxError.unexpectedOutput("???")) == .unknown)
    }

    // MARK: - Dry-run seams

    /// Without a hook, dry-run keeps saying exactly what the `Bool` probes said
    /// — alive server, alive window — so every fixture written before the
    /// tri-state existed keeps its meaning.
    @Test func dryRunDefaultsMatchTheBoolProbes() async {
        let tmux = TmuxManager(dryRun: true)
        #expect(await tmux.probeServer(server: "tbd-abc") == .alive)
        #expect(await tmux.probeWindow(server: "tbd-abc", windowID: "@1") == .alive)
        #expect(await tmux.serverExists(server: "tbd-abc"))
        #expect(await tmux.windowExists(server: "tbd-abc", windowID: "@1"))
    }

    @Test func dryRunWindowIsDeadStillMeansAbsent() async {
        let tmux = TmuxManager(dryRun: true, dryRunWindowIsDead: { $0 == "@2" })
        #expect(await tmux.probeWindow(server: "tbd-abc", windowID: "@2") == .absent)
        #expect(await tmux.probeWindow(server: "tbd-abc", windowID: "@1") == .alive)
    }

    @Test func dryRunPresenceHooksWin() async {
        let tmux = TmuxManager(
            dryRun: true,
            dryRunWindowIsDead: { _ in true },
            dryRunServerPresence: { _ in .unknown },
            dryRunWindowPresence: { _, _ in .unknown })
        #expect(await tmux.probeServer(server: "tbd-abc") == .unknown)
        #expect(await tmux.probeWindow(server: "tbd-abc", windowID: "@2") == .unknown)
    }

    @Test func realModeOverridesAnswerWithoutTmux() async {
        let tmux = TmuxManager(
            dryRun: false,
            realModeServerPresenceOverride: { $0 == "tbd-abc" ? .unknown : nil },
            realModeWindowPresenceOverride: { _, window in window == "@9" ? .absent : nil })
        #expect(await tmux.probeServer(server: "tbd-abc") == .unknown)
        #expect(await tmux.probeWindow(server: "tbd-abc", windowID: "@9") == .absent)
    }
}
