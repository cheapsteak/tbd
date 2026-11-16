import AppKit
import Foundation
import os
import SwiftUI
import TBDShared

/// Where a switch says what it did, beside the factory's engine lines.
let terminalEngineSwitchLog = Logger(subsystem: "com.tbd.app", category: "terminalEngine")

// MARK: - Switch Terminal Engine

/// Switch Terminal Engine: move a live holder terminal to the other engine, to
/// compare the two on the same session, or to put one terminal back on
/// SwiftTerm when libghostty shows a problem in it.
///
/// The switch records the other engine in `AppState.terminalEngineOverrides`
/// (`TerminalPanelRepresentable.Coordinator.switchEngine()`), and nothing
/// else. The override is part of the panel's identity, so SwiftUI rebuilds
/// the panel: the old one's teardown hands the session back as a layout
/// change's does, and the new one attaches on the other engine as any new
/// panel does. Design: `docs/specs/2026-11-07-libghostty-terminal-engine-design.md`.
enum TerminalEngineSwitchCommand {
    static let title = "Switch Terminal Engine"
    /// ⌃⌘E. Unbound elsewhere in this app and not a macOS default, and a
    /// terminal program has no use for a Control-Command chord, so the menu
    /// taking it costs no session a key.
    static var key: KeyEquivalent { "e" }
    static var modifiers: EventModifiers { [.command, .control] }

    /// The command is in the menu only while the experiment is on.
    static func isVisible(experimentEnabled: Bool) -> Bool {
        experimentEnabled
    }

    /// It runs only for a focused holder panel: a tmux panel stays on
    /// SwiftTerm, and a local PTY (remote attach or remote sign-in)
    /// has no daemon session to hand back.
    static func isEnabled(experimentEnabled: Bool, focusedHost: TerminalEngineHost?) -> Bool {
        experimentEnabled && focusedHost == .panel(.holder)
    }
}

/// The small label a terminal tab carries while the experiment is on, naming
/// the engine its panel was built on.
enum TerminalEngineLabel {
    /// Nil, so no label, while the experiment is off or the tab's terminal
    /// has no mounted panel.
    ///
    /// `kind` is read only while the experiment is on. A tab item passes the
    /// observed `AppState.terminalEnginesInUse` read here, so with the flag
    /// off the tab does not depend on that record and a panel mounting
    /// elsewhere does not redraw it.
    static func text(experimentEnabled: Bool, kind: @autoclosure () -> TerminalEngineKind?) -> String? {
        guard experimentEnabled, let kind = kind() else { return nil }
        switch kind {
        case .swiftTerm: return "SwiftTerm"
        case .ghostty: return "libghostty"
        }
    }
}

extension UserDefaults {
    /// The stored `AppState.useGhosttyTerminalEngineKey`, for key-value
    /// observation only (`AppState.ghosttyTerminalEngineFlag`): a defaults
    /// key is observed by a property of the same name, so the name and the
    /// key must stay equal. Reads go through
    /// `AppState.ghosttyTerminalEngineEnabled(defaults:)`.
    @objc dynamic var useGhosttyTerminalEngine: NSNumber? {
        object(forKey: "useGhosttyTerminalEngine") as? NSNumber
    }
}

extension TerminalEngineKind {
    /// The engine a switch moves a terminal built on this one to.
    var other: TerminalEngineKind {
        switch self {
        case .swiftTerm: return .ghostty
        case .ghostty: return .swiftTerm
        }
    }
}

/// What a mounted panel asked the factory for, and the terminal's override
/// then, recorded when the panel is built. The switch reads it to decide what
/// to write: the panel's identity carries the override, so only a change to
/// the override rebuilds it.
struct TerminalEngineBuild: Equatable, Sendable {
    /// The kind the panel asked for. The engine it got differs only when a
    /// libghostty start fell back to SwiftTerm.
    let requested: TerminalEngineKind
    /// `AppState.terminalEngineOverrides` for the terminal, as the panel's
    /// identity read it.
    let override: TerminalEngineKind?
}

/// What Switch Terminal Engine does for a holder panel while the experiment
/// is on.
enum TerminalEngineSwitchPlan: Equatable, Sendable {
    /// Record this override, or remove it when nil. Either one changes the
    /// panel's identity, and the rebuilt panel asks for the other engine.
    case setOverride(TerminalEngineKind?)
    /// libghostty was asked for and did not start, so asking again would
    /// only fall back again.
    case skipFellBack
    /// The override has changed since the panel was built (a second press),
    /// so its rebuild is already on the way.
    case skipRebuildPending
    /// No override both changes the identity and asks for the other engine.
    /// Not reached by any sequence of switches and flag changes; kept so the
    /// plan is total.
    case skipNothingMoves

    /// The plan for a panel built as `build` describes and actually running
    /// on `builtOn`, while the terminal's override is `currentOverride`.
    ///
    /// The target is the other of the engine the panel runs on, never the
    /// other of what the flag and override resolve to now: a terminal opened
    /// while the flag was off runs on SwiftTerm and, once the flag is on,
    /// resolves to libghostty already, and a switch must still move it. The
    /// override written is the target where that changes the identity, and
    /// otherwise none at all where no override asks for the target (an
    /// override of libghostty left from before the flag went off and on).
    static func plan(
        build: TerminalEngineBuild, builtOn: TerminalEngineKind, currentOverride: TerminalEngineKind?
    ) -> TerminalEngineSwitchPlan {
        guard build.requested == builtOn else { return .skipFellBack }
        guard currentOverride == build.override else { return .skipRebuildPending }
        let target = builtOn.other
        for candidate in [target, nil] as [TerminalEngineKind?]
        where candidate != currentOverride
            && TerminalEngineFactory.requestedKind(
                flagEnabled: true, host: .panel(.holder), override: candidate) == target {
            return .setOverride(candidate)
        }
        return .skipNothingMoves
    }
}

