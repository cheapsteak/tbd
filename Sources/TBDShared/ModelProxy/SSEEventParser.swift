/// One server-sent event, as the proxy's tee sees it go past on the wire.
public struct SSEEvent: Sendable, Equatable {
    /// The `event:` field's value, or nil when the event carried none.
    public let name: String?
    /// Every `data:` field's value in order, joined with a newline. Empty when
    /// the event carried no `data:` field.
    public let data: String
    /// True when the event was built from comment lines alone — the `: ping`
    /// keepalive. Comments are events here rather than noise the parser drops,
    /// because the proxy relays them and Claude Code counts them toward the
    /// liveness of a stream that is otherwise silent between tokens.
    public let isComment: Bool

    public init(name: String?, data: String, isComment: Bool) {
        self.name = name
        self.data = data
        self.isComment = isComment
    }
}

/// Incremental `text/event-stream` parser for the tee.
///
/// The tee sees the upstream body as whatever chunks the network hands it, and
/// those boundaries fall wherever they like — mid-line, mid-field, and mid-UTF-8
/// sequence. So the parser buffers **bytes**, never text, and decodes a region
/// only once its terminating blank line has arrived: a code point split across
/// two `feed` calls is whole again by the time any decoder sees it. Decoding
/// per chunk instead would turn a split emoji into two replacement characters
/// and corrupt the data the transcript records.
///
/// A value type with no reference-type state, so a copy is an independent
/// parser and the type is `Sendable` without a lock.
public struct SSEEventParser: Sendable {
    /// Bytes fed but not yet consumed by a completed event. Everything before
    /// `lineStart` is a run of complete, non-blank lines belonging to the event
    /// currently being accumulated.
    private var buffer: [UInt8] = []
    /// Index in `buffer` where the line currently being scanned begins.
    private var lineStart: Int = 0

    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D
    private static let colon: UInt8 = 0x3A
    private static let space: UInt8 = 0x20
    private static let dataField = Array("data".utf8)
    private static let eventField = Array("event".utf8)

    public init() {}

    /// Whatever is buffered and not yet terminated — the bytes after the last
    /// blank line, including the complete lines of an event still in progress.
    public var pendingByteCount: Int { buffer.count }

    /// Feed raw bytes; returns every complete event (terminated by a blank
    /// line) in order. Bytes after the last blank line are retained for the
    /// next feed.
    public mutating func feed(_ bytes: some Collection<UInt8>) -> [SSEEvent] {
        buffer.append(contentsOf: bytes)
        var events: [SSEEvent] = []
        while let feedIndex = buffer[lineStart...].firstIndex(of: Self.lineFeed) {
            // A line ends at LF; a CR immediately before it is part of the
            // terminator, which is how CRLF streams are accepted without a
            // second scan and without a lone trailing CR ever being mistaken
            // for a terminator of its own.
            var lineEnd = feedIndex
            if lineEnd > lineStart, buffer[lineEnd - 1] == Self.carriageReturn { lineEnd -= 1 }

            if lineEnd == lineStart {
                // Blank line: the event is whatever complete lines precede it.
                // Nothing preceding means a stray separator, not an empty event.
                if lineStart > 0 { events.append(Self.parseEvent(buffer[0..<lineStart])) }
                buffer.removeFirst(feedIndex + 1)
                lineStart = 0
            } else {
                lineStart = feedIndex + 1
            }
        }
        return events
    }

    /// Decodes one event's worth of complete lines. Every multi-byte sequence
    /// in `region` is whole, because the region ends at a terminator that has
    /// already arrived.
    private static func parseEvent(_ region: ArraySlice<UInt8>) -> SSEEvent {
        var dataBytes: [UInt8] = []
        var hasData = false
        var nameBytes: [UInt8]?
        var sawField = false
        var sawComment = false

        var cursor = region.startIndex
        while cursor < region.endIndex {
            let feedIndex = region[cursor...].firstIndex(of: lineFeed) ?? region.endIndex
            var lineEnd = feedIndex
            if lineEnd > cursor, region[lineEnd - 1] == carriageReturn { lineEnd -= 1 }
            let line = region[cursor..<lineEnd]
            cursor = feedIndex < region.endIndex ? feedIndex + 1 : region.endIndex

            guard let first = line.first else { continue }
            if first == colon {
                sawComment = true
                continue
            }
            sawField = true

            let colonIndex = line.firstIndex(of: colon)
            let field = line[line.startIndex..<(colonIndex ?? line.endIndex)]
            var valueStart = colonIndex.map { $0 + 1 } ?? line.endIndex
            // Exactly one space after the colon is part of the framing; any
            // further leading space belongs to the value.
            if valueStart < line.endIndex, line[valueStart] == space { valueStart += 1 }
            let value = line[valueStart..<line.endIndex]

            if field.elementsEqual(dataField) {
                if hasData { dataBytes.append(lineFeed) }
                dataBytes.append(contentsOf: value)
                hasData = true
            } else if field.elementsEqual(eventField) {
                nameBytes = Array(value)
            }
            // `id:`, `retry:` and anything we do not model are ignored — the
            // tee reproduces the stream byte for byte elsewhere, so nothing is
            // lost by not modelling them here.
        }

        // Lossy decoding is the wanted behaviour here, not a shortcut past a
        // failable initializer: the tee observes a stream it does not own, and
        // a byte upstream sent that is not valid UTF-8 must cost one
        // replacement character, never a dropped event.
        // swiftlint:disable optional_data_string_conversion
        return SSEEvent(
            name: nameBytes.map { String(decoding: $0, as: UTF8.self) },
            data: String(decoding: dataBytes, as: UTF8.self),
            isComment: sawComment && !sawField
        )
        // swiftlint:enable optional_data_string_conversion
    }
}
