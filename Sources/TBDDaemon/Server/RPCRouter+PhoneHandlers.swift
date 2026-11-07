import Foundation
import os
import TBDShared

private let phoneRPCLog = Logger(subsystem: "com.tbd.daemon", category: "phone-bridge")

/// The laptop side of phone control: the Phone settings pane's nine methods
/// (`docs/specs/2026-11-07-phone-control-design.md`, sections 5 and 10).
///
/// Every one of them is app-only. Each pairs, unpairs or exposes phones, or
/// changes where phone traffic goes, so the check that the caller is the TBD
/// app runs first, before params are decoded and before any database read or
/// write or bridge call.
extension RPCRouter {
    static let phoneNotFromAppRefusal = "phone control is managed only from the TBD app"
    static let phoneUnavailableRefusal = "phone control is not available in this daemon"
    /// The refusal when the caller passed the envelope check but its
    /// executable is not one of TBD's app binaries, or could not be read. The
    /// Phone settings pane shows it as it stands.
    static let phoneNotFromAppBinaryRefusal = "Couldn't confirm this request came from the TBD app"

    /// Answers one of `RPCMethod.phoneAppOnlyMethods`.
    ///
    /// The caller must be the TBD app, in two checks.
    ///
    /// - **The envelope check** that `prompt.answer` and `terminal.send`'s
    ///   envelope suppression use (`authenticatesEnvelopeSuppression`): the
    ///   kernel-named peer pid must be the recorded app identity, re-verified.
    ///   A nil context, which every caller that did not arrive over the socket
    ///   has, is refused, as is any other process on the socket. Refused with
    ///   `phoneNotFromAppRefusal`.
    /// - **The binary check** (`PhoneAppBinaryCheck`): that pid's executable
    ///   must be one of TBD's own app binaries, by device and inode. The
    ///   recorded identity is only "the sidecar's current client", and the
    ///   sidecar adopts whichever process connects. Refused with
    ///   `phoneNotFromAppBinaryRefusal`, logged at `.error`.
    ///
    /// A bridge error reaches the caller as its `localizedDescription`, which
    /// the Phone pane shows as it stands.
    func handlePhoneRPC(
        _ request: RPCRequest, connection: RPCConnectionContext?
    ) async throws -> RPCResponse {
        switch await authenticatesEnvelopeSuppression(connection: connection) {
        case .authenticated:
            break
        case .refused(let reason):
            phoneRPCLog.debug(
                "\(request.method, privacy: .public) refused: \(reason, privacy: .public)")
            return RPCResponse(error: Self.phoneNotFromAppRefusal)
        }

        // `.authenticated` means the peer pid is the recorded app's, just
        // re-verified, so this checks that same pid's executable.
        let binaryVerdict: PhoneAppBinaryCheck.Verdict
        if let pid = connection?.peerPID {
            binaryVerdict = phoneAppBinaryCheck.verify(pid: pid)
        } else {
            binaryVerdict = .refused(reason: "the caller's pid is not established")
        }
        if case .refused(let reason) = binaryVerdict {
            phoneRPCLog.error(
                "\(request.method, privacy: .public) refused: \(reason, privacy: .public)")
            return RPCResponse(error: Self.phoneNotFromAppBinaryRefusal)
        }

        let paramsData = request.paramsData
        switch request.method {
        case RPCMethod.phoneStatus:
            return try await handlePhoneStatus()
        case RPCMethod.phoneDevices:
            let devices = try await db.phoneDevices.list()
            return try RPCResponse(result: PhoneDeviceListResult(devices: devices))
        case RPCMethod.phonePairStart:
            return try await handlePhonePairStart()
        case RPCMethod.phonePairAllow:
            return try await handlePhonePairAllow(paramsData)
        case RPCMethod.phonePairDeny:
            return try await handlePhonePairDeny(paramsData)
        case RPCMethod.phoneRevoke:
            return try await handlePhoneRevoke(paramsData)
        case RPCMethod.configSetPhoneControlEnabled:
            return try await handleConfigSetPhoneControlEnabled(paramsData)
        case RPCMethod.configSetPhoneRelayURL:
            return try await handleConfigSetPhoneRelayURL(paramsData)
        case RPCMethod.configSetPhoneLoaderURL:
            return try await handleConfigSetPhoneLoaderURL(paramsData)
        default:
            return RPCResponse(error: "Unknown method: \(request.method)")
        }
    }

    // MARK: - Status and devices

