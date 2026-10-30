import Foundation
import TBDShared

/// Appends the session mod's streamed blocks to a freshly read transcript as
/// **provisional rows**, one per block the JSONL has not caught up with yet.
///
/// Pure and total: same inputs, same output, no I/O and no clock. The pane
/// owns the reads (`TranscriptSource.snapshot`), the merge that runs before
/// this (`AskUserQuestionMerger`), and the terminal's state.
///
/// **Order.** The rows go last, after the JSONL items and the pending
/// `AskUserQuestion` captures, because they are the newest thing in the
/// session by construction: the JSONL has not caught up with them. Among
/// themselves they keep the order the step produced its blocks, oldest step
/// first.
///
/// **What each block becomes.** A text block is an `.assistantText` row,
/// carrying the ▍ ``cursor`` at its end while it is still streaming. A
/// thinking block is a `.thinking` row, which the render projection shows only
/// while it is provisional — the settled thinking rows stay hidden. A text block that ended empty, and a
/// block of a kind this build does not know, show nothing.
///
/// **Identity.** A row's id is ``idPrefix`` followed by the turn, the step and
/// the block's position in it. It cannot collide with a JSONL item id, it
/// stays put while the block's text grows (so `TranscriptStreamPlan` sees
/// `.updateLast` rather than a rebuild), and its prefix is what marks the row
/// provisional downstream — `transcriptRenderNodes(from:)` reads the prefix,
/// and Session History drops every row that carries it.
///
/// **Retirement.** A block leaves when any of these holds, and every one is
/// listed here:
///
/// 1. **Confirmed** — the JSONL holds a row with the block's `uuid`, which
///    `session.append` gave the mod before the row reached the file. An
///    interrupted block retires this way too: its partial text still becomes a
///    row.
/// 2. **The terminal exited** — the pane reports it (`sessionEnded`).
/// 3. **The heartbeat is stale** — `alive.json` is older than
///    `SessionModSessionFiles.heartbeatStaleAfter`; also `sessionEnded`.
/// 4. **Gone from the snapshot** — a new turn cleared the steps, or a newer
///    step pushed the block's step out.
///
/// And no row at all while streaming is switched off. There is no timer: a
/// tool permission wait can hold the JSONL write for minutes, and a timer
/// would drop the row in the middle of that wait.
enum ProvisionalRowComposer {

    /// Prefix on a provisional row's item id.
    static let idPrefix = "stream:"

    /// Trailing mark on a provisional text block that is still streaming.
    ///
    /// Appended to the block's text while it streams and dropped once it ends,
    /// so the row's identity stays put and the cursor is part of its content.
    /// As text it inherits the bubble's font, colour and line wrapping and adds
    /// no layout node. U+258D LEFT FIVE EIGHTHS BLOCK, the same glyph a
    /// terminal draws for a bar cursor.
    static let cursor = "\u{258D}"

    /// Whether a transcript item id belongs to a provisional row.
    static func isProvisional(itemID: String) -> Bool {
        itemID.hasPrefix(idPrefix)
    }

    /// `items` with every provisional row removed.
    ///
    /// The inverse of ``compose``, for the one reader that shares the store
    /// with the live pane but must never show the rows: Session History.
    static func settledOnly(_ items: [TranscriptItem]) -> [TranscriptItem] {
        items.filter { !isProvisional(itemID: $0.id) }
    }

    /// Returns `items` with the snapshot's unconfirmed blocks appended.
    ///
    /// - Parameters:
    ///   - items: the transcript as it stands — JSONL items with pending
    ///     `AskUserQuestion` captures already merged in.
    ///   - stream: the session's `transcript-stream.json` as last read, or nil
    ///     when there is none.
    ///   - confirmedUUIDs: the block `uuid`s the JSONL already has rows for.
    ///   - sessionEnded: the terminal exited, or the mod's heartbeat is stale.
    ///   - streamingEnabled: the resolved streaming flag. Off means no rows,
    ///     whatever the file holds.
    static func compose(
        items: [TranscriptItem],
        stream: TranscriptStreamSnapshot?,
        confirmedUUIDs: Set<String>,
        sessionEnded: Bool,
        streamingEnabled: Bool
    ) -> [TranscriptItem] {
        guard streamingEnabled, !sessionEnded, let stream else { return items }
        return items + provisionalItems(stream: stream, confirmedUUIDs: confirmedUUIDs)
    }

    /// The rows for every block of `stream` not yet confirmed, in step order.
    static func provisionalItems(
        stream: TranscriptStreamSnapshot,
        confirmedUUIDs: Set<String>
    ) -> [TranscriptItem] {
        let turnID = stream.turn?.id ?? "-"
        var rows: [TranscriptItem] = []
        for step in stream.steps {
            for (position, block) in step.blocks.enumerated() {
                if let uuid = block.uuid, confirmedUUIDs.contains(uuid) { continue }
                let id = "\(idPrefix)\(turnID):\(step.index):\(position)"
                switch block.kind {
                case .text:
                    let streaming = !block.ended && !step.ended
                    if block.text.isEmpty && !streaming { continue }
                    rows.append(.assistantText(
                        id: id, text: block.text + (streaming ? cursor : ""),
                        timestamp: nil, usage: nil))
                case .thinking:
                    guard !block.text.isEmpty else { continue }
                    rows.append(.thinking(id: id, text: block.text, timestamp: nil))
                case .other:
                    continue
                }
            }
        }
        return rows
    }
}
