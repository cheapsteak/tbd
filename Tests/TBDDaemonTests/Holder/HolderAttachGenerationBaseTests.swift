import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Attach generations do not repeat across daemon processes, and say on their
/// face that they do not.
///
/// An `attach.ready` or a `pane.detach` names its attach by generation alone,
/// and one sent to a daemon can reach its successor — a detach in flight
/// across a restart, or a handback the app resends after reconnecting. A
/// successor counting from the same place could have minted that number for a
/// different claim, and would hand that claim back while its panel is still
/// reading: two readers on one pty. So every registry starts from a random
/// base in [2^32, 2^48 − 2^32): at or above
/// `AttachRequestResult.uniqueGenerationFloor`, which a daemon counting from 1
/// never reaches, and far enough under 2^48 that no run can count past it.
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
        #expect(predecessor >= AttachRequestResult.uniqueGenerationFloor)
        #expect(successor >= AttachRequestResult.uniqueGenerationFloor)
    }

    /// Every default base is at or above the shared floor — so even the first
    /// generation a randomizing daemon mints is recognisably its — and leaves
    /// 2^32 attaches of room before 2^48, more than any daemon process will
    /// ever mint. Sampled, because the base is random: a range check that only
    /// one draw passed would prove little.
    @Test func everyDefaultBaseClearsTheFloorAndLeavesRoomToCount() async {
        let uniqueFloor = AttachRequestResult.uniqueGenerationFloor
        let limit = HolderRegistry.attachGenerationBaseLimit
        #expect(uniqueFloor == 1 << 32)
        #expect(limit == 1 << 48)

        var bases = (0..<1_000).map { _ in HolderRegistry.randomAttachGenerationBase() }
        bases.append(await Self.registry().lastMintedAttachGeneration)
        for base in bases {
            #expect(base >= uniqueFloor, "a default base \(base) fell below the unique-generation floor")
            #expect(base + uniqueFloor <= limit, """
                a default base \(base) leaves fewer than 2^32 attaches before 2^48
                """)
        }
        // And the room really is the bound: four billion attaches past the
        // highest possible base is still exact as a `Double` (below 2^53).
        let ceiling = limit
        #expect(UInt64(exactly: Double(ceiling)) == ceiling)
    }

    /// The injectable base is honored, including values below the floor —
    /// tests pass 0 so they can name the generations an attach mints.
    @Test func anInjectedBaseIsHonored() async {
        #expect(await Self.registry(base: 41).lastMintedAttachGeneration == 41)
        #expect(await Self.registry(base: 0).lastMintedAttachGeneration == 0)
    }
}
