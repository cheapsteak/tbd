import Foundation
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

/// `RemoteProviderStatusPresentation.issueSummary(_:now:)` — a provider's
/// error, bounded, with the age of its last good snapshot.
@Suite("RemoteProviderStatusPresentation.issueSummary")
struct RemoteProviderStatusPresentationTests {

    private func status(
        name: String = "acme", health: ProviderHealth,
        errorMessage: String? = nil, lastSuccess: Date? = nil
    ) -> RemoteProviderStatus {
        RemoteProviderStatus(
            config: RemoteProviderConfig(name: name, exec: "/usr/bin/true"),
            describe: nil, health: health,
            errorMessage: errorMessage, remediationLabel: nil, remediationCommand: nil,
            lastSuccessfulSnapshotAt: lastSuccess)
    }

    @Test func providerIssueSummaryShowsBoundedErrorAndLastGoodAge() {
        let now = Date(timeIntervalSince1970: 10_000)
        let provider = status(
            health: .stale, errorMessage: "Inventory response was truncated",
            lastSuccess: now.addingTimeInterval(-2 * 3600))
        #expect(RemoteProviderStatusPresentation.issueSummary(provider, now: now)
                == "Inventory response was truncated · last good 2h ago")
    }

    @Test func providerIssueSummarySaysWhenNoSuccessfulSnapshotExists() {
        let provider = status(health: .error, errorMessage: "Provider failed")
        #expect(RemoteProviderStatusPresentation.issueSummary(provider)
                == "Provider failed · no successful snapshot yet")
    }

    @Test func providerIssueSummaryIsNilWhenHealthy() {
        #expect(RemoteProviderStatusPresentation.issueSummary(status(health: .ok)) == nil)
    }
}
