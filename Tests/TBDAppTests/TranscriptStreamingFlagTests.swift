import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// `AppState.transcriptStreamingEnabled` — the single place the app asks
/// whether a transcript pane should read the session mod's stream file at all.
///
/// Every test constructs `AppState` against a unique throwaway `UserDefaults`
/// suite and tears it down: TBDApp ships as an unbundled SPM executable, so
/// `UserDefaults.standard` is the running developer's real `TBDApp.plist`.
@MainActor
@Suite("TranscriptStreamingFlag")
struct TranscriptStreamingFlagTests {

    private func withAppState(_ body: (AppState) async -> Void) async {
        let name = "tbd-transcript-streaming-flag-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        await body(AppState(userDefaults: defaults))
        defaults.removePersistentDomain(forName: name)
    }

    /// The app is launched by `open`, which drops shell env, so capabilities
    /// are nil until the first RPC lands. Reading that as "off" is what keeps a
    /// provisional row from appearing and then vanishing a moment later.
    @Test("capabilities that have not arrived read as off")
    func nilCapabilitiesReadAsOff() async {
        await withAppState { state in
            #expect(state.daemonCapabilities == nil)
            #expect(state.transcriptStreamingEnabled == false)
        }
    }

    @Test("the daemon reporting streaming on turns it on")
    func capabilityOnEnables() async {
        await withAppState { state in
            state.daemonCapabilities = DaemonCapabilitiesResult(
                controlModeEnabled: false, transcriptStreamingEnabled: true)

            #expect(state.transcriptStreamingEnabled)
        }
    }

    /// The off branch is its own assertion rather than an inference from the
    /// nil case: a property that ignored the field entirely and always returned
    /// false would pass the nil test too.
    @Test("the daemon reporting streaming off keeps it off")
    func capabilityOffDisables() async {
        await withAppState { state in
            state.daemonCapabilities = DaemonCapabilitiesResult(
                controlModeEnabled: false, transcriptStreamingEnabled: false)

            #expect(state.transcriptStreamingEnabled == false)
        }
    }
}

/// The live transcript pane's `.task(id:)` key.
///
/// `appSideLoop` resolves the session mod's stream file once, at the top of the
/// run, so whatever that resolution depends on has to be part of the key or the
/// loop keeps running against a stale reading of it. The flag is the input that
/// actually moves: a viewer ticks "Stream assistant text into the transcript"
/// in Settings while a pane is on screen, and off→on is the direction the soak
/// depends on.
@Suite("TranscriptPaneTaskKey")
struct TranscriptPaneTaskKeyTests {

    private static let terminalID = UUID()
    private static let sessionsDir = URL(fileURLWithPath: "/tmp/tbd-test-sessions", isDirectory: true)

    private static func key(
        streaming: Bool, sessionID: String? = "s1", exited: Bool = false
    ) -> TaskKey {
        TaskKey.resolve(
            terminalID: terminalID,
            sessionID: sessionID,
            retryToken: 0,
            transcriptPath: "/tmp/session.jsonl",
            streamingEnabled: streaming,
            terminalExited: exited,
            sessionsDir: sessionsDir)
    }

    /// The finding this test pins: with the flag outside the key, turning
    /// streaming on left an already-open pane registered without a stream path
    /// until an unrelated remount.
    @Test("flipping the streaming flag restarts the loop for the same terminal")
    func flippingTheFlagChangesTheKey() {
        let off = Self.key(streaming: false)
        let on = Self.key(streaming: true)

        #expect(off != on, "the same terminal must key differently on either side of the flag")
        #expect(off.streamPath == nil, "the flag off resolves to no stream file")
        #expect(on.streamPath == "/tmp/tbd-test-sessions/s1/transcript-stream.json")
    }

    /// The path comes from the sessions directory and the session id.
    @Test("a /clear's new session id is a new stream path")
    func theStreamPathFollowsTheSessionID() {
        #expect(Self.key(streaming: true, sessionID: "s2").streamPath
                == "/tmp/tbd-test-sessions/s2/transcript-stream.json")
    }

    @Test("a session id that is missing or unsafe as a path has no stream file")
    func anUnusableSessionIDHasNoStreamFile() {
        #expect(Self.key(streaming: true, sessionID: nil).streamPath == nil)
        #expect(Self.key(streaming: true, sessionID: "../escape").streamPath == nil)
    }

    /// A terminal exiting retires its provisional rows, and touches no file the
    /// scheduler watches: the restart is what publishes the retirement.
    @Test("a terminal exiting restarts the loop")
    func aTerminalExitChangesTheKey() {
        #expect(Self.key(streaming: true) != Self.key(streaming: true, exited: true))
    }
}
