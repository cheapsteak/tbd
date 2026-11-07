import Foundation

/// The phone app protocol's named values, in one place. The first group is
/// spec section 13's; the rest are the ones the app service chooses.
enum PhoneAppConstants {
    // MARK: Spec section 13

    /// The first page reaches back to and includes the 4th-last message.
    static let firstPageMessages = 4
    /// A first page's serialized JSON is at most 16 KB.
    static let firstPageBytes = 16_384
    /// An older page holds the next 20 messages.
    static let olderPageMessages = 20
    /// An older page's serialized JSON is at most 60 KB, so it fits one frame
    /// with its envelope.
    static let olderPageBytes = 61_440
    /// Message text over 4 KB arrives cut, with the rest behind
    /// `transcript.detail`.
    static let messagePreviewBytes = 4_096
    /// A detail over 1 MB is too large for the phone.
    static let detailLimitBytes = 1_048_576
    /// How long a request ID and its result are kept, so a resend does nothing
    /// again.
    static let requestMemory: Duration = .seconds(600)
    /// How long an open transcript's parse state outlives a disconnect.
    static let parseStateGrace: Duration = .seconds(120)

    // MARK: Chosen by the app service

    /// How long `sessions.changed` waits to gather changes.
    static let sessionsDebounce: Duration = .milliseconds(500)
    /// How often an open remote transcript is synced, the same interval the
    /// laptop's remote transcript sync uses.
    static let remoteSyncInterval: Duration = .seconds(3)
    /// How long `worktree.create` waits for the new worktree's session.
    static let worktreeSessionWait: Duration = .seconds(30)
    /// The most events kept for a reconnecting phone to replay.
    static let eventRingCount = 512
    /// The most bytes of events kept for replay.
    static let eventRingBytes = 4_194_304
    /// The most request IDs kept for one device.
    static let requestMemoryPerDevice = 1_000
    /// The most rows one `sessions.subscribe` snapshot carries.
    static let snapshotMaxRows = 1_000
    /// The most items one first page carries.
    static let firstPageItemLimit = 256
    /// The most items one older page carries.
    static let olderPageItemLimit = 1_024
    /// Prompt and question text is cut at this many bytes.
    static let promptTextCap = 4_096
    /// An option's label or description is cut at this many bytes.
    static let promptOptionCap = 1_024
    /// The most bytes read back from an offset to find a page's start.
    static let anchorScanLimit = 8_388_608
    /// The most items a subagent's count reports.
    static let subagentCountLimit = 1_048_576
}

/// What fits in one channel frame, and how long a string is once encoded.
///
/// One Noise transport message carries at most 65,519 bytes of plaintext, and
/// every app message, envelope included, must serialize to at most that once
/// it is wrapped in the loader's `{"type":"app","body":…}`.
enum PhoneFrameBudget {
    /// The most plaintext one transport message carries: 65,519 bytes.
    static let maxPlaintext = NoiseTransport.maxPlaintextLength
    /// The bytes `{"type":"app","body":` and the closing `}` add around an app
    /// body, in either key order.
    static let loaderWrapperBytes = 22
    /// A first page's serialized JSON.
    static let firstPageBytes = PhoneAppConstants.firstPageBytes
    /// An older page's serialized JSON.
    static let olderPageBytes = PhoneAppConstants.olderPageBytes
    /// An event's serialized `data`.
    static let eventDataBytes = 61_440
    /// One `transcript.detail` chunk's serialized text.
    static let detailChunkBytes = 60_000

    /// The length `s` takes as a JSON string body, without its quotes, under
    /// `PhoneAppCoding.makeEncoder()`. This is the one place that mirrors the
    /// encoder's escaping:
    /// - `"` and `\` take 2 bytes;
    /// - `\n`, `\r`, `\t`, U+0008 (`\b`) and U+000C (`\f`) take 2;
    /// - any other scalar below U+0020 takes 6 (`\u00XX`);
    /// - every other scalar takes its UTF-8 length. `/` is not escaped under
    ///   `.withoutEscapingSlashes`, and neither are DEL, U+2028 nor U+2029.
    static func escapedLength(_ s: Substring.UnicodeScalarView) -> Int {
        var length = 0
        for scalar in s {
            switch scalar.value {
            case 0x22, 0x5C, 0x08, 0x09, 0x0A, 0x0C, 0x0D:
                length += 2
            case 0x00..<0x20:
                length += 6
            default:
                length += UTF8.width(scalar)
            }
        }
        return length
    }
}
