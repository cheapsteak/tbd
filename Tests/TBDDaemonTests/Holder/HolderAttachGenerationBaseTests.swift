import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Attach generations do not repeat across daemon processes.
///
/// An `attach.ready` or a `pane.detach` names its attach by generation alone,
/// and one sent to a daemon can reach its successor — a detach in flight
/// across a restart, or a handback the app resends after reconnecting. A
/// successor counting from the same place could have minted that number for a
/// different claim, and would hand that claim back while its panel is still
/// reading: two readers on one pty. So every registry starts from a random
/// base, kept below 2^48.
///
/// Tier 1: the base is read before anything is minted, so no holder is needed.
/// That minting continues from the base is asserted where a real attach mints
/// one (`HolderAttachOnDemandAdoptionLiveTests`).
@Suite("Every holder registry starts its attach generations at its own random base")
struct HolderAttachGenerationBaseTests {

    private static func registry(base: UInt64? = nil) -> HolderRegistry {
        let owner = HolderOwnerToken(rawValue: "acme-installation")
        let environment = ["TBD_HOME": "/nonexistent/acme-tbd-home"]
        guard let base else {
            return HolderRegistry(owner: owner, environment: environment, listTerminals: { [] })
        }
        return HolderRegistry(
            owner: owner, environment: environment, listTerminals: { [] },
            attachGenerationBase: base)
    }

    /// Two daemons in succession are two registries built with the default.
    /// A shared starting point — zero, say — is what lets a message meant for
    /// one match a claim in the other.
    @Test func twoRegistriesBuiltWithTheDefaultDoNotShareAStartingGeneration() async {
        let predecessor = await Self.registry().lastMintedAttachGeneration
        let successor = await Self.registry().lastMintedAttachGeneration

        #expect(predecessor != successor, """
            two registries started their attach generations at the same value \(predecessor), \
            so a detach meant for one daemon can take back the other's claim
            """)
        #expect(predecessor < HolderRegistry.attachGenerationBaseLimit)
        #expect(successor < HolderRegistry.attachGenerationBaseLimit)
    }

    @Test func anInjectedBaseIsHonored() async {
        #expect(await Self.registry(base: 41).lastMintedAttachGeneration == 41)
        #expect(await Self.registry(base: 0).lastMintedAttachGeneration == 0)
    }

    /// The bound itself: 2^48 leaves room to count without wrapping and keeps
    /// every generation exact as a `Double` (below 2^53).
    @Test func theBaseLimitKeepsGenerationsExactAsADouble() {
        let limit = HolderRegistry.attachGenerationBaseLimit
        #expect(limit == 1 << 48)
        let ceiling = limit - 1 + 1_000_000_000
        #expect(UInt64(exactly: Double(ceiling)) == ceiling)
    }
}
