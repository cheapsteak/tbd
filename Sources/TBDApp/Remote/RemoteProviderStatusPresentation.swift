import Foundation
import TBDShared

/// Compact, testable status copy shared by the provider header and detail
/// pane. `RemoteProviderManager` already bounds `errorMessage` before it
/// crosses RPC; this composes that message with the last complete inventory
/// age so the UI states what is stale, not merely that something failed.
enum RemoteProviderStatusPresentation {
    nonisolated static func issueSummary(
        _ status: RemoteProviderStatus, now: Date = Date()
    ) -> String? {
        guard status.health != .ok else { return nil }
        let message = status.errorMessage ?? fallback(for: status.health)
        guard let lastSuccess = status.lastSuccessfulSnapshotAt else {
            return "\(message) · no successful snapshot yet"
        }
        let age = ProfileUsagePresentation.ageText(since: lastSuccess, now: now)
        let agePhrase = age == "just now" ? "last good just now" : "last good \(age) ago"
        return "\(message) · \(agePhrase)"
    }

    private nonisolated static func fallback(for health: ProviderHealth) -> String {
        switch health {
        case .ok: return "Provider healthy"
        case .stale: return "Inventory unavailable"
        case .needsAuth: return "Authentication needed"
        case .error: return "Provider error"
        }
    }
}