/// The engine a mounted panel was built on, and which panel said so.
struct TerminalEngineInUse: Equatable, Sendable {
    let kind: TerminalEngineKind
    /// The writing panel's token, so a predecessor's teardown cannot erase
    /// its successor's entry.
    let owner: UUID
}

/// A mounted panel's Switch Terminal Engine handler.
struct TerminalEngineSwitcher {
    /// The registering panel's token, so a predecessor's teardown cannot
    /// unregister its successor.
    let owner: UUID
    let run: @MainActor () -> Void
}

extension AppState {
    /// The engine a panel for `terminalID` should be built on now: the
    /// switch's override where there is one, else what
    /// `useGhosttyTerminalEngine` gives the panel's transport. A terminal whose
    /// row is not loaded resolves as tmux, as the panel's transport does.
    func terminalEngineKind(for terminalID: UUID) -> TerminalEngineKind {
        let transport = terminals.values.lazy.flatMap { $0 }
            .first(where: { $0.id == terminalID })?.transport ?? .tmux
        return TerminalEngineFactory.requestedKind(
            flagEnabled: ghosttyTerminalEngineEnabled,
            host: .panel(transport),
            override: terminalEngineOverrides[terminalID])
    }

    /// What the tab's engine label names: the engine the terminal's panel was
    /// built on, or nil when no panel for it is mounted.
    func terminalEngineKindInUse(for terminalID: UUID) -> TerminalEngineKind? {
        terminalEnginesInUse[terminalID]?.kind
    }

    /// The engine label the tab for `terminalID` shows, or nil for none.
    /// Reads the observed `ghosttyTerminalEngineFlag`, so the label follows
    /// this AppState's store, and reads the in-use record only while that is
    /// on, so with the flag off no tab observes the record.
    func terminalEngineLabel(for terminalID: UUID) -> String? {
        TerminalEngineLabel.text(
            experimentEnabled: ghosttyTerminalEngineFlag,
            kind: terminalEngineKindInUse(for: terminalID))
    }

    /// Records the engine panel `owner` was built on.
    func noteTerminalEngineInUse(_ kind: TerminalEngineKind, terminalID: UUID, owner: UUID) {
        let entry = TerminalEngineInUse(kind: kind, owner: owner)
        if terminalEnginesInUse[terminalID] != entry {
            terminalEnginesInUse[terminalID] = entry
        }
    }

    /// Forgets the engine panel `owner` recorded, unless a successor panel
    /// has recorded its own since.
    func forgetTerminalEngineInUse(terminalID: UUID, owner: UUID) {
        guard terminalEnginesInUse[terminalID]?.owner == owner else { return }
        terminalEnginesInUse.removeValue(forKey: terminalID)
    }

    func registerTerminalEngineSwitcher(
        for terminalID: UUID, owner: UUID, run: @escaping @MainActor () -> Void
    ) {
        terminalEngineSwitchers[terminalID] = TerminalEngineSwitcher(owner: owner, run: run)
    }

    func unregisterTerminalEngineSwitcher(for terminalID: UUID, owner: UUID) {
        guard terminalEngineSwitchers[terminalID]?.owner == owner else { return }
        terminalEngineSwitchers.removeValue(forKey: terminalID)
    }

    /// Where the terminal with keyboard focus is hosted, or nil when focus is
    /// not in a terminal.
    ///
    /// Reads `focusedTabCloseContext` first for the reason
    /// `resolvedFocusedTabCloseContext()` does: it is the one observable
    /// property that moves when terminal focus does, so a menu item reading
    /// this re-evaluates. The answer itself comes from the first responder.
    func focusedTerminalEngineHost() -> TerminalEngineHost? {
        _ = focusedTabCloseContext
        guard let responder = NSApp.keyWindow?.firstResponder as? NSView else { return nil }
        return terminalEngineHost(ofFocusedView: responder)
    }

    /// The host of a terminal view: a registered panel's transport, or a local
    /// PTY for a registered remote attach or remote sign-in view.
    func terminalEngineHost(ofFocusedView view: NSView) -> TerminalEngineHost? {
        if let terminalID = terminalFocusTargets.first(where: { $0.value.view === view })?.key {
            let transport = terminals.values.lazy.flatMap { $0 }
                .first(where: { $0.id == terminalID })?.transport ?? .tmux
            return .panel(transport)
        }
        if remoteTerminalFocusTargets.values.contains(where: { $0.view === view }) {
            return .localPTY
        }
        return nil
    }

    /// Whether Switch Terminal Engine can run now. Reads the observed
    /// `ghosttyTerminalEngineFlag`, so the menu item re-evaluates when the
    /// flag changes.
    var canSwitchFocusedTerminalEngine: Bool {
        TerminalEngineSwitchCommand.isEnabled(
            experimentEnabled: ghosttyTerminalEngineFlag,
            focusedHost: focusedTerminalEngineHost())
    }

    /// Switches the focused holder terminal to the other engine. Re-resolved
    /// from the first responder, so a stale menu state cannot switch the
    /// wrong terminal.
    func switchFocusedTerminalEngine() {
        guard canSwitchFocusedTerminalEngine,
              let responder = NSApp.keyWindow?.firstResponder as? NSView,
              let terminalID = terminalFocusTargets.first(where: { $0.value.view === responder })?.key
        else { return }
        switchTerminalEngine(terminalID: terminalID)
    }

    /// Runs the mounted panel's switch for `terminalID`, if it has one.
    func switchTerminalEngine(terminalID: UUID) {
        guard let switcher = terminalEngineSwitchers[terminalID] else { return }
        switcher.run()
    }
}
