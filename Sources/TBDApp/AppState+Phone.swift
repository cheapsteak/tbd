import AppKit
import Foundation
import os
import TBDShared

private let phoneLogger = Logger(subsystem: "com.tbd.app", category: "phone-bridge")

/// The daemon's phone control RPCs, as the app calls them
/// (`docs/specs/2026-11-07-phone-control-design.md`, sections 5 and 10).
/// `DaemonClient` is the production conformer; tests pass a fake through
/// `AppState.phoneClient`.
///
/// The daemon answers these only for the TBD app, and may refuse once while
/// it is still recording the app's identity at launch, so the Phone pane
/// refreshes when it appears.
protocol PhoneControlClient: Sendable {
    func phoneStatus() async throws -> PhoneStatusResult
    func phoneDevices() async throws -> [PhoneDevice]
    func phonePairStart() async throws -> PhonePairingStatus
    func phonePairAllow(offerID: UUID) async throws -> PhoneDevice
    func phonePairDeny(offerID: UUID) async throws
    func phoneRevoke(deviceID: UUID) async throws
    func setPhoneControlEnabled(_ enabled: Bool) async throws
    func setPhoneRelayURL(_ url: String?) async throws
    func setPhoneLoaderURL(_ url: String?) async throws
}

extension DaemonClient: PhoneControlClient {}

extension AppState {
    /// Reads `phone.status`, then `phone.devices`. Only the newest refresh
    /// started may publish, so an older answer never lands over a newer one.
    /// A failure sets `phoneStatusError` and keeps what was last read; an
    /// older daemon, which lacks the methods, leaves `phoneStatus` nil.
    func refreshPhone() async {
        phoneRefreshGeneration &+= 1
        let generation = phoneRefreshGeneration
        let client = phoneClient
        do {
            let status = try await client.phoneStatus()
            guard phoneRefreshGeneration == generation else { return }
            if status != phoneStatus { phoneStatus = status }
            let devices = try await client.phoneDevices()
            guard phoneRefreshGeneration == generation else { return }
            if devices != phoneDevices { phoneDevices = devices }
            if phoneStatusError != nil { phoneStatusError = nil }
        } catch {
            guard phoneRefreshGeneration == generation else { return }
            let text = Self.phoneErrorText(error)
            phoneLogger.debug("phone refresh failed: \(text, privacy: .public)")
            if text != phoneStatusError { phoneStatusError = text }
        }
    }

    /// Turns phone control on or off.
    func setPhoneControlEnabled(_ enabled: Bool) async {
        do {
            try await phoneClient.setPhoneControlEnabled(enabled)
        } catch {
            logPhoneFailure("config.setPhoneControlEnabled", error)
        }
        await refreshPhone()
    }

    /// Saves the relay URL; nil or blank removes it. The daemon checks the
    /// relay before it saves. Returns nil on success, or the daemon's reason
    /// for the setup sheet to show inline.
    func setPhoneRelayURL(_ raw: String?) async -> String? {
        let failure: String?
        do {
            try await phoneClient.setPhoneRelayURL(Self.nonBlankPhoneURL(raw))
            failure = nil
        } catch {
            logPhoneFailure("config.setPhoneRelayURL", error)
            failure = Self.phoneErrorText(error)
        }
        await refreshPhone()
        return failure
    }

    /// Saves the loader URL override; nil or blank goes back to the default.
    /// Returns nil on success, or the reason for the pane to show inline.
    func setPhoneLoaderURL(_ raw: String?) async -> String? {
        let failure: String?
        do {
            try await phoneClient.setPhoneLoaderURL(Self.nonBlankPhoneURL(raw))
            failure = nil
        } catch {
            logPhoneFailure("config.setPhoneLoaderURL", error)
            failure = Self.phoneErrorText(error)
        }
        await refreshPhone()
        return failure
    }

    /// Starts a pairing offer. The new offer is published into `phoneStatus`
    /// before the refresh, so the pairing sheet sees it even if that refresh
    /// fails. Returns nil on success, or the reason pairing could not start.
    func startPhonePairing() async -> String? {
        let failure: String?
        do {
            let pairing = try await phoneClient.phonePairStart()
            phoneStatus?.pairing = pairing
            failure = nil
        } catch {
            logPhoneFailure("phone.pairStart", error)
            failure = Self.phoneErrorText(error)
        }
        await refreshPhone()
        return failure
    }

    /// Allows the phone waiting on the shown offer.
    func allowPhonePairing() async {
        guard let offerID = phoneStatus?.pairing?.offerID else { return }
        do {
            _ = try await phoneClient.phonePairAllow(offerID: offerID)
        } catch {
            logPhoneFailure("phone.pairAllow", error)
        }
        await refreshPhone()
    }

    /// Denies the shown offer: the user clicked Deny, or closed the pairing
    /// sheet while it was live.
    func denyPhonePairing() async {
        guard let offerID = phoneStatus?.pairing?.offerID else { return }
        do {
            try await phoneClient.phonePairDeny(offerID: offerID)
        } catch {
            logPhoneFailure("phone.pairDeny", error)
        }
        await refreshPhone()
    }

    /// Unpairs a phone.
    func revokePhone(deviceID: UUID) async {
        do {
            try await phoneClient.phoneRevoke(deviceID: deviceID)
        } catch {
            logPhoneFailure("phone.revoke", error)
        }
        await refreshPhone()
    }

    /// Opens Settings on the Phone tab, with the relay setup sheet when
    /// `relaySetup` is true.
    func openPhoneSettings(relaySetup: Bool) {
        settingsTab = .phone
        phoneRelaySetupRequested = relaySetup
        settingsWindowOpener()
    }

    /// The text to show for a failed phone call: the daemon's own sentence
    /// for an RPC error, which the bridge writes to be shown as it stands, or
    /// the error's description otherwise.
    nonisolated static func phoneErrorText(_ error: any Error) -> String {
        if case .rpcError(let message, _)? = error as? DaemonClientError {
            return message
        }
        return error.localizedDescription
    }

    /// `raw` trimmed, or nil when it is nil or only whitespace.
    nonisolated static func nonBlankPhoneURL(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func logPhoneFailure(_ method: String, _ error: any Error) {
        let text = Self.phoneErrorText(error)
        phoneLogger.error("\(method, privacy: .public) failed: \(text, privacy: .public)")
    }
}
