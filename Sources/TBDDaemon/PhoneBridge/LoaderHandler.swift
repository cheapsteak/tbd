import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "phone-bridge")

/// Why a pairing ended without a paired phone, as `pairDenied` tells the
/// phone.
enum PairDeniedReason: String, Sendable {
    case denied, expired
}

/// The loader protocol (spec section 4.3) for one channel, as a pure state
/// machine. It takes each decrypted message from the phone and returns what
/// the connection must do; it sends nothing itself, holds no clock and does
/// no I/O.
///
/// Every message is attacker-shaped bytes from an authenticated but
/// untrusted page, so the handler never traps on one. A message it cannot
/// use ends the connection with `.end(reason)`, and every reason is a fixed
/// phrase that never quotes the message. Once it has ended, every later
/// message ends it again, so nothing more is sent or delivered.
///
/// The rules:
/// - Until `welcome`, only `hello` is accepted; anything else ends.
/// - `hello` picks the highest version both its `protocols` and this laptop
///   support, and answers `welcome`. With none in common it answers
///   `incompatible` and ends. A later `hello` is ignored.
/// - `bundle.get` naming exactly the shipped bundle's hash sends every chunk
///   in order. Any other hash ends.
/// - `app` delivers its `body` when that is a JSON object, and ends
///   otherwise.
/// - Any other `type` after `welcome` is ignored. Bytes that are not one
///   UTF-8 JSON object with a string `type` end.
///
/// Every message the handler builds fits one transport message
/// (`NoiseTransport.maxPlaintextLength`); one that would not ends the
/// connection instead of being sent.
struct LoaderHandler: Sendable {
    enum Action: Sendable, Equatable {
        /// Plaintext JSON for the connection to encrypt and send, in order.
        case send(Data)
        /// The `body` object of an `app` message, as UTF-8 JSON. It is the
        /// parsed body written out again, so it is the same JSON value as
        /// the phone sent, though its key order and number spelling may
        /// differ.
        case deliverApp(Data)
        /// A protocol error: the connection ends. The reason is a fixed
        /// phrase, never message content.
        case end(String)
    }

    private enum State: Sendable {
        case awaitingHello
        case welcomed
        case ended(String)
    }

    private let bundle: PhoneAppBundle
    private let tbdVersion: String
    /// The `bundle.chunk` messages, built once. Their size is checked where
    /// they are sent, in `handle`, like every other outgoing message.
    private let chunkMessages: [Data]
    private var state: State = .awaitingHello

    init(bundle: PhoneAppBundle, tbdVersion: String = TBDConstants.version) {
        self.bundle = bundle
        self.tbdVersion = tbdVersion
        let hash = Self.jsonString(bundle.sha256Hex)
        let count = bundle.chunks.count
        // Standard base64 uses only letters, digits, `+`, `/` and `=`, none
        // of which a JSON string escapes.
        self.chunkMessages = bundle.chunks.enumerated().map { index, chunk in
            let text = #"{"type":"bundle.chunk","sha256":\#(hash),"index":\#(index),"count":\#(count),"#
                + #""data":"\#(chunk.base64EncodedString())"}"#
            return Data(text.utf8)
        }
    }

    /// What to do with one decrypted message from the phone.
    mutating func handle(_ plaintext: Data) -> [Action] {
        if case .ended(let reason) = state {
            return [.end(reason)]
        }
        var actions = route(plaintext)
        let oversize = actions.contains { action in
            if case .send(let message) = action {
                return message.count > NoiseTransport.maxPlaintextLength
            }
            return false
        }
        if oversize {
            actions = [.end("outgoing message too large")]
        }
        if case .end(let reason)? = actions.last {
            state = .ended(reason)
        }
        return actions
    }

    private mutating func route(_ plaintext: Data) -> [Action] {
        guard plaintext.count <= NoiseTransport.maxPlaintextLength else {
            return [.end("message too large")]
        }
        guard let message = Self.parseObject(plaintext),
              let type = message["type"] as? String else {
            return [.end("malformed message")]
        }
        switch state {
        case .awaitingHello:
            guard type == "hello" else {
                return [.end("message before hello")]
            }
            return hello(message)
        case .welcomed:
            switch type {
            case "hello":
                return []
            case "bundle.get":
                return bundleGet(message)
            case "app":
                return app(message)
            default:
                logger.debug("Ignored a loader message of an unknown type (\(plaintext.count, privacy: .public) bytes)")
                return []
            }
        case .ended(let reason):
            return [.end(reason)]
        }
    }

