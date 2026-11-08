import AppKit
import Foundation
import Testing
@testable import TBDApp
import TBDGhosttyTerminal
import TBDShared
import TestSupport

/// The `useGhosttyTerminalEngine` flag and the factory's choice of engine.
///
/// The flag is a three-state UserDefaults read: unset follows
/// `AppState.ghosttyTerminalEngineDefault`, and an explicit `false` or `true`
/// holds against any change to that constant. Off, every terminal is SwiftTerm;
/// on, holder panels and local PTYs ask for libghostty and tmux panels stay on
/// SwiftTerm. Both branches are checked, and the build itself where this
/// machine has the Metal device libghostty needs. Every store is an isolated
/// suite. Design: `docs/specs/2026-11-07-libghostty-terminal-engine-design.md`.
@MainActor
@Suite("Terminal engine factory", .fastPassBounded)
struct TerminalEngineFactoryTests {
    private static let key = AppState.useGhosttyTerminalEngineKey
    private static let hosts: [TerminalEngineHost] = [.panel(.holder), .panel(.tmux), .localPTY]

    // MARK: - Flag off

    @Test("With the flag unset or false, every host asks for and gets SwiftTerm, override or not")
    func flagOffBuildsSwiftTerm() {
        withTestDefaults("TerminalEngineFactory.FlagOff") { defaults in
            let appearance = AppearanceSettings(defaults: defaults)
            for stored in [nil, false] as [Bool?] {
                if let stored {
                    defaults.set(stored, forKey: Self.key)
                } else {
                    defaults.removeObject(forKey: Self.key)
                }
                let state = AppState(userDefaults: defaults)
                #expect(!state.ghosttyTerminalEngineEnabled, "stored \(String(describing: stored)) read as on")

                for host in Self.hosts {
                    let kind = TerminalEngineFactory.requestedKind(
                        flagEnabled: state.ghosttyTerminalEngineEnabled, host: host)
                    #expect(kind == .swiftTerm, "\(host) asked for \(kind) with the flag off")
                    let engine = Self.make(kind, appearance: appearance)
                    #expect(engine.kind == .swiftTerm)
                }
                // A switch's override counts only while the flag is on.
                let overridden = TerminalEngineFactory.requestedKind(
                    flagEnabled: state.ghosttyTerminalEngineEnabled, host: .panel(.holder), override: .ghostty)
                #expect(overridden == .swiftTerm, "an override reached libghostty with the flag off")
            }
        }
    }

    // MARK: - Flag on

