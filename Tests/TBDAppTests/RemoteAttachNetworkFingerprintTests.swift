import Foundation
import Network
import Testing
@testable import TBDApp

// Tier 1: pure value types, no network, no clock, no AppState.

/// `RemoteAttachNetworkFingerprint` and `RemoteAttachNetworkChangeDetector` —
/// the reduction of an `NWPath` update and the rule deciding whether it is a
/// change worth re-attaching for (#884).
///
/// Fingerprints are constructed through the test seam rather than from an
/// `NWPath`, which cannot be built outside the Network framework. That is not
/// a weakening: the production `init(path:)` only copies three fields across,
/// and every rule under test is a rule about the fields.
@Suite("Remote attach network fingerprint")
struct RemoteAttachNetworkFingerprintTests {
    private static func fingerprint(
        _ status: NWPath.Status = .satisfied,
        interfaces: [String] = ["en0"],
        gateways: [String] = ["192.0.2.1"]
    ) -> RemoteAttachNetworkFingerprint {
        RemoteAttachNetworkFingerprint(status: status, interfaceNames: interfaces, gateways: gateways)
    }

    // MARK: - The fingerprint itself

    /// Reddens if the fingerprint stops being structurally `Equatable` — which
    /// is the whole of what the detector below compares. What it checks is
    /// exactly that: two fingerprints built from the same status, interface
    /// list and gateway list are equal. The deliberate exclusion of the cost
    /// and constrained flags is structural rather than asserted — the type has
    /// no such field, so nothing about them can be exercised through this seam
    /// without fabricating an `NWPath`.
    @Test func identicalFingerprintsAreEqual() {
        #expect(
            Self.fingerprint(.satisfied, interfaces: ["en0", "utun4"], gateways: ["192.0.2.1"])
                == Self.fingerprint(.satisfied, interfaces: ["en0", "utun4"], gateways: ["192.0.2.1"]))
    }

    /// The log line is the only after-the-fact explanation of an unnecessary
    /// restart, so it has to name all three fields.
    @Test func descriptionNamesStatusInterfacesAndGateways() {
        let text = Self.fingerprint(.satisfied, interfaces: ["en0", "utun4"], gateways: ["192.0.2.1"]).description
        #expect(text == "satisfied [en0,utun4] via [192.0.2.1]")
    }

    // MARK: - The detector

    /// The seed update has no "before" that could have been killed. Reddens if
    /// `observe` stops returning false for the first fingerprint it sees —
    /// which would restart every pane once at every app launch.
    @Test func theSeedUpdateEmitsNothing() {
        var detector = RemoteAttachNetworkChangeDetector()
        // Hoisted out of `#expect`: `observe` is `mutating`, and the macro
        // captures its operands immutably. Same everywhere below.
        let emitted = detector.observe(Self.fingerprint())
        #expect(!emitted)
        #expect(detector.last == Self.fingerprint())
    }

    /// Reddens if the inequality check is dropped: `NWPathMonitor` republishes
    /// unchanged paths, and each one would cost every attached pane a spawn.
    @Test func anUnchangedPathEmitsNothing() {
        var detector = RemoteAttachNetworkChangeDetector()
        _ = detector.observe(Self.fingerprint())
        let emitted = detector.observe(Self.fingerprint())
        #expect(!emitted)
    }

    /// A VPN coming up. Reddens if `interfaceNames` leaves the fingerprint.
    @Test func anAddedInterfaceEmits() {
        var detector = RemoteAttachNetworkChangeDetector()
        _ = detector.observe(Self.fingerprint(interfaces: ["en0"]))
        let emitted = detector.observe(Self.fingerprint(interfaces: ["en0", "utun4"]))
        #expect(emitted)
    }

    /// A primary-route change: same interfaces, different order. Reddens if
    /// the interface list is ever sorted or turned into a Set before
    /// comparison.
    @Test func areorderedPrimaryInterfaceEmits() {
        var detector = RemoteAttachNetworkChangeDetector()
        _ = detector.observe(Self.fingerprint(interfaces: ["en0", "en1"]))
        let emitted = detector.observe(Self.fingerprint(interfaces: ["en1", "en0"]))
        #expect(emitted)
    }

    /// A new default router on the same interface — the field evidence's own
    /// shape. Reddens if `gateways` leaves the fingerprint.
    @Test func aChangedGatewayEmits() {
        var detector = RemoteAttachNetworkChangeDetector()
        _ = detector.observe(Self.fingerprint(gateways: ["192.0.2.1"]))
        let emitted = detector.observe(Self.fingerprint(gateways: ["198.51.100.1"]))
        #expect(emitted)
    }

    /// Re-attaching onto no network only burns a spawn. Reddens if the
    /// `.satisfied` guard is dropped — note the update below differs from the
    /// previous one in every field, so only the status guard can suppress it.
    @Test func anUnsatisfiedPathEmitsNothingEvenWhenDifferent() {
        var detector = RemoteAttachNetworkChangeDetector()
        _ = detector.observe(Self.fingerprint(.satisfied, interfaces: ["en0"], gateways: ["192.0.2.1"]))
        let emitted = detector.observe(Self.fingerprint(.unsatisfied, interfaces: [], gateways: []))
        #expect(!emitted)
    }

    /// Wi-Fi dropping and coming back on the same network: the path is
    /// identical to where it started, but every transport died while it was
    /// down. Reddens if `last` stops being written on unsatisfied updates
    /// (the third update would then compare equal to the first and emit
    /// nothing) — the case the whole "every update becomes `last`" rule
    /// exists for.
    @Test func satisfiedThenUnsatisfiedThenTheSameSatisfiedEmits() {
        var detector = RemoteAttachNetworkChangeDetector()
        let seeded = detector.observe(Self.fingerprint())
        #expect(!seeded)
        let wentDown = detector.observe(Self.fingerprint(.unsatisfied, interfaces: [], gateways: []))
        #expect(!wentDown)
        let cameBack = detector.observe(Self.fingerprint())
        #expect(cameBack)
    }

    /// `last` is what the watcher reads to recover the fingerprint a change
    /// replaced, so it has to follow every update, emitting or not.
    @Test func lastFollowsEveryObservation() {
        var detector = RemoteAttachNetworkChangeDetector()
        #expect(detector.last == nil)
        _ = detector.observe(Self.fingerprint(interfaces: ["en0"]))
        #expect(detector.last?.interfaceNames == ["en0"])
        let down = Self.fingerprint(.unsatisfied, interfaces: [], gateways: [])
        _ = detector.observe(down)
        #expect(detector.last == down)
    }
}
