import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "gcSettings")

/// The opt-in orphan-GC collectors that ship off and are each read on top of
/// the `gcEnabled` master switch. Each one has a CLI switch under `tbd gc`
/// and a Settings → Cleanup toggle; both write the same `config.setGC…Enabled`
/// RPC.
enum GCCollector: CaseIterable, Sendable {
    case orphanProcesses
    case profileDirs
    case retainedTranscripts
    case hangStacks

    /// Everything that ties one collector to its state, its config field, its
    /// RPC and its copy. The single per-collector table: the mirror, the
    /// loader, the setter and the Settings row all read it. Main-actor bound
    /// because it carries a key path into main-actor `AppState`.
    @MainActor
    struct Mapping {
        /// The `AppState` mirror the Settings toggle binds to.
        let state: ReferenceWritableKeyPath<AppState, Bool>
        /// The daemon `Config` field the mirror loads from.
        let config: KeyPath<Config, Bool>
        /// The shipped default — the same constant `ConfigRecord.toModel()`
        /// resolves an unset column through, so graduation is one line there.
        let shippedDefault: Bool
        let rpcMethod: String
        let params: @Sendable (Bool) -> any Encodable & Sendable
        /// The Settings toggle label.
        let label: String
        /// What the collector reclaims, in the words of its `tbd gc` abstract.
        let reclaims: String
        /// The rest of the one-line caption under the toggle.
        let effect: String
        /// The `tbd gc` subcommand that reads and writes the same switch.
        let cliCommand: String
    }

    @MainActor var mapping: Mapping {
        switch self {
        case .orphanProcesses:
            Mapping(
                state: \.gcOrphanProcessesEnabled, config: \.gcOrphanProcessesEnabled,
                shippedDefault: Config.gcOrphanProcessesEnabledDefault,
                rpcMethod: RPCMethod.configSetGCOrphanProcessesEnabled,
                params: { ConfigSetGCOrphanProcessesEnabledParams(enabled: $0) },
                label: "Reclaim orphaned processes",
                reclaims: "processes that outlived their worktree",
                effect: "Kills processes still running after their worktree is gone.",
                cliCommand: "tbd gc orphan-processes")
        case .profileDirs:
            Mapping(
                state: \.gcProfileDirsEnabled, config: \.gcProfileDirsEnabled,
                shippedDefault: Config.gcProfileDirsEnabledDefault,
                rpcMethod: RPCMethod.configSetGCProfileDirsEnabled,
                params: { ConfigSetGCProfileDirsEnabledParams(enabled: $0) },
                label: "Reclaim orphaned profile config dirs",
                reclaims: "orphaned model-profile config dirs",
                effect: "Quarantines config dirs left behind by deleted model profiles.",
                cliCommand: "tbd gc profile-dirs")
        case .retainedTranscripts:
            Mapping(
                state: \.gcRetainedTranscriptsEnabled, config: \.gcRetainedTranscriptsEnabled,
                shippedDefault: Config.gcRetainedTranscriptsEnabledDefault,
                rpcMethod: RPCMethod.configSetGCRetainedTranscriptsEnabled,
                params: { ConfigSetGCRetainedTranscriptsParams(enabled: $0) },
                label: "Reclaim unreferenced retained transcripts",
                reclaims: "unreferenced retained transcripts",
                effect: "Deletes retained transcript files nothing references, and expired ones.",
                cliCommand: "tbd gc retained-transcripts")
        case .hangStacks:
            Mapping(
                state: \.gcHangStacksEnabled, config: \.gcHangStacksEnabled,
                shippedDefault: Config.gcHangStacksEnabledDefault,
                rpcMethod: RPCMethod.configSetGCHangStacksEnabled,
                params: { ConfigSetGCHangStacksEnabledParams(enabled: $0) },
                label: "Reclaim old hang-stack diagnostics",
                reclaims: "old hang-stack diagnostics",
                effect: "Keeps hang-stack diagnostics to 14 days and 1000 files.",
                cliCommand: "tbd gc hang-stacks")
        }
    }

    @MainActor var label: String { mapping.label }

    /// Hover text, worded like the matching `tbd gc` abstract and naming the
    /// subcommand that flips the same switch.
    @MainActor var help: String {
        let m = mapping
        return "Reclaims \(m.reclaims) (default \(m.shippedDefault ? "on" : "off")). "
            + "Same switch as \(m.cliCommand)."
    }

    /// The one-line caption shown under the toggle.
    @MainActor var caption: String {
        let m = mapping
        return "\(m.effect) \(m.shippedDefault ? "On" : "Off") by default."
    }
}

extension AppState {
    /// The local mirror of one collector's switch.
    func gcCollectorEnabled(_ collector: GCCollector) -> Bool {
        self[keyPath: collector.mapping.state]
    }

    /// Load GC config from the daemon with one `config.get`: the four
    /// collector mirrors, and the hang-stack write-time cap. Called on launch
    /// and whenever a config-change delta arrives — the same two call sites as
    /// `loadSupervisionConfig()`. Every `config.setGC…Enabled` handler
    /// broadcasts that delta, so a toggle flipped here or from the CLI reaches
    /// both. Silent on failure: the toggles keep their last value, and the cap
    /// stays at whatever it was, which on launch is OFF — the keep-biased
    /// direction, and the same answer the unset column gives.
    func loadGCConfig() async {
        guard let config = await fetchConfig() else { return }
        applyGCCollectorConfig(config)
        // Mirror the hang-stack reclaimer gate into `HangStackWriter`'s
        // write-time cap (docs/specs/2026-08-29-hang-stack-reclaimer-design.md).
        // `retentionArmed(for:)` reads `gcHangStacksEnabled` **on top of**
        // `gcEnabled` exactly as the daemon's own phase does: the master switch
        // has to master both halves of one policy, or turning GC off in
        // Settings would stop the sweep while the app kept deleting.
        HangStackWriter.shared.setRetentionEnabled(HangStackWriter.retentionArmed(for: config))
    }

    func applyGCCollectorConfig(_ config: Config) {
        for collector in GCCollector.allCases {
            let mapping = collector.mapping
            let value = config[keyPath: mapping.config]
            if self[keyPath: mapping.state] != value {
                self[keyPath: mapping.state] = value
            }
        }
    }

    /// Persist one collector's switch through the same RPC its `tbd gc`
    /// subcommand uses. A failure leaves the mirror unchanged and alerts. The
    /// daemon's config-change broadcast then reloads `loadGCConfig()`, which
    /// is what re-arms the hang-stack write-time cap.
    func setGCCollectorEnabled(_ collector: GCCollector, _ enabled: Bool) async {
        do {
            try await gcCollectorSetter(collector, enabled)
            self[keyPath: collector.mapping.state] = enabled
        } catch {
            logger.error("Failed to set GC collector \(String(describing: collector), privacy: .public): \(error, privacy: .public)")
            showAlert("Failed to update GC setting: \(error.localizedDescription)", isError: true)
        }
    }
}
