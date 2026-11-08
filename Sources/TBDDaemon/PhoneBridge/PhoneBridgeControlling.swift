import Foundation
import TBDShared

/// What `Server`'s `phone.*` handlers ask of the phone bridge.
///
/// Declared here rather than in `Server`, because `Server` sits above
/// `PhoneBridge` and may name it, while the bridge never names `Server`. The
/// handler tests drive a fake through it, so they need no relay and no key
/// file. `PhoneBridge` is the one production conformer.
///
/// Every call reaches the bridge only after the router has checked that the
/// caller is the TBD app.
protocol PhoneBridgeControlling: Sendable {
    /// Brings the running links in line with the saved settings: starts or
    /// stops the bridge, and opens or closes one link per paired phone.
    /// Broadcasts `.phoneStatusChanged` once when it is done, whatever it
    /// did, so a caller that reconciles sends no delta of its own.
    func reconcile() async

    /// The same reconcile, after the user saved the relay `url`, which
    /// `checkRelay` has just answered with `info`. That answer stands as the
    /// relay check for `url`, so the relay is not asked again; a reconcile
    /// that finds another relay saved ignores it. Each link still checks the
    /// relay before it connects.
    func reconcile(afterSavingRelay url: URL, checkedAs info: PhoneRelayInfo) async

    /// Reads `GET /v1/info` from `url`, a relay the user has not saved yet,
    /// and checks it with `RelayCompatibility.check`. Throws when the relay
    /// cannot be reached, is not a TBD relay, or does not speak API 1.
    func checkRelay(_ url: URL) async throws -> PhoneRelayInfo

    func status() async -> PhoneStatusResult

    /// Starts a pairing offer and returns its status, link included.
    func pairStart() async throws -> PhonePairingStatus

    /// The user clicked Allow: stores the phone and returns its row.
    func pairAllow(offerID: UUID) async throws -> PhoneDevice

    /// The user clicked Deny.
    func pairDeny(offerID: UUID) async throws

    /// Unpairs a phone: ends its channel, if any, and deletes its row.
    func revoke(deviceID: UUID) async throws
}
