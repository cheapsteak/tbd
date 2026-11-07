import Foundation
import os

/// The app protocol's requests, by their wire names (spec section 4.4). Each
/// method's params and result types are in `PhoneAppMessages.swift`, and its
/// fixtures are `phone/protocol/<method>.request.json` and `.reply.json`.
enum PhoneAppMethod: String, CaseIterable, Sendable {
    case sessionsSubscribe = "sessions.subscribe"
    case transcriptOpen = "transcript.open"
    case transcriptPage = "transcript.page"
    case transcriptDetail = "transcript.detail"
    case transcriptClose = "transcript.close"
    case messageSend = "message.send"
    case promptAnswer = "prompt.answer"
    case profilesList = "profiles.list"
    case sessionSwitchProfile = "session.switchProfile"
    case sessionFork = "session.fork"
    case sessionSetModel = "session.setModel"
    case worktreeCreate = "worktree.create"
    case remoteProviders = "remote.providers"
    case remoteCreate = "remote.create"
}

/// The app protocol's events, by their wire names. Each one's fixture is
/// `phone/protocol/<event>.event.json`.
enum PhoneAppEventName: String, CaseIterable, Sendable {
    case sessionsChanged = "sessions.changed"
    case transcriptAppend = "transcript.append"
    case transcriptUpdate = "transcript.update"
    case transcriptReset = "transcript.reset"
    case promptChanged = "prompt.changed"
}

/// The closed list of error codes.
enum PhoneAppErrorCode: String, Codable, CaseIterable, Sendable {
    case phoneControlOff = "phone_control_off"
    case badRequest = "bad_request"
    case unknownMethod = "unknown_method"
    case notFound = "not_found"
    case unsupported
    case refused
    case notOpen = "not_open"
    case staleCursor = "stale_cursor"
    case unavailable
    case internalError = "internal"
}

/// A reply's error: a code from the closed list and a plain message for the
/// phone to show.
struct PhoneAppError: LocalizedError, Codable, Equatable, Sendable {
    let code: PhoneAppErrorCode
    let message: String

    var errorDescription: String? { "\(code.rawValue): \(message)" }
}

/// The fields every request carries, read before the request's params so the
/// service can route it and answer a bad one by its request ID.
struct PhoneRequestHead: Decodable, Sendable {
    let kind: String
    let requestID: String
    let method: String
}

/// `{"kind":"request","method":…,"params":…,"requestID":…}`.
///
/// `kind` is carried, not checked: decoding requires it and accepts any
/// value. The service routes on `PhoneRequestHead.kind`. The same holds for
/// the other envelopes.
struct PhoneRequestEnvelope<P: Codable>: Codable {
    var kind = "request"
    let requestID: String
    let method: String
    let params: P
}

/// `{"kind":"reply","requestID":…,"result":…}`.
struct PhoneReplyEnvelope<R: Codable>: Codable {
    var kind = "reply"
    let requestID: String
    let result: R
}

/// `{"error":{"code":…,"message":…},"kind":"reply","requestID":…}`.
struct PhoneErrorEnvelope: Codable, Equatable, Sendable {
    var kind = "reply"
    let requestID: String
    let error: PhoneAppError
}

/// `{"data":…,"event":…,"kind":"event","seq":…}`. `seq` numbers the events
/// a phone has been sent, so a reconnecting phone can ask for what it missed.
struct PhoneEventEnvelope<D: Codable>: Codable {
    var kind = "event"
    let event: String
    let seq: Int
    let data: D
}

extension PhoneRequestEnvelope: Equatable where P: Equatable {}
extension PhoneRequestEnvelope: Sendable where P: Sendable {}
extension PhoneReplyEnvelope: Equatable where R: Equatable {}
extension PhoneReplyEnvelope: Sendable where R: Sendable {}
extension PhoneEventEnvelope: Equatable where D: Equatable {}
extension PhoneEventEnvelope: Sendable where D: Sendable {}

/// `{}`: the params of a request that takes none, and the result of one that
/// returns none.
struct PhoneEmpty: Codable, Equatable, Sendable {}

/// Encodes and decodes app bodies, the JSON carried in the loader's
/// `{"type":"app","body":…}`.
enum PhoneAppCoding {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "phone-bridge")

    /// The reply sent when an error reply cannot be encoded. It has no request
    /// ID to give, since the encoding that failed carried it.
    private static let fallbackErrorReply = Data(#"{"error":{"code":"internal","message":"The reply could not be encoded."},"kind":"reply","requestID":""}"#.utf8)

    /// A fresh encoder for every call site, since a shared `JSONEncoder` is
    /// not concurrency-safe. Keys are sorted, `/` is not escaped, and nil
    /// optionals are omitted, so app bodies never hold `null`.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func reply<R: Codable>(requestID: String, result: R) throws -> Data {
        try makeEncoder().encode(PhoneReplyEnvelope(requestID: requestID, result: result))
    }

    /// Never fails: if the reply cannot be encoded, it returns a fixed
    /// `internal` error reply instead.
    static func errorReply(requestID: String, _ appError: PhoneAppError) -> Data {
        do {
            return try makeEncoder().encode(PhoneErrorEnvelope(requestID: requestID, error: appError))
        } catch {
            logger.error("phone app: error reply not encoded: \(error.localizedDescription, privacy: .public)")
            return fallbackErrorReply
        }
    }

    static func event<D: Codable>(_ name: PhoneAppEventName, seq: Int, data: D) throws -> Data {
        try makeEncoder().encode(PhoneEventEnvelope(event: name.rawValue, seq: seq, data: data))
    }

    /// The `params` of the request in `body`, a whole app body.
    static func params<P: Codable>(_ type: P.Type, from body: Data) throws -> P {
        try JSONDecoder().decode(ParamsField<P>.self, from: body).params
    }

    /// Bytes this app body takes inside `{"type":"app","body":…}`.
    static func framedSize(_ appBody: Data) -> Int {
        appBody.count + PhoneFrameBudget.loaderWrapperBytes
    }

    /// A request read for its params alone; the head is read separately.
    private struct ParamsField<P: Decodable>: Decodable {
        let params: P
    }
}
