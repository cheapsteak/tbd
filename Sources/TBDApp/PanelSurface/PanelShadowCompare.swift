import Foundation
import TBDShared

/// Spec C §11.3 — migration-validation-only shadow comparator. Pure: no I/O,
/// no daemon calls, no mutation. Compares a normalized view of the app's
/// current legacy-derived conversion against the daemon's imported surface
/// and returns human-readable mismatch strings; the caller (`AppState`'s
/// shadow-compare trigger) logs them and does nothing else with them — this
/// must never gate, block, or influence the import itself, and must never
/// implement Approach A's broadcast-command/parked-ACK protocol.
enum PanelShadowCompare {
    /// Normalizes both sides and compares primary/label/layout per matched
    /// tab. `revision` is deliberately excluded — the daemon copy may have
    /// advanced since import (later applies, a later launch) and that is not
    /// a divergence this diagnostic cares about.
    ///
    /// The local and daemon conversions come from two INDEPENDENT calls to
    /// `LegacySurfaceImporter.convert` (the daemon's at import time, this
    /// diagnostic's just now) — each mints its own fresh random IDs for
    /// promoted-terminal-tab surfaces and note-panel slots
    /// (`LegacySurfaceImporter.swift`'s two `makeID()` call sites). Those IDs
    /// can never coincide across the two calls, so both tab-matching and
    /// layout comparison key off STABLE content instead of minted identity:
    /// - a tab is matched by its primary's `terminalID` when the primary is
    ///   a terminal (true for both plain terminal tabs, whose surface `id`
    ///   already IS the stable legacy tabID, and promoted tabs, whose surface
    ///   `id` is minted) — terminalID is the one thing guaranteed stable
    ///   there; otherwise by surface `id`, which is always the legacy tabID
    ///   for every non-promoted tab (promotion only ever produces
    ///   terminal-primary tabs).
    /// - layouts compare via `normalize(_:)`, which drops every `PanelSlot`
    ///   and `SplitNode` id and compares structure/direction/ratios/content
    ///   only — so a minted note-panel slot id never flags, while a real
    ///   content divergence (path changed, a viewer vanished, wrong split
    ///   shape) still does.
    static func mismatches(
        local: LegacySurfaceImporter.Conversion, daemon: PanelGetResult
    ) -> [String] {
        var results: [String] = []
        let localByKey = Dictionary(local.surfaces.map { (tabKey($0), $0) }, uniquingKeysWith: { first, _ in first })
        let daemonByKey = Dictionary(daemon.tabs.map { (tabKey($0), $0) }, uniquingKeysWith: { first, _ in first })

        let localKeys = localByKey.keys.sorted { $0.uuidString < $1.uuidString }
        let daemonKeys = daemonByKey.keys.sorted { $0.uuidString < $1.uuidString }

        for key in localKeys where daemonByKey[key] == nil {
            results.append("tab \(key): present in local conversion, missing from daemon surface")
        }
        for key in daemonKeys where localByKey[key] == nil {
            results.append("tab \(key): present in daemon surface, missing from local conversion")
        }

        for key in localKeys {
            guard let localTab = localByKey[key], let daemonTab = daemonByKey[key] else { continue }
            if localTab.primary != daemonTab.primary {
                results.append("tab \(key): primary mismatch (local \(localTab.primary), daemon \(daemonTab.primary))")
            }
            if localTab.label != daemonTab.label {
                results.append(
                    "tab \(key): label mismatch (local \(localTab.label ?? "nil"), daemon \(daemonTab.label ?? "nil"))")
            }
            if normalize(localTab.layout) != normalize(daemonTab.layout) {
                results.append("tab \(key): layout mismatch")
            }
        }
        return results
    }

    /// Stable cross-import matching key: terminalID for any terminal-primary
    /// tab (covers both plain and promoted tabs uniformly), else the surface
    /// id (the legacy tabID — never minted for a non-terminal-primary tab).
    private static func tabKey(_ surface: WorkspaceTabSurface) -> UUID {
        if case .terminal(let terminalID) = surface.primary {
            return terminalID
        }
        return surface.id
    }

    /// Structural shape of a layout tree with every minted identity (split
    /// id, panel slot id) dropped — only content, position, and ratios
    /// remain, which is exactly what §11.3 means by "normalize away cosmetic
    /// differences."
    private indirect enum NormalizedNode: Equatable {
        case primary
        case panel(PanelContent)
        case split(direction: SplitDirection, children: [NormalizedNode], ratios: [Double])
    }

    private static func normalize(_ node: PanelLayoutNode) -> NormalizedNode {
        switch node {
        case .primary:
            return .primary
        case .panel(let slot):
            return .panel(slot.content)
        case .split(let split):
            return .split(direction: split.direction, children: split.children.map(normalize), ratios: split.ratios)
        }
    }
}
