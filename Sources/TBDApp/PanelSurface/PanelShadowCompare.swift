import Foundation
import TBDShared

/// Spec C §11.3 — migration-validation-only shadow comparator. Pure: no I/O,
/// no daemon calls, no mutation. Compares a normalized view of the app's
/// current legacy-derived conversion against the daemon's imported surface
/// and returns human-readable mismatch strings; the caller (`AppState`'s
/// shadow-compare trigger) logs them and does nothing else with them — this
/// must never gate, block, or influence the import itself, and must never
/// implement Approach A's broadcast-command/parked-ACK protocol.
public enum PanelShadowCompare {
    /// Normalizes both sides (sorts tabs by id so key/array ordering never
    /// flags) and compares id/primary/label/layout equality per tab.
    /// `revision` is deliberately excluded — the daemon copy may have
    /// advanced since import (later applies, a later launch) and that is not
    /// a divergence this diagnostic cares about.
    public static func mismatches(
        local: LegacySurfaceImporter.Conversion, daemon: PanelGetResult
    ) -> [String] {
        var results: [String] = []
        let localByID = Dictionary(uniqueKeysWithValues: local.surfaces.map { ($0.id, $0) })
        let daemonByID = Dictionary(uniqueKeysWithValues: daemon.tabs.map { ($0.id, $0) })

        let localIDs = localByID.keys.sorted { $0.uuidString < $1.uuidString }
        let daemonIDs = daemonByID.keys.sorted { $0.uuidString < $1.uuidString }

        for id in localIDs where daemonByID[id] == nil {
            results.append("tab \(id): present in local conversion, missing from daemon surface")
        }
        for id in daemonIDs where localByID[id] == nil {
            results.append("tab \(id): present in daemon surface, missing from local conversion")
        }

        for id in localIDs {
            guard let localTab = localByID[id], let daemonTab = daemonByID[id] else { continue }
            if localTab.primary != daemonTab.primary {
                results.append("tab \(id): primary mismatch (local \(localTab.primary), daemon \(daemonTab.primary))")
            }
            if localTab.label != daemonTab.label {
                results.append(
                    "tab \(id): label mismatch (local \(localTab.label ?? "nil"), daemon \(daemonTab.label ?? "nil"))")
            }
            if localTab.layout != daemonTab.layout {
                results.append("tab \(id): layout mismatch")
            }
        }
        return results
    }
}
