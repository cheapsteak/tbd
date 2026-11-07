import Foundation

// RPC surface for phone control (docs/specs/2026-11-07-phone-control-design.md,
// sections 5 and 10).

extension RPCMethod {
    public static let phoneStatus = "phone.status"
    public static let phonePairStart = "phone.pairStart"
    public static let phonePairAllow = "phone.pairAllow"
    public static let phonePairDeny = "phone.pairDeny"
    public static let phoneDevices = "phone.devices"
    public static let phoneRevoke = "phone.revoke"
    public static let configSetPhoneControlEnabled = "config.setPhoneControlEnabled"
    public static let configSetPhoneRelayURL = "config.setPhoneRelayURL"
    public static let configSetPhoneLoaderURL = "config.setPhoneLoaderURL"

    /// Every phone control method. The daemon answers them only for the TBD
    /// app, because each one pairs, unpairs or exposes phones, or changes
    /// where phone traffic goes (spec section 5).
    public static let phoneAppOnlyMethods: [String] = [
        phoneStatus,
        phonePairStart,
        phonePairAllow,
        phonePairDeny,
        phoneDevices,
        phoneRevoke,
        configSetPhoneControlEnabled,
        configSetPhoneRelayURL,
        configSetPhoneLoaderURL,
    ]
}

public struct ConfigSetPhoneControlEnabledParams: Codable, Sendable {
    public var enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }
}

/// Params for `config.setPhoneRelayURL` and `config.setPhoneLoaderURL`.
public struct ConfigSetPhoneURLParams: Codable, Sendable {
    /// The new URL, checked with `PhoneURLValidation`. Nil clears the setting:
    /// no relay, or the default loader.
    public var url: String?
    public init(url: String?) { self.url = url }
}

/// Params for `phone.pairAllow` and `phone.pairDeny`.
public struct PhonePairOfferParams: Codable, Sendable {
    public var offerID: UUID
    public init(offerID: UUID) { self.offerID = offerID }
}

public struct PhoneRevokeParams: Codable, Sendable {
    public var deviceID: UUID
    public init(deviceID: UUID) { self.deviceID = deviceID }
}

public struct PhoneDeviceListResult: Codable, Sendable, Equatable {
    public var devices: [PhoneDevice]
    public init(devices: [PhoneDevice]) { self.devices = devices }
}

/// The relay's answer to `GET /v1/info`.
public struct PhoneRelayInfo: Codable, Sendable, Equatable {
    /// `tbd-relay` for a TBD relay.
    public var name: String
    public var version: String
    /// The relay API versions it speaks.
    public var api: [Int]

    public init(name: String, version: String, api: [Int]) {
        self.name = name; self.version = version; self.api = api
    }
}

public enum PhoneRelayState: String, Codable, Sendable {
    /// No relay URL is set.
    case notSetUp
    /// The relay has not answered a check yet. While the bridge runs, its
    /// check is under way. A stopped bridge (`PhoneStatusResult.running` is
    /// false) checks nothing and reports this state throughout.
    case checking
    case connected
    /// The relay could not be reached; the bridge keeps retrying.
    case unreachable
    /// The relay answered but is not one this laptop can use: its name is not
    /// `tbd-relay`, or its `api` list lacks the version this laptop speaks.
    /// The bridge stops and does not retry.
    case incompatible
    /// Connected, and the relay is older than the version this build ships.
    case updateAvailable
    /// A state a newer daemon added.
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PhoneRelayState(rawValue: raw) ?? .unknown
    }
}

public struct PhoneRelayStatus: Codable, Sendable, Equatable {
    public var state: PhoneRelayState
    /// The version the relay reported, once it answered.
    public var version: String?
    /// The relay version this build ships with.
    public var bundledVersion: String
    /// Why the relay is unreachable or incompatible, in plain English.
    public var detail: String?

    public init(
        state: PhoneRelayState, version: String? = nil, bundledVersion: String, detail: String? = nil
    ) {
        self.state = state; self.version = version
        self.bundledVersion = bundledVersion; self.detail = detail
    }
}

public enum PhonePairingState: String, Codable, Sendable {
    /// The QR code is live and no phone has finished the handshake and sent
    /// its first message.
    case waitingForPhone
    /// A phone finished the handshake and its first transport message
    /// decrypted; the laptop waits for Allow or Deny.
    case awaitingApproval
    case paired
    case denied
    case expired
    /// The pairing stopped before it finished: once the phone's `hello` had
    /// decrypted, its channel broke (a phone joined or left the room, the
    /// link closed, or a frame failed to decrypt); or the relay refused the
    /// pairing link; or the laptop could not store the allowed phone. A
    /// handshake that times out before `hello` keeps the offer waiting.
    case interrupted
    /// A state a newer daemon added.
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PhonePairingState(rawValue: raw) ?? .unknown
    }
}

/// The pairing offer the laptop is showing, if any.
public struct PhonePairingStatus: Codable, Sendable, Equatable {
    public var offerID: UUID
    /// The pairing link the QR code encodes. Nil once the offer is no longer
    /// live.
    public var link: String?
    public var expiresAt: Date
    public var state: PhonePairingState
    /// The 6-digit confirmation code, without the space. Set from
    /// `awaitingApproval` on, once the phone's first transport message has
    /// decrypted; nil before, so a replayed handshake message never shows one.
    public var confirmationCode: String?
    /// The name the phone sent. Set from `awaitingApproval` on, once the
    /// phone's first transport message has decrypted; nil before. Before Allow
    /// the laptop shows it in the prompt but never stores or logs it.
    public var deviceName: String?
    /// The new `phone_device` row's ID. Set only once paired.
    public var deviceID: UUID?

    public init(
        offerID: UUID, link: String?, expiresAt: Date, state: PhonePairingState,
        confirmationCode: String? = nil, deviceName: String? = nil, deviceID: UUID? = nil
    ) {
        self.offerID = offerID; self.link = link; self.expiresAt = expiresAt; self.state = state
        self.confirmationCode = confirmationCode; self.deviceName = deviceName; self.deviceID = deviceID
    }
}

/// The result of `phone.status`.
public struct PhoneStatusResult: Codable, Sendable, Equatable {
    /// The "Phone control" setting.
    public var enabled: Bool
    public var relayURL: String?
    /// The loader URL the user set; nil means the default.
    public var loaderURLOverride: String?
    /// Whether the bridge is running.
    public var running: Bool
    /// Why the bridge is not running although enabled, in plain English.
    public var problem: String?
    public var relay: PhoneRelayStatus
    /// The phones connected now: their first transport message decrypted.
    public var connectedDeviceIDs: [UUID]
    public var pairing: PhonePairingStatus?

    public init(
        enabled: Bool, relayURL: String?, loaderURLOverride: String?, running: Bool,
        problem: String?, relay: PhoneRelayStatus, connectedDeviceIDs: [UUID],
        pairing: PhonePairingStatus?
    ) {
        self.enabled = enabled; self.relayURL = relayURL; self.loaderURLOverride = loaderURLOverride
        self.running = running; self.problem = problem; self.relay = relay
        self.connectedDeviceIDs = connectedDeviceIDs; self.pairing = pairing
    }
}
