import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "gcSettings")

/// The opt-in orphan-GC collectors that ship off and are each read on top of
/// the `gcEnabled` master switch. Each one has a CLI switch under `tbd gc`
/// and a Settings toggle; both write the same `config.setGC…Enabled` RPC.
enum GCCollector: CaseIterable, Sendable {
    case orphanProcesses
    case profileDirs
    case retainedTranscripts
    case hangStacks

    /// The Settings toggle label.
    var label: String {
        switch self {
        case .orphanProcesses: "Reclaim orphaned processes"
        case .profileDirs: "Reclaim orphaned profile config dirs"
        case .retainedTranscripts: "Reclaim unreferenced retained transcripts"
        case .hangStacks: "Reclaim old hang-stack diagnostics"
        }
    }

    /// Hover text — the same abstract the matching `tbd gc` subcommand shows.
    var help: String {
        switch self {
        case .orphanProcesses: "Reclaiming processes that outlived their worktree (default off)"
        case .profileDirs: "Reclaiming orphaned model-profile config dirs (default off)"
        case .retainedTranscripts: "Reclaiming unreferenced retained transcripts (default off)"
        case .hangStacks: "Reclaiming old hang-stack diagnostics (default off)"
        }
    }

    /// The one-line caption shown under the toggle.
    var caption: String {
        switch self {
        case .orphanProcesses:
            "Kills processes still running after their worktree is gone. Off by default."
        case .profileDirs:
            "Quarantines config dirs left behind by deleted model profiles. Off by default."
        case .retainedTranscripts:
            "Deletes retained transcript files nothing references, and expired ones. Off by default."
        case .hangStacks:
            "Keeps hang-stack diagnostics to 14 days and 1000 files. Off by default."
        }
    }

    /// The `tbd gc` subcommand that reads and writes the same switch.
    var cliCommand: String {
        switch self {
        case .orphanProcesses: "tbd gc orphan-processes"
        case .profileDirs: "tbd gc profile-dirs"
        case .retainedTranscripts: "tbd gc retained-transcripts"
        case .hangStacks: "tbd gc hang-stacks"
        }
    }
}

extension AppState {
    /// The local mirror of one collector's switch.
    func gcCollectorEnabled(_ collector: GCCollector) -> Bool {
        switch collector {
        case .orphanProcesses: gcOrphanProcessesEnabled
        case .profileDirs: gcProfileDirsEnabled
        case .retainedTranscripts: gcRetainedTranscriptsEnabled
        case .hangStacks: gcHangStacksEnabled
        }
    }

    private func setGCCollectorMirror(_ collector: GCCollector, _ enabled: Bool) {
        switch collector {
        case .orphanProcesses: gcOrphanProcessesEnabled = enabled
        case .profileDirs: gcProfileDirsEnabled = enabled
        case .retainedTranscripts: gcRetainedTranscriptsEnabled = enabled
        case .hangStacks: gcHangStacksEnabled = enabled
        }
    }

    /// Load the four collector switches from the daemon `Config`. Called on
    /// launch and whenever a config-change delta arrives — the same two call
    /// sites as `loadSupervisionConfig()`. Silent on failure: the toggles keep
    /// their last value until the next successful load.
    func loadGCCollectorConfig() async {
        guard let config = await fetchConfig() else { return }
        applyGCCollectorConfig(config)
    }

    func applyGCCollectorConfig(_ config: Config) {
        for collector in GCCollector.allCases {
            let value: Bool = switch collector {
            case .orphanProcesses: config.gcOrphanProcessesEnabled
            case .profileDirs: config.gcProfileDirsEnabled
            case .retainedTranscripts: config.gcRetainedTranscriptsEnabled
            case .hangStacks: config.gcHangStacksEnabled
            }
            if gcCollectorEnabled(collector) != value {
                setGCCollectorMirror(collector, value)
            }
        }
    }

    /// Persist one collector's switch through the same RPC its `tbd gc`
    /// subcommand uses. A failure leaves the mirror unchanged and alerts.
    /// The hang-stack switch also arms the app's own write-time cap, so after
    /// setting it the cap is re-derived from the daemon's config.
    func setGCCollectorEnabled(_ collector: GCCollector, _ enabled: Bool) async {
        do {
            try await gcCollectorSetter(collector, enabled)
            setGCCollectorMirror(collector, enabled)
        } catch {
            logger.error("Failed to set GC collector \(String(describing: collector), privacy: .public): \(error, privacy: .public)")
            showAlert("Failed to update GC setting: \(error.localizedDescription)", isError: true)
            return
        }
        if collector == .hangStacks {
            await loadHangStackRetentionConfig()
        }
    }
}
