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
    /// The longest a `prompt.changed` waits for a phone's answer, still
    /// running, to a prompt that closed, so it can say who answered. Past it
    /// the running answer is taken as the one that closed the prompt.
    static let answerAttributionWait: Duration = .seconds(2)
    /// The most events kept for a reconnecting phone to replay.
    static let eventRingCount = 512
    /// The most bytes of events kept for replay.
    static let eventRingBytes = 4_194_304
    /// The most request IDs kept for one device.
    static let requestMemoryPerDevice = 1_000
    /// The most requests one device may have running at once. A new request
    /// past it is refused, so a phone cannot start runs without bound.
    static let requestsInFlightPerDevice = 32
    /// The longest request ID the service accepts, in UTF-8 bytes. A longer
    /// one is refused before it reaches the request memory.
    static let requestIDMaxBytes = 128
    /// The most UTF-8 bytes of text one `message.send` or `session.setModel`
    /// may type into a session. A frame already bounds a request near 64 KB;
    /// this makes the limit explicit, so it holds whatever carries the text.
    static let messageMaxBytes = 262_144
    /// The most UTF-8 bytes a phone message that starts a session on the
    /// tmux transport may take in its spawn command, shell-quoted
    /// (`PhoneAppService.fitsTmuxFirstPrompt(_:)`): a phone
    /// `worktree.create`'s first message, or a message that wakes a parked
    /// tmux session. Such a message rides the spawn command, and tmux packs
    /// the whole command into one client message of about 16 KB and refuses
    /// a longer one with "command too long" (on tmux 3.6a a 16,013-byte
    /// command was accepted and a 17,013-byte one refused). The quoting
    /// counts against the limit because each `'` grows to four bytes, so
    /// 12,000 leaves about 4 KB for the rest of the command: the agent's
    /// flags and environment. A pty-holder spawn hands its command to the
    /// holder through a socket and execs it with argv, bounded by `ARG_MAX`
    /// (1 MiB on macOS) rather than by tmux, so it takes up to
    /// `messageMaxBytes`, as a running session does.
    static let firstPromptMaxBytes = 12_000
    /// The most rows one `sessions.subscribe` snapshot carries.
    static let snapshotMaxRows = 1_000
    /// The most items one first page carries.
    static let firstPageItemLimit = 256
    /// The most items one older page carries.
    static let olderPageItemLimit = 1_024
    /// A permission prompt's summary and target are cut at this many bytes,
    /// and a deny reason may be at most this long. A question's text is never
    /// cut, since an answer is keyed on it.
    static let promptTextCap = 4_096
    /// An option's description and a suggestion line are cut at this many
    /// bytes. An option's label is never cut, since it is an answer value.
    static let promptOptionCap = 1_024
    /// The most bytes read back from an offset to find a page's start.
    static let anchorScanLimit = 8_388_608
    /// The longest item ID `transcript.detail` accepts, in UTF-8 bytes. Its
    /// reply echoes the ID, so the ID's size counts against the frame.
    static let detailItemIDMaxBytes = 256
    /// Bounds a subagent row's item count, two ways: the most bytes of a
    /// subagent's transcript file that `TranscriptPager.subagentItemCount`
    /// reads, so a larger file has no count, and the largest count a row
    /// carries, which is also the count a row is measured with while a page
    /// is fitted.
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
            length += escapedLength(scalar)
        }
        return length
    }

    /// The length one scalar takes in a JSON string body, by the rules above.
    static func escapedLength(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0x22, 0x5C, 0x08, 0x09, 0x0A, 0x0C, 0x0D:
            return 2
        case 0x00..<0x20:
            return 6
        default:
            return UTF8.width(scalar)
        }
    }
}
