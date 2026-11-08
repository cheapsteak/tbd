import Foundation
import os
import TBDShared

/// Where the feed says an item's detail lies: the transcript file, the offset
/// of the item's line and its subagent's ID when the feed kept them, and the
/// generation all of it belongs to (`TranscriptFeed.detailContext(itemID:)`).
struct TranscriptDetailContext: Sendable {
    let filePath: String
    let lineOffset: UInt64?
    let agentID: String?
    let generation: Int
}

/// One detail text, split into chunks that each fit one frame.
///
/// `ranges` index into `text` and cover it in order, so the chunks rejoin to
/// it exactly. When `tooLarge` is set, `text` holds only the first chunk and
/// `ranges` that one chunk; `totalBytes` is always the whole text's UTF-8
/// length.
struct DetailChunks: Sendable {
    let totalBytes: Int
    let tooLarge: Bool
    let ranges: [Range<String.UnicodeScalarView.Index>]
    let text: String

    /// The text of chunk `index`, one of `ranges`' indices.
    func chunkText(_ index: Int) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars[ranges[index]]))
    }
}

/// A subagent's items, shaped for the phone, in chunks of whole items that
/// each fit one frame.
struct SubagentDetailChunks: Sendable {
    /// The subagent transcript's size in bytes.
    let totalBytes: Int
    /// The transcript is over `PhoneAppConstants.subagentCountLimit`, so the
    /// chunks hold only its first part.
    let tooLarge: Bool
    /// Never empty: a subagent with no items is one empty chunk.
    let chunks: [[PhoneItem]]
}

/// Splits a `transcript.detail` reply's payload into chunks that each fit one
/// frame (spec section 7, "Large details").
enum TranscriptDetailChunker {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "phone-bridge")

    /// Splits at scalar boundaries so each chunk's escaped length is at most `budget`;
    /// over `limit` UTF-8 bytes keeps only the first chunk and sets tooLarge.
    ///
    /// The walk adds `PhoneFrameBudget.escapedLength` for each unicode scalar
    /// and cuts before the scalar that would pass `budget`. A chunk always
    /// takes at least one scalar, so a budget below one scalar's length still
    /// makes progress. An empty text is one empty chunk. A cut can fall inside
    /// a grapheme cluster, never inside a scalar; the phone joins the chunks
    /// before it shows them.
    static func chunk(_ text: String, budget: Int = PhoneFrameBudget.detailChunkBytes,
                      limit: Int = PhoneAppConstants.detailLimitBytes) -> DetailChunks {
        let totalBytes = text.utf8.count
        let tooLarge = totalBytes > limit
        let scalars = text.unicodeScalars
        var ranges: [Range<String.UnicodeScalarView.Index>] = []
        var start = scalars.startIndex
        repeat {
            let end = chunkEnd(scalars, from: start, budget: budget)
            ranges.append(start..<end)
            start = end
        } while start < scalars.endIndex && !tooLarge
        guard tooLarge else {
            return DetailChunks(totalBytes: totalBytes, tooLarge: false, ranges: ranges, text: text)
        }
        // Only the first chunk is kept, so a cached detail never holds more
        // than one chunk of a text too large for the phone.
        let first = String(String.UnicodeScalarView(scalars[ranges[0]]))
        let firstScalars = first.unicodeScalars
        return DetailChunks(
            totalBytes: totalBytes, tooLarge: true,
            ranges: [firstScalars.startIndex..<firstScalars.endIndex], text: first)
    }

    /// `items` in order, in as few runs as keep each run's encoded JSON
    /// array within `budget`. An item is never split. One too large for any
    /// run is left out and logged by count: the shaper's caps keep every item
    /// far below the budget, so only an absurd ID could make one. No items is
    /// one empty run.
    static func itemChunks(_ items: [PhoneItem], budget: Int = PhoneFrameBudget.detailChunkBytes) -> [[PhoneItem]] {
        let encoder = PhoneAppCoding.makeEncoder()
        // `[` and `]`, and a comma between each pair of items.
        let brackets = 2
        var chunks: [[PhoneItem]] = []
        var current: [PhoneItem] = []
        var used = brackets
        var leftOut = 0
        for item in items {
            let size = (try? encoder.encode(item).count) ?? budget + 1
            guard brackets + size <= budget else {
                leftOut += 1
                continue
            }
            if !current.isEmpty, used + 1 + size > budget {
                chunks.append(current)
                current = []
                used = brackets
            }
            used += current.isEmpty ? size : size + 1
            current.append(item)
        }
        if !current.isEmpty || chunks.isEmpty {
            chunks.append(current)
        }
        if leftOut > 0 {
            logger.error("Phone transcript: left out \(leftOut, privacy: .public) subagent items too large for a detail chunk")
        }
        return chunks
    }

    /// Where the chunk that starts at `start` ends.
    private static func chunkEnd(
        _ scalars: String.UnicodeScalarView, from start: String.UnicodeScalarView.Index, budget: Int
    ) -> String.UnicodeScalarView.Index {
        var used = 0
        var index = start
        while index < scalars.endIndex {
            let width = PhoneFrameBudget.escapedLength(scalars[index])
            if used + width > budget, index > start { break }
            used += width
            index = scalars.index(after: index)
        }
        return index
    }
}

