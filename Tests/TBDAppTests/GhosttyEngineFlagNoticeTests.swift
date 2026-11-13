import Foundation
import Testing
@testable import TBDApp
import TestSupport

/// The line `AppState` sends when `useGhosttyTerminalEngine` changes, through
/// the `onEngineNotice` sink it was built with. The latency probe reads that
/// line to tell whether an arm's latest engine line was written while the flag
/// still held, so it must come once per real change and never otherwise:
/// once at launch when the flag is on, never at launch when it is off, and
/// never for a write of the value the flag already holds. Every store is an
/// isolated suite. Tier 1, apart from bounded waits for the key-value
/// observation of a write made outside the toggle.
/// Design: `docs/specs/2026-11-07-libghostty-terminal-engine-design.md`.
@MainActor
@Suite("libghostty engine flag notices", .fastPassBounded)
struct GhosttyEngineFlagNoticeTests {
    private static let key = AppState.useGhosttyTerminalEngineKey
    private static let turnedOn: TerminalEngineNotice = .experiment(enabled: true)
    private static let turnedOff: TerminalEngineNotice = .experiment(enabled: false)

    private static func make(_ defaults: UserDefaults, _ recorder: EngineNoticeRecorder) -> AppState {
        AppState(userDefaults: defaults, onEngineNotice: { recorder.record($0) })
    }

    @Test("Launching with the flag on sends one turned-on notice")
    func launchWithTheFlagOn() {
        withTestDefaults("GhosttyEngineFlagNotice.LaunchOn") { defaults in
            defaults.set(true, forKey: Self.key)
            let recorder = EngineNoticeRecorder()
            let state = Self.make(defaults, recorder)
            let sent = recorder.notices
            #expect(sent == [Self.turnedOn], "launching with the flag on sent \(sent)")
            withExtendedLifetime(state) {}
        }
    }

    @Test("Launching with the flag stored false sends no notice")
    func launchWithTheFlagOff() {
        withTestDefaults("GhosttyEngineFlagNotice.LaunchOff") { defaults in
            defaults.set(false, forKey: Self.key)
            let recorder = EngineNoticeRecorder()
            let state = Self.make(defaults, recorder)
            let sent = recorder.notices
            #expect(sent.isEmpty, "launching with the flag stored false sent \(sent)")
            withExtendedLifetime(state) {}
        }
    }

    @Test("Launching with the key unset sends what the shipped default gives: one turned-on notice when it is on, none when it is off")
    func launchWithTheKeyUnset() {
        withTestDefaults("GhosttyEngineFlagNotice.LaunchUnset") { defaults in
            let recorder = EngineNoticeRecorder()
            let state = Self.make(defaults, recorder)
            let sent = recorder.notices
            let expected: [TerminalEngineNotice] = AppState.ghosttyTerminalEngineDefault ? [Self.turnedOn] : []
            #expect(sent == expected, "launching with the key unset sent \(sent)")
            withExtendedLifetime(state) {}
        }
    }

    /// The flag starts stored off, so the write outside the app is a real
    /// change and launch sent nothing before it.
    @Test("A real change sends one notice, whether it is written outside the app or through the toggle")
    func aRealChangeSendsOneNotice() async {
        await withTestDefaults("GhosttyEngineFlagNotice.Change") { defaults in
            defaults.set(false, forKey: Self.key)
            let recorder = EngineNoticeRecorder()
            let state = Self.make(defaults, recorder)

            // As `defaults write` would: the app hears of it only through the
            // key-value observation.
            defaults.set(true, forKey: Self.key)
            await EngineTestSupport.waitUntil(
                "the notice for a write made outside the toggle",
                observed: { "sent \(recorder.notices)" }
            ) {
                !recorder.notices.isEmpty
            }
            let afterOutside = recorder.notices
            #expect(afterOutside == [Self.turnedOn], "turning the flag on outside the toggle sent \(afterOutside)")

            // The setter refreshes the mirror itself and the observation
            // refreshes it again, so only the first may send.
            state.ghosttyTerminalEngineSetting = false
            let afterToggle = recorder.notices
            #expect(afterToggle == [Self.turnedOn, Self.turnedOff], "turning the toggle off sent \(afterToggle)")
        }
    }

    @Test("A write of the value the flag already holds sends no notice")
    func aWriteOfTheSameValueSendsNone() async {
        await withTestDefaults("GhosttyEngineFlagNotice.SameValue") { defaults in
            defaults.set(true, forKey: Self.key)
            let recorder = EngineNoticeRecorder()
            let state = Self.make(defaults, recorder)

            defaults.set(true, forKey: Self.key)
            state.ghosttyTerminalEngineSetting = true
            // The observation reports writes in order, so once the later real
            // change has been heard, both writes before it have been too.
            defaults.set(false, forKey: Self.key)
            await EngineTestSupport.waitUntil(
                "the notice for the real change after the same-value writes",
                observed: { "sent \(recorder.notices)" }
            ) {
                recorder.notices.contains(Self.turnedOff)
            }
            let sent = recorder.notices
            #expect(sent == [Self.turnedOn, Self.turnedOff], "writing the value the flag already held sent \(sent)")
        }
    }
}

/// Collects what `AppState` sends to its `onEngineNotice` sink.
@MainActor
private final class EngineNoticeRecorder {
    private(set) var notices: [TerminalEngineNotice] = []

    func record(_ notice: TerminalEngineNotice) {
        notices.append(notice)
    }
}
