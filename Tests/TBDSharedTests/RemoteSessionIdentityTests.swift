import Testing
import Foundation
@testable import TBDShared

/// Task 9d (remote worktrees inside repo sections). Covers the deterministic
/// UUID derivation that gives every remote mirror row a stable identity for
/// `List(selection:)` tagging.
@Suite("RemoteSessionIdentity")
struct RemoteSessionIdentityTests {
    @Test func sameInputsProduceTheSameID() {
        let a = RemoteSessionIdentity.uuid(provider: "acme", sessionID: "s1")
        let b = RemoteSessionIdentity.uuid(provider: "acme", sessionID: "s1")
        #expect(a == b)
    }

    /// Stability across a simulated daemon/app restart: nothing here is
    /// process-local state (no seeded RNG, no counter) — calling it from a
    /// "fresh" scope must reproduce byte-identical output.
    @Test func stableAcrossSimulatedRestart() {
        func deriveInFreshScope() -> UUID {
            RemoteSessionIdentity.uuid(provider: "acme", sessionID: "s1")
        }
        let beforeRestart = deriveInFreshScope()
        let afterRestart = deriveInFreshScope()
        #expect(beforeRestart == afterRestart)
    }

    @Test func differentSessionIDsProduceDifferentIDs() {
        let a = RemoteSessionIdentity.uuid(provider: "acme", sessionID: "s1")
        let b = RemoteSessionIdentity.uuid(provider: "acme", sessionID: "s2")
        #expect(a != b)
    }

    @Test func differentProvidersProduceDifferentIDs() {
        let a = RemoteSessionIdentity.uuid(provider: "acme", sessionID: "s1")
        let b = RemoteSessionIdentity.uuid(provider: "other", sessionID: "s1")
        #expect(a != b)
    }

    /// Concatenation-collision guard: without a separator, ("ab", "c") and
    /// ("a", "bc") would hash identically. The embedded NUL byte between
    /// provider and sessionID prevents this.
    @Test func noConcatenationCollisionAcrossTheProviderSessionBoundary() {
        let a = RemoteSessionIdentity.uuid(provider: "ab", sessionID: "c")
        let b = RemoteSessionIdentity.uuid(provider: "a", sessionID: "bc")
        #expect(a != b)
    }

    @Test func producesAWellFormedVersion5VariantUUID() {
        let id = RemoteSessionIdentity.uuid(provider: "acme", sessionID: "s1")
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        #expect((bytes[6] & 0xF0) == 0x50, "version nibble must be 5")
        #expect((bytes[8] & 0xC0) == 0x80, "variant bits must be the RFC4122 pattern")
    }
}
