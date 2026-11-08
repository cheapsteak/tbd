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
    /// How long the connect-time phone refresh waits before each retry,
    /// after its first try fails. About 7.5 s in all.
    nonisolated static let phoneConnectRetryDelays: [Duration] = [
        .milliseconds(500), .seconds(1), .seconds(2), .seconds(4),
    ]

    /// Reads `phone.status`, then `phone.devices`. Only the newest refresh
    /// started may publish, so an older answer never lands over a newer one.
    /// A failure sets `phoneStatusError` and keeps what was last read; an
    /// older daemon, which lacks the methods, leaves `phoneStatus` nil.
    func refreshPhone() async {
        _ = await readPhone()
    }

    /// The phone refresh at connect, which tries again when it fails.
    ///
    /// The daemon can refuse the first `phone.status` while it is still
    /// recording the app's identity, and no delta follows that refusal, so
    /// `phoneStatus` would stay nil and the "Phone connected" chip hidden
    /// while a phone may be controlling the laptop. So a failed first try is
    /// retried after each of `phoneConnectRetryDelays` on `phoneRetryClock`,
    /// in a task of its own, so the rest of the connect does not wait. The
    /// retries stop at the first `phone.status` that answers, once the app
    /// disconnects, and when a later connect starts its own.
    func refreshPhoneAtConnect() async {
        phoneConnectRetryTask?.cancel()
        phoneConnectRetryTask = nil
        let answered = await readPhone()
        guard !answered else { return }
        phoneConnectRetryTask = Task { [weak self] in
            await self?.retryPhoneRefresh()
        }
    }

    private func retryPhoneRefresh() async {
        for delay in Self.phoneConnectRetryDelays {
            do {
                try await phoneRetryClock.sleep(for: delay)
            } catch {
                return
            }
            guard isConnected, !Task.isCancelled else { return }
            if await readPhone() { return }
        }
    }

    /// `refreshPhone`'s work. Returns whether `phone.status` answered,
    /// whether or not a newer refresh then took over publishing.
    private func readPhone() async -> Bool {
        phoneRefreshGeneration &+= 1
        let generation = phoneRefreshGeneration
        let client = phoneClient
        let status: PhoneStatusResult
        do {
            status = try await client.phoneStatus()
        } catch {
            recordPhoneRefreshFailure(error, generation: generation)
            return false
        }
        guard phoneRefreshGeneration == generation else { return true }
        if status != phoneStatus { phoneStatus = status }
        do {
            let devices = try await client.phoneDevices()
            guard phoneRefreshGeneration == generation else { return true }
            if devices != phoneDevices { phoneDevices = devices }
            if phoneStatusError != nil { phoneStatusError = nil }
        } catch {
            recordPhoneRefreshFailure(error, generation: generation)
        }
        return true
    }

    /// Keeps a failed refresh's reason as `phoneStatusError`, unless a newer
    /// refresh has started since.
    private func recordPhoneRefreshFailure(_ error: any Error, generation: UInt64) {
        guard phoneRefreshGeneration == generation else { return }
        let text = Self.phoneErrorText(error)
        phoneLogger.debug("phone refresh failed: \(text, privacy: .public)")
        if text != phoneStatusError { phoneStatusError = text }
    }

    /// Turns phone control on or off.
    func setPhoneControlEnabled(_ enabled: Bool) async {
        await performPhoneAction(RPCMethod.configSetPhoneControlEnabled) {
            try await phoneClient.setPhoneControlEnabled(enabled)
        }
    }

    /// Saves the relay URL; nil or blank removes it. The daemon checks the
    /// relay before it saves. Returns nil on success, or the daemon's reason
    /// for the setup sheet to show inline.
    func setPhoneRelayURL(_ raw: String?) async -> String? {
        await performPhoneAction(RPCMethod.configSetPhoneRelayURL) {
            try await phoneClient.setPhoneRelayURL(Self.nonBlankPhoneURL(raw))
        }
    }

    /// Saves the loader URL override; nil or blank clears it, leaving the
    /// default, which is none until the loader org is recorded.
    /// Returns nil on success, or the reason for the pane to show inline.
    func setPhoneLoaderURL(_ raw: String?) async -> String? {
        await performPhoneAction(RPCMethod.configSetPhoneLoaderURL) {
            try await phoneClient.setPhoneLoaderURL(Self.nonBlankPhoneURL(raw))
        }
    }

    /// Starts a pairing offer. The new offer is published into `phoneStatus`
    /// before the refresh, so the pairing sheet sees it even if that refresh
    /// fails. Returns nil on success, or the reason pairing could not start.
    /// An earlier offer's Allow or Deny failure is cleared.
    func startPhonePairing() async -> String? {
        if phonePairingError != nil { phonePairingError = nil }
        return await performPhoneAction(RPCMethod.phonePairStart) {
            let pairing = try await phoneClient.phonePairStart()
            phoneStatus?.pairing = pairing
        }
    }

    /// Allows the phone waiting on offer `offerID`, the offer whose phone
    /// name and code the pairing sheet showed. The daemon refuses any ID but
    /// its live offer's, so an Allow never reaches a newer offer, whose phone
    /// the user has not seen. A failure's reason is kept in
    /// `phonePairingError`, for the pairing sheet to show.
    func allowPhonePairing(offerID: UUID) async {
        let failure = await performPhoneAction(RPCMethod.phonePairAllow) {
            _ = try await phoneClient.phonePairAllow(offerID: offerID)
        }
        if failure != phonePairingError { phonePairingError = failure }
    }

    /// Denies offer `offerID`, the one the pairing sheet showed: the user
    /// clicked Deny, or closed the sheet while it was live. Like Allow, it
    /// never reaches a newer offer. A failure's reason is kept in
    /// `phonePairingError`, for the pairing sheet to show.
    func denyPhonePairing(offerID: UUID) async {
        let failure = await performPhoneAction(RPCMethod.phonePairDeny) {
            try await phoneClient.phonePairDeny(offerID: offerID)
        }
        if failure != phonePairingError { phonePairingError = failure }
    }

    /// Unpairs a phone. A failure's reason is kept in `phoneRevokeError`, for
    /// the Phone pane to show.
    func revokePhone(deviceID: UUID) async {
        let failure = await performPhoneAction(RPCMethod.phoneRevoke) {
            try await phoneClient.phoneRevoke(deviceID: deviceID)
        }
        if failure != phoneRevokeError { phoneRevokeError = failure }
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

    /// Runs one phone RPC, logs it if it fails, then refreshes either way.
    /// Returns nil on success, or the failure's text.
    @discardableResult
    private func performPhoneAction(_ method: String, _ action: () async throws -> Void) async -> String? {
        let failure: String?
        do {
            try await action()
            failure = nil
        } catch {
            let text = Self.phoneErrorText(error)
            phoneLogger.error("\(method, privacy: .public) failed: \(text, privacy: .public)")
            failure = text
        }
        await refreshPhone()
        return failure
    }
}
