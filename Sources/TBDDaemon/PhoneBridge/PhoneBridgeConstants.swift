import Foundation
import SystemConfiguration
import TBDShared

/// The phone bridge's pinned values, in one place (spec section 13).
enum PhoneBridgeConstants {
    /// How long a pairing offer, and so its QR code, stays usable.
    static let pairingOfferLifetime: Duration = .seconds(300)
    /// How often a relay socket sends the `ping` text frame.
    static let keepaliveInterval: Duration = .seconds(30)
    /// The first reconnect delay. Each failure doubles it, up to
    /// `reconnectMaximum`, with equal jitter.
    static let reconnectInitial: Duration = .seconds(1)
    static let reconnectMaximum: Duration = .seconds(60)
    /// The longest the laptop waits for a last message to reach the relay
    /// before it closes a socket.
    static let flushLimit: Duration = .seconds(2)
    /// The longest the laptop waits, once it has written handshake message 2,
    /// for the phone's first transport message to decrypt. A channel that
    /// reaches it is dropped.
    static let handshakeTimeout: Duration = .seconds(10)
    /// The request timeout for `GET /v1/info`.
    static let relayInfoTimeoutSeconds: TimeInterval = 10
    /// The relay API version this laptop speaks; a relay whose `api` list
    /// lacks it is refused.
    static let relayAPIVersion = 1
    /// The relay version this build ships with, kept in step with
    /// `RELAY_VERSION` in `relay/cloudflare/src`.
    static let bundledRelayVersion = "1.0.0"
    /// The most raw (compressed) bundle bytes one `bundle.chunk` carries.
    static let bundleChunkRawBytes = 45_000
    /// The largest compressed bundle a phone's loader accepts: it refuses a
    /// `welcome` whose bundle `size` is larger. `MAX_BUNDLE_COMPRESSED` in
    /// `phone/loader/constants.js`.
    static let maxBundleCompressedBytes = 4 * 1024 * 1024
    /// The largest bundle, inflated, a phone's loader accepts: it stops
    /// inflating past it. `MAX_BUNDLE_TEXT` in `phone/loader/constants.js`.
    static let maxBundleTextBytes = 16 * 1024 * 1024
    static let loaderProtocolVersion = 1
    static let minLoaderProtocolVersion = 1
    /// A phone's name is 1 to this many characters after trimming.
    static let deviceNameMaxCharacters = 64
    /// The laptop's name in a pairing link and in message 2.
    static let laptopNameMaxUTF8Bytes = 256
    /// A `.laptop.key.*.tmp` file older than this is left over from an
    /// interrupted create, and the next load removes it.
    static let keyTempMaxAge: TimeInterval = 60
    /// Sent on every relay request, so a relay's logs can tell TBD's traffic
    /// and version apart.
    static var userAgent: String { "TBD-PhoneBridge/\(TBDConstants.version) (+https://github.com/cheapsteak/tbd)" }
}

/// The laptop's name as phones see it: in the pairing link and in handshake
/// message 2.
enum LaptopName {
    /// The Mac's computer name, the one the user sets in System Settings;
    /// else its local host name, the Bonjour name without `.local`; else the
    /// kernel's host name; cut to fit, and "Mac" when none can be read.
    ///
    /// None of these waits on DNS or mDNS. The bridge reads the name on its
    /// actor while it reconciles, where a wait would hold up every phone
    /// request, so `ProcessInfo.hostName`, which can resolve the name over
    /// the network, is not used.
    static func current() -> String {
        let candidates = [
            SCDynamicStoreCopyComputerName(nil, nil).map { $0 as String },
            SCDynamicStoreCopyLocalHostName(nil).map { $0 as String },
            kernelHostName(),
        ]
        let name = candidates.compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return limited(name ?? "")
    }

    /// `gethostname(3)`, or nil when it fails.
    private static func kernelHostName() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        // One byte short of the buffer, so the name is always terminated.
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    /// `raw` trimmed of whitespace and cut, at a `Character` boundary, to at
    /// most `maxUTF8Bytes` UTF-8 bytes, so a cut never splits an accented
    /// letter or an emoji. "Mac" when nothing is left.
    static func limited(_ raw: String, maxUTF8Bytes: Int = PhoneBridgeConstants.laptopNameMaxUTF8Bytes) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var end = trimmed.startIndex
        var byteCount = 0
        for index in trimmed.indices {
            let size = trimmed[index].utf8.count
            guard byteCount + size <= maxUTF8Bytes else { break }
            byteCount += size
            end = trimmed.index(after: index)
        }
        // A cut can leave whitespace at the new end.
        let name = String(trimmed[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Mac" : name
    }
}