    private mutating func hello(_ message: [String: Any]) -> [Action] {
        guard let offered = Self.protocolVersions(message["protocols"]) else {
            return [.end("malformed message")]
        }
        let lowest = PhoneBridgeConstants.minLoaderProtocolVersion
        let highest = PhoneBridgeConstants.loaderProtocolVersion
        guard let chosen = offered.filter({ $0 >= lowest && $0 <= highest }).max() else {
            // An empty list counts as too old: a loader that offers nothing
            // predates every version this laptop speaks.
            let tooOld = (offered.max() ?? Int.min) < lowest ? "loader" : "laptop"
            return [
                .send(Data(#"{"type":"incompatible","tooOld":\#(Self.jsonString(tooOld))}"#.utf8)),
                .end("no common loader protocol"),
            ]
        }
        state = .welcomed
        return [.send(welcome(protocolVersion: chosen))]
    }

    private func welcome(protocolVersion: Int) -> Data {
        let text = #"{"type":"welcome","protocol":\#(protocolVersion),"#
            + #""minProtocol":\#(PhoneBridgeConstants.minLoaderProtocolVersion),"#
            + #""tbdVersion":\#(Self.jsonString(tbdVersion)),"#
            + #""bundle":{"sha256":\#(Self.jsonString(bundle.sha256Hex)),"size":\#(bundle.compressed.count)}}"#
        return Data(text.utf8)
    }

    private func bundleGet(_ message: [String: Any]) -> [Action] {
        guard let requested = message["sha256"] as? String else {
            return [.end("malformed message")]
        }
        // Byte for byte, not `==`: Swift compares strings by canonical
        // equivalence, and only the exact lowercase hex names the bundle.
        guard requested.utf8.elementsEqual(bundle.sha256Hex.utf8) else {
            return [.end("unknown bundle")]
        }
        return chunkMessages.map { .send($0) }
    }

    private func app(_ message: [String: Any]) -> [Action] {
        // `isValidJSONObject` before writing: the parser accepts a value the
        // writer refuses. The only such value reachable here is a non-finite
        // number (`-1e400` parses to `-inf`), for which the writer raises an
        // Objective-C exception rather than throwing. (Nesting is no hazard:
        // the parser refuses depth 513 and the writer handles depth 512.)
        guard let body = message["body"], body is NSDictionary,
              JSONSerialization.isValidJSONObject(body),
              let bytes = try? JSONSerialization.data(withJSONObject: body) else {
            return [.end("app body is not a JSON object")]
        }
        return [.deliverApp(bytes)]
    }

    // MARK: - Messages the bridge sends outside the handler

    private static let appPrefix = Data(#"{"type":"app","body":"#.utf8)
    private static let appSuffix = Data("}".utf8)

    /// `{"type":"app","body":<body>}`, with `body`'s bytes spliced in as
    /// they are.
    ///
    /// Because nothing re-reads the splice, `body` must be exactly one UTF-8
    /// JSON object: its first byte other than JSON whitespace is `{`, and the
    /// whole of it parses as one object, as Foundation parses it, with
    /// nothing after it. Foundation accepts a trailing comma (`{"a":1,}`),
    /// which a strict phone parser rejects, so callers must emit strict JSON;
    /// this check does not enforce it. A body like
    /// `{"a":1},"type":"revoked"` would otherwise make the phone read another
    /// `type`. Throws `.notAJSONObject` when it is not, and `.messageTooLarge`
    /// when the message would not fit one transport message.
    static func appMessage(body: Data) throws -> Data {
        guard body.first(where: { !isJSONWhitespace($0) }) == UInt8(ascii: "{") else {
            throw PhoneBridgeError.notAJSONObject
        }
        guard appPrefix.count + body.count + appSuffix.count <= NoiseTransport.maxPlaintextLength else {
            throw PhoneBridgeError.messageTooLarge
        }
        guard parseObject(body) != nil else {
            throw PhoneBridgeError.notAJSONObject
        }
        return appPrefix + body + appSuffix
    }

    /// `{"type":"revoked"}`.
    static let revoked = Data(#"{"type":"revoked"}"#.utf8)

    /// `{"type":"paired","room":"<room>"}`, sent inside the pairing channel
    /// after Allow.
    static func paired(room: String) -> Data {
        Data(#"{"type":"paired","room":\#(jsonString(room))}"#.utf8)
    }

    /// `{"type":"pairDenied","reason":"denied"|"expired"}`.
    static func pairDenied(_ reason: PairDeniedReason) -> Data {
        Data(#"{"type":"pairDenied","reason":\#(jsonString(reason.rawValue))}"#.utf8)
    }

    /// `{"laptopName":"<laptopName>"}`, handshake message 2's payload.
    /// `laptopName` goes in as given, so callers cut it with
    /// `LaptopName.limited` first.
    static func message2Payload(laptopName: String) -> Data {
        Data(#"{"laptopName":\#(jsonString(laptopName))}"#.utf8)
    }

    // MARK: - JSON

    /// `value` as a JSON string literal, quotes included: `"` and `\` are
    /// escaped, and so is every control character below U+0020. Everything
    /// else stays as it is, which JSON allows.
    static func jsonString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                out += "\\\""
            case "\\":
                out += "\\\\"
            case "\n":
                out += "\\n"
            case "\r":
                out += "\\r"
            case "\t":
                out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += (scalar.value < 0x10 ? "\\u000" : "\\u00") + String(scalar.value, radix: 16)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }

    /// `bytes` as one JSON object, or nil when they are not exactly one
    /// UTF-8 JSON object.
    ///
    /// The UTF-8 check comes first because `JSONSerialization` also detects
    /// and accepts UTF-16 and UTF-32. A UTF-8 JSON text is valid UTF-8 with
    /// no byte below 0x20 except JSON whitespace, since JSON escapes control
    /// characters inside strings; any UTF-16 or UTF-32 text holds a zero
    /// byte, so the check rules both out.
    private static func parseObject(_ bytes: Data) -> [String: Any]? {
        guard !bytes.contains(where: { $0 < 0x20 && !isJSONWhitespace($0) }),
              String(data: bytes, encoding: .utf8) != nil,
              let object = try? JSONSerialization.jsonObject(with: bytes) else {
            return nil
        }
        return object as? [String: Any]
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// `hello`'s `protocols` as integers, or nil when it is not a list of
    /// integers. A boolean is not an integer here, though `NSNumber` holds
    /// both, and a number with a fraction or out of `Int`'s range is not one
    /// either.
    private static func protocolVersions(_ value: Any?) -> [Int]? {
        guard let list = value as? [Any] else {
            return nil
        }
        var versions: [Int] = []
        for element in list {
            guard let number = element as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else {
                return nil
            }
            let isFloat = ["f", "d"].contains(String(cString: number.objCType))
            guard let version = isFloat ? Int(exactly: number.doubleValue) : Int(exactly: number) else {
                return nil
            }
            versions.append(version)
        }
        return versions
    }
}