/// Reads one part of one item for `transcript.detail`. Every path comes from
/// the feed, never from the phone: the transcript file the terminal row names,
/// and a subagent transcript beside it named by an agent ID the transcript
/// itself recorded, which `TranscriptPager.subagentFilePath` checks.
enum TranscriptDetailReader {
    /// The full text of `itemID`'s `part`: the call's input JSON for `input`,
    /// its result for `result`, the whole message for `text`. Nil when the
    /// part of the file the lookup reads holds no such text.
    ///
    /// **Every scan reads at most `scanLimit` bytes**
    /// (`PhoneAppConstants.anchorScanLimit` by default), so no lookup reads a
    /// large transcript whole:
    /// 1. When the feed kept `lineOffset`, the item's line, the lookup scans
    ///    forward from it, and usually matches on its first line.
    /// 2. When the feed kept no offset, as for an item whose offset left the
    ///    feed's index, or the scan from it missed, as when a rewrite or a
    ///    remote prepend moved the line, the lookup scans the file's last
    ///    `scanLimit` bytes, the whole file when it is smaller. Recent items
    ///    are the ones that lie there. It skips this scan when the first one
    ///    already read those bytes.
    ///
    /// An item before that window whose offset the feed no longer holds is
    /// not found.
    static func text(
        itemID: String, part: TranscriptDetailPart, filePath: String, lineOffset: UInt64?,
        scanLimit: UInt64 = UInt64(PhoneAppConstants.anchorScanLimit)
    ) -> String? {
        let lookupID = part == .input ? itemID + "#input" : itemID
        if let lineOffset, let text = TranscriptParser.lookupDetail(
            filePath: filePath, itemID: lookupID, startingAt: lineOffset, scanLimit: scanLimit).text {
            return text
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: filePath),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return nil }
        let tailStart = size > scanLimit ? size - scanLimit : 0
        // The window is `scanLimit` bytes long, or the whole file, so the
        // scan from `lineOffset` read all of it only when it started there.
        if lineOffset == tailStart { return nil }
        return TranscriptParser.lookupDetail(
            filePath: filePath, itemID: lookupID, startingAt: tailStart, scanLimit: scanLimit).text
    }

    /// Subagent `agentID`'s items, shaped with `showDetails` and chunked, or
    /// nil when the agent ID cannot name a file beside the session's
    /// transcript, or the file is missing or unreadable.
    ///
    /// The read is bounded by `limit`. A file within it is read whole. A
    /// larger one is `tooLarge`, and only its first part is read: the whole
    /// lines in its first `limit` bytes, found with one read of those bytes
    /// and parsed up to the last `"\n"` in them. When those bytes hold no
    /// `"\n"`, the first line alone is over the limit and there are no items.
    static func subagent(
        agentID: String, transcriptPath: String, showDetails: Bool,
        limit: Int = PhoneAppConstants.subagentCountLimit,
        budget: Int = PhoneFrameBudget.detailChunkBytes
    ) -> SubagentDetailChunks? {
        guard let path = TranscriptPager.subagentFilePath(transcriptPath: transcriptPath, agentID: agentID),
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let totalBytes = Int(clamping: size)
        let tooLarge = size > UInt64(limit)

        var end: UInt64?
        if tooLarge {
            guard (try? handle.seek(toOffset: 0)) != nil,
                  let head = try? handle.read(upToCount: limit) else { return nil }
            guard let newline = head.lastIndex(of: UInt8(ascii: "\n")) else {
                return SubagentDetailChunks(totalBytes: totalBytes, tooLarge: true, chunks: [[]])
            }
            end = UInt64(newline - head.startIndex + 1)
        }
        guard let window = TranscriptParser.parseWindow(
            filePath: path, endingBefore: end, messageLimit: .max, itemLimit: .max,
            includeSidechain: true, scanLimit: limit) else { return nil }
        let ctx = ShapingContext(
            showDetails: showDetails, fileEdits: window.fileEdits, subagentAgentIDs: window.subagentAgentIDs)
        let items = window.entries.compactMap { TranscriptShaper.shape($0.item, ctx) }
        return SubagentDetailChunks(
            totalBytes: totalBytes, tooLarge: tooLarge,
            chunks: TranscriptDetailChunker.itemChunks(items, budget: budget))
    }
}