    /// The bridge's status. Without a bridge, the saved settings and
    /// `phoneUnavailableRefusal` as the problem, so the pane can still show
    /// what is set.
    private func handlePhoneStatus() async throws -> RPCResponse {
        if let bridge = phoneBridge {
            return try RPCResponse(result: await bridge.status())
        }
        let config = try await db.config.get()
        let status = PhoneStatusResult(
            enabled: config.phoneControlEnabled,
            relayURL: config.phoneRelayURL,
            loaderURLOverride: config.phoneLoaderURL,
            running: false,
            problem: Self.phoneUnavailableRefusal,
            relay: PhoneRelayStatus(
                state: config.phoneRelayURL == nil ? .notSetUp : .unknown,
                bundledVersion: PhoneBridgeConstants.bundledRelayVersion),
            connectedDeviceIDs: [],
            pairing: nil)
        return try RPCResponse(result: status)
    }

    // MARK: - Pairing and revoking

    private func handlePhonePairStart() async throws -> RPCResponse {
        guard let bridge = phoneBridge else { return RPCResponse(error: Self.phoneUnavailableRefusal) }
        let pairing: PhonePairingStatus
        do {
            pairing = try await bridge.pairStart()
        } catch {
            return RPCResponse(error: error.localizedDescription)
        }
        return try RPCResponse(result: pairing)
    }

    private func handlePhonePairAllow(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(PhonePairOfferParams.self, from: paramsData)
        guard let bridge = phoneBridge else { return RPCResponse(error: Self.phoneUnavailableRefusal) }
        let device: PhoneDevice
        do {
            device = try await bridge.pairAllow(offerID: params.offerID)
        } catch {
            return RPCResponse(error: error.localizedDescription)
        }
        return try RPCResponse(result: device)
    }

    private func handlePhonePairDeny(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(PhonePairOfferParams.self, from: paramsData)
        guard let bridge = phoneBridge else { return RPCResponse(error: Self.phoneUnavailableRefusal) }
        do {
            try await bridge.pairDeny(offerID: params.offerID)
        } catch {
            return RPCResponse(error: error.localizedDescription)
        }
        return .ok()
    }

    private func handlePhoneRevoke(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(PhoneRevokeParams.self, from: paramsData)
        guard let bridge = phoneBridge else { return RPCResponse(error: Self.phoneUnavailableRefusal) }
        do {
            try await bridge.revoke(deviceID: params.deviceID)
        } catch {
            return RPCResponse(error: error.localizedDescription)
        }
        return .ok()
    }

    // MARK: - Settings

    /// Saves the "Phone control" setting, then lets the bridge start or stop.
    private func handleConfigSetPhoneControlEnabled(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConfigSetPhoneControlEnabledParams.self, from: paramsData)
        try await db.config.setPhoneControlEnabled(params.enabled)
        await phoneBridge?.reconcile()
        subscriptions.broadcast(delta: .phoneStatusChanged)
        return .ok()
    }

    /// Saves the relay URL, but only one that passed both `PhoneURLValidation`
    /// and the bridge's relay check; nil or blank removes it. The check runs on
    /// every save, so saving the same URL again checks it again.
    private func handleConfigSetPhoneRelayURL(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConfigSetPhoneURLParams.self, from: paramsData)
        let bridge = phoneBridge
        let stored: String?
        if let raw = Self.nonBlank(params.url) {
            let url: URL
            do {
                url = try PhoneURLValidation.relay(raw)
            } catch {
                return RPCResponse(error: error.localizedDescription)
            }
            guard let bridge else { return RPCResponse(error: Self.phoneUnavailableRefusal) }
            do {
                _ = try await bridge.checkRelay(url)
            } catch {
                return RPCResponse(error: error.localizedDescription)
            }
            stored = url.absoluteString
        } else {
            stored = nil
        }
        try await db.config.setPhoneRelayURL(stored)
        await bridge?.reconcile()
        subscriptions.broadcast(delta: .phoneStatusChanged)
        return .ok()
    }

    /// Saves the loader URL override after `PhoneURLValidation.loader`; nil or
    /// blank goes back to the default. The bridge reads it at the next
    /// `pairStart`, so nothing needs to restart.
    private func handleConfigSetPhoneLoaderURL(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(ConfigSetPhoneURLParams.self, from: paramsData)
        let stored: String?
        if let raw = Self.nonBlank(params.url) {
            do {
                stored = try PhoneURLValidation.loader(raw).absoluteString
            } catch {
                return RPCResponse(error: error.localizedDescription)
            }
        } else {
            stored = nil
        }
        try await db.config.setPhoneLoaderURL(stored)
        subscriptions.broadcast(delta: .phoneStatusChanged)
        return .ok()
    }

    /// `url`, unless it is nil or only whitespace.
    private static func nonBlank(_ url: String?) -> String? {
        guard let url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return url
    }
}