    /// The routing on its own, which needs no Metal device.
    @Test("With the flag on, holder panels and local PTYs ask for libghostty, tmux panels for SwiftTerm, and an override wins on a holder panel")
    func flagOnAsksForGhosttyOnlyWhereAllowed() {
        withTestDefaults("TerminalEngineFactory.FlagOnRouting") { defaults in
            defaults.set(true, forKey: Self.key)
            let state = AppState(userDefaults: defaults)
            #expect(state.ghosttyTerminalEngineEnabled)
            let enabled = state.ghosttyTerminalEngineEnabled

            #expect(TerminalEngineFactory.requestedKind(flagEnabled: enabled, host: .panel(.holder)) == .ghostty)
            #expect(TerminalEngineFactory.requestedKind(flagEnabled: enabled, host: .localPTY) == .ghostty)
            #expect(TerminalEngineFactory.requestedKind(flagEnabled: enabled, host: .panel(.tmux)) == .swiftTerm)
            #expect(TerminalEngineFactory.requestedKind(
                flagEnabled: enabled, host: .panel(.holder), override: .swiftTerm) == .swiftTerm)
            #expect(TerminalEngineFactory.requestedKind(
                flagEnabled: enabled, host: .panel(.tmux), override: .ghostty) == .swiftTerm,
                "an override moved a tmux panel off SwiftTerm")
        }
    }

    @Test("With the flag on, a holder panel and a local PTY are built on libghostty with no fallback, and a tmux panel on SwiftTerm",
          .enabled(if: EngineTestSupport.canBuildGhostty, EngineTestSupport.noMetalDevice))
    func flagOnBuildsGhostty() {
        withTestDefaults("TerminalEngineFactory.FlagOn") { defaults in
            defaults.set(true, forKey: Self.key)
            let state = AppState(userDefaults: defaults)
            let appearance = AppearanceSettings(defaults: defaults)
            var fallbacks: [String] = []

            for host in Self.hosts {
                let kind = TerminalEngineFactory.requestedKind(
                    flagEnabled: state.ghosttyTerminalEngineEnabled, host: host)
                let engine = TerminalEngineFactory.make(
                    kind: kind,
                    font: appearance.font,
                    appearance: appearance,
                    configuration: TerminalEngineConfiguration(),
                    onFallback: { fallbacks.append($1) })
                let expected: TerminalEngineKind = host == .panel(.tmux) ? .swiftTerm : .ghostty
                #expect(engine.kind == expected, "\(host) was built on \(engine.kind)")
                if engine.kind == .ghostty {
                    #expect(engine is GhosttyEngine)
                }
            }
            #expect(fallbacks.isEmpty, "a libghostty build fell back: \(fallbacks)")
        }
    }

    // MARK: - Fallback

    @Test("A libghostty engine that fails to start yields SwiftTerm and one fallback that says why")
    func initFailureFallsBackToSwiftTerm() {
        withTestDefaults("TerminalEngineFactory.Fallback") { defaults in
            let appearance = AppearanceSettings(defaults: defaults)
            let attempts = MakerAttempts()
            var fallbacks: [(requested: TerminalEngineKind, reason: String)] = []

            let engine = TerminalEngineFactory.make(
                kind: .ghostty,
                font: appearance.font,
                appearance: appearance,
                configuration: TerminalEngineConfiguration(),
                makeGhostty: { _, _, _ in
                    attempts.count += 1
                    throw GhosttyError.metalUnavailable
                },
                onFallback: { fallbacks.append((requested: $0, reason: $1)) })

            #expect(attempts.count == 1, "the libghostty maker ran \(attempts.count) times")
            #expect(engine.kind == .swiftTerm)
            #expect(engine is SwiftTermEngine)
            #expect(fallbacks.count == 1)
            #expect(fallbacks.first?.requested == .ghostty)
            #expect(fallbacks.first?.reason == String(describing: GhosttyError.metalUnavailable),
                    "the fallback lost the error's own words: \(fallbacks.first?.reason ?? "none")")
            #expect(fallbacks.first?.reason.contains("Metal") == true)
        }
    }

    // MARK: - Three states

    @Test("An unset key reads the shipped default, which is off, and reading it writes nothing")
    func unsetFlagFollowsDefault() {
        withTestDefaults("TerminalEngineFactory.Unset") { defaults in
            #expect(defaults.object(forKey: Self.key) == nil)
            #expect(AppState.ghosttyTerminalEngineDefault == false, "the experiment must ship off")
            #expect(AppState.ghosttyTerminalEngineEnabled(defaults: defaults) == AppState.ghosttyTerminalEngineDefault)
            #expect(AppState(userDefaults: defaults).ghosttyTerminalEngineEnabled == AppState.ghosttyTerminalEngineDefault)
            // Unset follows whatever the default is.
            #expect(AppState.ghosttyTerminalEngineEnabled(defaults: defaults, shippedDefault: true))
            #expect(!AppState.ghosttyTerminalEngineEnabled(defaults: defaults, shippedDefault: false))
            #expect(defaults.object(forKey: Self.key) == nil, "reading the flag wrote it")
        }
    }

    @Test("An explicit false holds when the default turns on, an explicit true holds when it is off, and unset follows it")
    func explicitFalseSurvivesADefaultChange() {
        withTestDefaults("TerminalEngineFactory.Explicit") { defaults in
            defaults.set(false, forKey: Self.key)
            #expect(!AppState.ghosttyTerminalEngineEnabled(defaults: defaults, shippedDefault: true),
                    "an explicit false followed a default of true")
            #expect(!AppState.ghosttyTerminalEngineEnabled(defaults: defaults, shippedDefault: false))

            defaults.set(true, forKey: Self.key)
            #expect(AppState.ghosttyTerminalEngineEnabled(defaults: defaults, shippedDefault: false),
                    "an explicit true followed a default of false")
            #expect(AppState(userDefaults: defaults).ghosttyTerminalEngineEnabled)

            // The decision on its own: three stored states, two defaults.
            #expect(AppState.ghosttyTerminalEngineEnabled(stored: nil, shippedDefault: true))
            #expect(!AppState.ghosttyTerminalEngineEnabled(stored: nil, shippedDefault: false))
            #expect(!AppState.ghosttyTerminalEngineEnabled(stored: false, shippedDefault: true))
            #expect(AppState.ghosttyTerminalEngineEnabled(stored: true, shippedDefault: false))
        }
    }

    // MARK: - Local PTY focus

    /// A remote attach pane built on libghostty joins the focus registry as a
    /// SwiftTerm one does: the registration chains onto the engine's own
    /// window hook rather than replacing it, and unregistering puts that hook
    /// back. Without the registry, the pane could not give focus back when the
    /// log fallback hides it.
    @Test("A libghostty local PTY view registers for remote attach focus, chained after the engine's own window hook",
          .enabled(if: EngineTestSupport.canBuildGhostty, EngineTestSupport.noMetalDevice))
    func ghosttyLocalPTYViewJoinsTheRemoteFocusRegistry() throws {
        let fixture = EngineUnderTest(kind: .ghostty, label: "TerminalEngineFactory.RemoteFocus")
        defer { fixture.tearDown() }
        let state = AppState(userDefaults: fixture.suite.defaults)
        let selection = RemoteSessionSelection(provider: "acme", sessionID: "s-1")
        let view = try #require(fixture.engine.view as? any RemoteFocusTerminalView,
                                "the libghostty view cannot join the remote focus registry")
        let ghosttyView = try #require(fixture.engine.view as? GhosttyTerminalView)

        state.registerRemoteTerminalView(view, for: selection)
        #expect(state.remoteTerminalFocusTargets[selection]?.view === ghosttyView)
        ghosttyView.onMovedToWindow?()
        #expect(fixture.recorder.calls == ["movedToWindow"],
                "the registration replaced the engine's window hook: \(fixture.recorder.calls)")

        state.unregisterRemoteTerminalView(view, for: selection)
        #expect(state.remoteTerminalFocusTargets[selection] == nil)
        fixture.recorder.reset()
        ghosttyView.onMovedToWindow?()
        #expect(fixture.recorder.calls == ["movedToWindow"],
                "unregistering did not put the engine's window hook back: \(fixture.recorder.calls)")
    }

    // MARK: - Helpers

    private static func make(_ kind: TerminalEngineKind, appearance: AppearanceSettings) -> any TerminalEngine {
        TerminalEngineFactory.make(
            kind: kind,
            font: appearance.font,
            appearance: appearance,
            configuration: TerminalEngineConfiguration())
    }
}

/// How many times an injected maker ran. A main-actor class, so the maker,
/// a main-actor closure, counts without capturing a mutable local.
@MainActor
private final class MakerAttempts {
    var count = 0
}
