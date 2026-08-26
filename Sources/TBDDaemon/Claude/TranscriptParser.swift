import Foundation
import os
import TBDShared

/// Loads a Claude Code session JSONL into a structured `[TranscriptItem]`.
///
/// This parser is deliberately permissive — malformed or unknown lines are
/// skipped rather than failing the whole session. JSONL writes from Claude
/// Code may be partial during live polling; we tolerate that.
enum TranscriptParser {
    private static let perfLog = Logger(subsystem: "com.tbd.daemon", category: "perf-transcript")
    /// Shared ISO8601 formatter that accepts Claude Code's fractional-seconds
    /// timestamps (e.g. `2026-05-05T03:06:16.813Z`). Without
    /// `.withFractionalSeconds`, every such timestamp silently fails to parse.
    /// `ISO8601DateFormatter` is documented as thread-safe for read-only use.
    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Parse a top-level Claude session JSONL into transcript items in file order.
    ///
    /// Only the PARENT file is read. Task/Agent tool calls render as ordinary
    /// tool cards (their description + result); the parser deliberately does NOT
    /// open the `<sessionID>/subagents/agent-*.jsonl` files. Recursively parsing
    /// every subagent transcript made opening a session with many subagents cost
    /// O(all subagent bytes) — ~13s on heavy sessions — for content the UI no
    /// longer surfaces. Parse cost is now O(parent file).
    static func parse(filePath: String) -> [TranscriptItem] {
        let basename = (filePath as NSString).lastPathComponent
        perfLog.debug("parse.start file=\(basename, privacy: .public)")
        let start = ContinuousClock.now
        var totalBytes = 0
        let result = parse(filePath: filePath, totalBytes: &totalBytes)
        let elapsed = ContinuousClock.now - start
        let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        perfLog.debug("parse.end file=\(basename, privacy: .public) elapsed_ms=\(ms, privacy: .public) items=\(result.count, privacy: .public) bytes=\(totalBytes, privacy: .public)")
        return result
    }

    /// Worker that reads a single Claude JSONL file. Sidechain (subagent) lines
    /// in the parent file are skipped; subagent files are never opened.
    private static func parse(
        filePath: String,
        totalBytes: inout Int
    ) -> [TranscriptItem] {
        guard let data = FileManager.default.contents(atPath: filePath),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }
        totalBytes += data.count

        // First pass: collect raw line dicts; index tool_results.
        var rawLines: [[String: Any]] = []
        // Parallel to rawLines. Stable per-line identifier used as a fallback
        // when a line is missing the `uuid` field. Using a fresh UUID() here
        // would make the poll loops' TranscriptPollDiff.changed permanently
        // true for that item (forcing a @Published write on every poll). Line
        // index is process-stable and
        // cheap; in practice every Claude JSONL line carries a `uuid` so this
        // fallback is defensive.
        var stableIDs: [String] = []
        var toolResultsByID: [String: ToolResult] = [:]

        var lineIndex = 0
        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            defer { lineIndex += 1 }
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            rawLines.append(json)
            stableIDs.append((json["uuid"] as? String) ?? "line-\(lineIndex)")

            if json["type"] as? String == "user",
               let message = json["message"] as? [String: Any],
               let array = message["content"] as? [[String: Any]] {
                let toolResultBlocks = array.filter { ($0["type"] as? String) == "tool_result" }
                for block in toolResultBlocks {
                    guard let id = block["tool_use_id"] as? String else { continue }
                    toolResultsByID[id] = extractToolResult(from: block)
                }
            }
        }

        return buildItems(rawLines: rawLines, stableIDs: stableIDs, toolResultsByID: toolResultsByID)
    }

    /// Tail-parse path: returns only the LAST `limit` visible items, fast.
    ///
    /// Approach: read ONLY the last `chunkBytes` of the file (seek to
    /// `max(0, fileSize - chunkBytes)`, read to EOF) instead of the whole file.
    /// On a ~30MB JSONL we therefore decode/split a few hundred KB rather than
    /// 30MB — the full-file UTF8 decode + line-split was the dominant cost
    /// (~910ms measured) even though we only JSON-parse the last few lines.
    ///
    /// The chunk usually starts mid-line. We find the FIRST newline in the chunk
    /// and discard everything up to and including it (the partial leading line) —
    /// UNLESS the chunk started at offset 0 (whole file fit), in which case we
    /// keep all of it. Dropping the partial prefix also sidesteps a possible
    /// mid-UTF8-character split at the seek boundary.
    ///
    /// Correctness guard: if the chunk yields FEWER than `limit` visible items
    /// (very large items, or a tiny tail window), we double `chunkBytes` and
    /// retry, up to the full file size — so edge cases stay correct. In the
    /// common case the first ~1MB chunk holds far more than `limit` items and no
    /// retry happens.
    ///
    /// Identical-bottom guarantee: this calls the SAME `buildItems` helper as
    /// the full parse, so the items it produces for the windowed lines are
    /// byte-identical to the corresponding bottom of the full parse — the
    /// tail→full UI swap therefore does not shift the visible bottom.
    static func parseTail(filePath: String, limit: Int) -> [TranscriptItem] {
        guard let handle = FileHandle(forReadingAtPath: filePath) else { return [] }
        defer { try? handle.close() }
        guard let fileSize = (try? handle.seekToEnd()).map({ Int($0) }) else { return [] }

        // Start ~1MB; far below a 30MB file, far above `limit` items of lines.
        var chunkBytes = 1 << 20

        while true {
            let readSize = min(chunkBytes, fileSize)
            let offset = fileSize - readSize
            let coveredWholeFile = offset == 0

            guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
                  let chunk = try? handle.readToEnd() else {
                return []
            }

            // Drop the partial leading line unless we read from offset 0.
            // The bytes up to and including the first '\n' are a line fragment
            // (and may straddle a UTF8 character); discarding them is safe.
            let bytes: Data
            if coveredWholeFile {
                bytes = chunk
            } else if let nl = chunk.firstIndex(of: UInt8(ascii: "\n")) {
                bytes = chunk[chunk.index(after: nl)...]
            } else {
                // No newline in the chunk: the tail is one giant partial line.
                // Grow (or give up if we already read the whole file).
                bytes = Data()
            }

            if let content = String(data: bytes, encoding: .utf8) {
                let items = parseTailWindow(content: content)
                if items.count >= limit || coveredWholeFile {
                    return Array(items.suffix(limit))
                }
            } else if coveredWholeFile {
                // Whole file isn't decodable as UTF8 — match the empty contract.
                return []
            }

            // Underflow (or undecodable chunk): grow and retry.
            if coveredWholeFile { return [] }
            chunkBytes *= 2
        }
    }

    /// Parse a decoded tail window (a suffix of the file's lines, each line
    /// whole) into transcript items. Builds a window-local `toolResultsByID` so
    /// a tool_use+tool_result pair within the window folds together; a tool_use
    /// whose result fell outside the window renders without a result —
    /// acceptable, matching today's behavior at any truncation boundary.
    ///
    /// stableIDs here use a "tail-<n>" fallback only for synthetic/malformed
    /// lines that lack a `uuid`; real Claude lines always carry one, so the
    /// fallback never participates in the tail→full identical-bottom comparison.
    private static func parseTailWindow(content: String) -> [TranscriptItem] {
        var rawLines: [[String: Any]] = []
        var stableIDs: [String] = []
        var toolResultsByID: [String: ToolResult] = [:]

        var lineIndex = 0
        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            defer { lineIndex += 1 }
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            rawLines.append(json)
            stableIDs.append((json["uuid"] as? String) ?? "tail-\(lineIndex)")

            if json["type"] as? String == "user",
               let message = json["message"] as? [String: Any],
               let array = message["content"] as? [[String: Any]] {
                let toolResultBlocks = array.filter { ($0["type"] as? String) == "tool_result" }
                for block in toolResultBlocks {
                    guard let id = block["tool_use_id"] as? String else { continue }
                    toolResultsByID[id] = extractToolResult(from: block)
                }
            }
        }

        return buildItems(rawLines: rawLines, stableIDs: stableIDs, toolResultsByID: toolResultsByID)
    }

    /// Shared core: turn an array of raw line dicts (+ parallel stableIDs and a
    /// tool_use_id→result index) into `[TranscriptItem]`. Both the full `parse`
    /// and the tail `parseTail` call this, guaranteeing the tail's items are
    /// byte-identical to the bottom of the full parse for the same lines.
    ///
    /// That guarantee holds only while this stays a pure function of the lines
    /// it is handed: every item must be derivable from its own row. Do not add
    /// cross-row state (a "have I already emitted this text?" set, say) — the
    /// tail path passes only the lines inside its byte window, so any such
    /// state starts empty there and the tail would emit rows the full parse
    /// suppresses.
    private static func buildItems(
        rawLines: [[String: Any]],
        stableIDs: [String],
        toolResultsByID: [String: ToolResult]
    ) -> [TranscriptItem] {
        var items: [TranscriptItem] = []

        for (i, json) in rawLines.enumerated() {
            // Subagent (sidechain) lines belong to a nested agent's own
            // conversation; the parent transcript drops them entirely.
            if json["isSidechain"] as? Bool == true { continue }

            let lineUUID = stableIDs[i]
            let timestamp = (json["timestamp"] as? String).flatMap { iso8601.date(from: $0) }
            let typeStr = json["type"] as? String

            // A prompt typed while the agent was mid-turn is QUEUED, and Claude
            // Code never writes a `type:"user"` line for it — the delivery is
            // recorded only as this attachment. Route its text through the same
            // classification and emit decision as a typed prompt so the two
            // recording shapes render identically.
            //
            // "Queued" covers more than human typing: peer traffic
            // (`<agent-message>`, `<cross-session-message>`) arrives this way
            // and this way only. Those envelopes match no system prefix, so
            // they classify as real prompts and render as bubbles. That is the
            // intent — they are messages this session received, and the
            // alternative is the pre-fix behavior of dropping them silently.
            //
            // Deliberately NOT `truncate`d, unlike the injected-context
            // attachment branch below: this is delivered input rather than
            // injected context, and a prompt that arrived on a `type:"user"`
            // line is not truncated either. Truncating here would make the
            // same prompt render
            // differently depending on when it landed, which is the whole
            // defect being fixed. The measured cost is a median of ~6 KB of
            // extra body per session.
            if typeStr == "attachment", let text = queuedCommandText(from: json) {
                items.append(promptItem(
                    id: lineUUID,
                    kind: UserMessageClassifier.classify(text: text),
                    text: text,
                    timestamp: timestamp))
                continue
            }

            // Hook- and CLAUDE.md-injected context arrives as `type:"attachment"`
            // rows, which carry no `message` and so match none of the branches
            // below. Always `continue` — an attachment never falls through.
            if typeStr == "attachment" {
                let payloads = attachmentPayloads(from: json)
                for (index, payload) in payloads.enumerated() {
                    let (truncated, originalCount) = truncate(payload.text)
                    items.append(.systemReminder(
                        id: payloads.count > 1 ? "\(lineUUID)#\(index)" : lineUUID,
                        kind: payload.kind,
                        text: truncated,
                        timestamp: timestamp,
                        source: payload.source,
                        truncatedTo: originalCount == truncated.count ? nil : originalCount
                    ))
                }
                continue
            }

            // A message delivered from another Claude session. The receiving
            // harness records the sender on the row itself, so this classifies
            // ahead of the user branches below — otherwise the delivery
            // envelope renders as something the user typed.
            //
            // Purity holds: `PeerOriginExtractor` reads only this row's
            // `origin` dictionary and its own content string, so a tail window
            // that contains the row derives the same item the full parse does.
            if typeStr == "user", let peer = PeerOriginExtractor.extract(from: json) {
                items.append(.peerMessage(
                    id: lineUUID,
                    sender: peer.sender,
                    text: peer.text,
                    deliveredPayload: peer.deliveredPayload,
                    timestamp: timestamp))
                continue
            }

            if typeStr == "user", let kind = UserMessageClassifier.classify(json) {
                items.append(promptItem(
                    id: lineUUID,
                    kind: kind,
                    text: extractUserText(from: json) ?? "",
                    timestamp: timestamp))
                continue
            }

            if typeStr == "user", UserMessageClassifier.isRealUserMessage(json),
               let text = UserMessageClassifier.extractText(json) {
                items.append(promptItem(id: lineUUID, kind: nil, text: text, timestamp: timestamp))
                continue
            }

            if typeStr == "assistant" {
                guard let message = json["message"] as? [String: Any] else { continue }
                let usage = extractUsage(from: message)

                // String-content fallback (matches existing scanner behavior).
                if let s = message["content"] as? String {
                    if !s.isEmpty {
                        items.append(.assistantText(id: "\(lineUUID)#0", text: s, timestamp: timestamp, usage: usage))
                    }
                    continue
                }

                guard let blocks = message["content"] as? [[String: Any]] else { continue }
                for (index, block) in blocks.enumerated() {
                    let blockID = "\(lineUUID)#\(index)"
                    let blockType = block["type"] as? String
                    switch blockType {
                    case "thinking":
                        let text = (block["thinking"] as? String) ?? ""
                        items.append(.thinking(id: blockID, text: text, timestamp: timestamp))
                    case "text":
                        let text = (block["text"] as? String) ?? ""
                        if !text.isEmpty {
                            items.append(.assistantText(id: blockID, text: text, timestamp: timestamp, usage: usage))
                        }
                    case "tool_use":
                        let toolID = (block["id"] as? String) ?? blockID
                        let name = (block["name"] as? String) ?? ""
                        let rawInput = block["input"] ?? [:]
                        let (truncatedInput, didTruncate) = truncateInputStrings(rawInput)
                        let inputData = (try? JSONSerialization.data(
                            withJSONObject: didTruncate ? truncatedInput : rawInput,
                            options: [.sortedKeys])) ?? Data()
                        let inputJSON = String(data: inputData, encoding: .utf8) ?? "{}"
                        let inputTruncatedTo: Int? = {
                            guard didTruncate,
                                  let d = try? JSONSerialization.data(withJSONObject: rawInput, options: [.sortedKeys]),
                                  let s = String(data: d, encoding: .utf8) else { return nil }
                            return s.count
                        }()
                        let result = toolResultsByID[toolID]

                        // Task/Agent tool calls render as ordinary tool cards.
                        // We never open the nested subagent transcript, so
                        // `subagent` is always nil.
                        items.append(.toolCall(
                            id: toolID, name: name, inputJSON: inputJSON,
                            inputTruncatedTo: inputTruncatedTo,
                            result: result, subagent: nil, timestamp: timestamp,
                            usage: usage
                        ))
                    default:
                        continue
                    }
                }
            }
        }

        return items
    }

    /// The item one prompt renders as, given its body and its classification.
    ///
    /// The single emit decision for user-authored input, shared by the
    /// `type:"user"` line branch and the `queued_command` attachment branch —
    /// a prompt must look the same whether it was typed at an idle agent or
    /// queued mid-turn, and one helper is what keeps the two from drifting.
    ///
    /// NOTE: TranscriptItem.slashCommand is no longer emitted — slash commands
    /// are flattened into .userPrompt so they render as the user's chat bubble
    /// (the slash command IS what the user typed). The case remains in the
    /// enum for Codable compatibility with any persisted state.
    private static func promptItem(
        id: String, kind: SystemKind?, text: String, timestamp: Date?
    ) -> TranscriptItem {
        guard let kind else {
            return .userPrompt(id: id, text: text, timestamp: timestamp)
        }
        guard kind == .slashEnvelope else {
            return .systemReminder(id: id, kind: kind, text: text, timestamp: timestamp)
        }
        let (name, args) = parseSlashEnvelope(text)
        let bubbleText: String
        if let args, !args.isEmpty {
            bubbleText = "/\(name) \(args)"
        } else {
            bubbleText = "/\(name)"
        }
        return .userPrompt(id: id, text: bubbleText, timestamp: timestamp)
    }

    /// The prompt body of a `queued_command` attachment, or nil for every other
    /// row. `attachment.prompt` is usually a String but is an array of content
    /// blocks for a multimodal paste, in which case every `text` block joins —
    /// the same rule `UserMessageClassifier.extractText` applies to a
    /// `type:"user"` line's content array. Both shapes are measured, not
    /// assumed: across 701 local session JSONLs, 5876 of 5887 queued rows
    /// carry a String and 11 carry the array form — a paste of one `text`
    /// block alongside a base64 `image` block.
    ///
    /// Every other shape — `prompt` absent, empty, an empty array, an array
    /// whose blocks carry no text, a number, an object, an array of bare
    /// strings — returns nil, and the row then falls through to the general
    /// attachment branch, which has no `queued_command` case and emits
    /// nothing. That is exactly where such a row sat before this function
    /// existed: an empty bubble would be worse than no bubble.
    ///
    /// The sibling `enqueue`/`remove`/`dequeue` rows are queue bookkeeping,
    /// not the delivery record. They are a distinct TOP-LEVEL
    /// `type:"queue-operation"` rather than an attachment flavor, so they fail
    /// the first guard below and reach no rendering path — which is what keeps
    /// one queued prompt from rendering once per queue event.
    static func queuedCommandText(from json: [String: Any]) -> String? {
        guard json["type"] as? String == "attachment",
              let att = json["attachment"] as? [String: Any],
              att["type"] as? String == "queued_command" else {
            return nil
        }
        if let s = att["prompt"] as? String {
            return s.isEmpty ? nil : s
        }
        if let blocks = att["prompt"] as? [[String: Any]] {
            return UserMessageClassifier.joinTextBlocks(blocks)
        }
        return nil
    }

    /// Extract a `TokenUsage` from `message.usage` if all three input-token
    /// fields are present. Output tokens, cache breakdowns, and other fields
    /// are ignored — we only care about the prompt-size signal.
    private static func extractUsage(from message: [String: Any]) -> TokenUsage? {
        guard let usage = message["usage"] as? [String: Any],
              let input = usage["input_tokens"] as? Int else {
            return nil
        }
        // Cache fields are optional in the Anthropic API: users without
        // prompt caching enabled emit `usage` blocks that omit them
        // entirely. Default to 0 so the badge still surfaces a token count
        // for those sessions.
        let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        return TokenUsage(
            inputTokens: input,
            cacheCreationTokens: cacheCreation,
            cacheReadTokens: cacheRead
        )
    }

    // MARK: - attachments

    /// One renderable payload extracted from a `type: "attachment"` JSONL row.
    struct AttachmentPayload: Equatable {
        let kind: SystemKind
        /// Where the context came from: a CLAUDE.md display path, a hook name.
        let source: String
        let text: String
    }

    /// Extracts every injected-context payload from one JSONL row, in emission
    /// order. Returns `[]` for non-attachment rows and for flavors that carry
    /// no injected *prose* context: `*_delta`, `command_permissions`,
    /// `diagnostics`, and `edited_text_file` have no `content` field at all,
    /// while `task_reminder`'s `content` is a structured array of todo objects,
    /// not renderable text. `queued_command` has no `content` either — it
    /// carries a delivered *prompt* rather than injected context, and is
    /// handled by `queuedCommandText(from:)`. (Measured: 0 of 5887
    /// `queued_command` rows in the local corpus carry a `content` field.)
    ///
    /// `attachment.content` has a DIFFERENT native JSON type per flavor —
    /// object for `nested_memory`, array for `hook_additional_context`, string
    /// for the rest — so a single `as? String` silently drops the two largest
    /// sources of injected context.
    ///
    /// Shared by `buildItems` and `lookupFullBody` so the collapsed row and the
    /// click-to-open overlay can never disagree about what a row contains.
    ///
    /// Extraction is per-row and stateless — no cross-row dedup — which is what
    /// keeps `buildItems` a pure function of the lines it is handed and
    /// preserves `parseTail`'s identical-bottom guarantee.
    static func attachmentPayloads(from json: [String: Any]) -> [AttachmentPayload] {
        guard json["type"] as? String == "attachment",
              let att = json["attachment"] as? [String: Any],
              let rawType = att["type"] as? String else {
            return []
        }

        func hookName() -> String { (att["hookName"] as? String) ?? "hook" }

        switch rawType {
        case "nested_memory":
            // `content` is an object `{path, type, content}`; the CLAUDE.md
            // body is one level deeper.
            guard let inner = att["content"] as? [String: Any],
                  let body = inner["content"] as? String, !body.isEmpty else { return [] }
            let source = injectedPathSource(
                displayPath: att["displayPath"] as? String,
                absolutePath: (att["path"] as? String) ?? (inner["path"] as? String),
                filename: nil
            ) ?? "CLAUDE.md"
            return [AttachmentPayload(kind: .nestedMemory, source: source, text: body)]

        case "file":
            // An @-mentioned file's body, injected verbatim into the context
            // window. Same shape as `nested_memory` — `content` is an object,
            // the body one level deeper at `content.file.content` — and the
            // same *thing*: a file's text pasted into the prompt. Reusing
            // `.nestedMemory` (not `.hookOutput`, which would badge a file
            // body as hook stdout) rather than adding a case; the badge is now
            // "file" for both, and the source segment carries the actual path,
            // which is what distinguished a CLAUDE.md row anyway.
            guard let inner = att["content"] as? [String: Any],
                  let file = inner["file"] as? [String: Any],
                  let body = file["content"] as? String, !body.isEmpty else { return [] }
            let source = injectedPathSource(
                displayPath: att["displayPath"] as? String,
                absolutePath: file["filePath"] as? String,
                filename: att["filename"] as? String
            ) ?? "file"
            return [AttachmentPayload(kind: .nestedMemory, source: source, text: body)]

        case "hook_additional_context":
            // `content` is an array of strings — one entry per injected block.
            let strings = (att["content"] as? [Any])?.compactMap { $0 as? String } ?? []
            return strings.filter { !$0.isEmpty }.map {
                AttachmentPayload(kind: .hookOutput, source: hookName(), text: $0)
            }

        case "hook_success":
            // ONLY the plain-text `content` branch. `stdout`'s
            // `hookSpecificOutput.additionalContext` is deliberately NOT read:
            // measured across 120+ real sessions, every such payload is also
            // present in a `hook_additional_context` row — either verbatim (130
            // cases) or as the `<persisted-output>` notice that REPLACED an
            // oversized payload (all 11 apparent orphans). `hook_additional_context`
            // is what actually entered the context window; a hook's stdout is
            // merely what it emitted. Rendering only the former is therefore
            // both non-redundant and more truthful — and, because the rule is
            // per-row rather than a cross-row dedup set, it keeps `buildItems`
            // a pure function of its window (see `parseTail`'s identical-bottom
            // guarantee). `content` itself is never mirrored in hac (221/221
            // unique) so it stays.
            guard let s = att["content"] as? String, !s.isEmpty else { return [] }
            return [AttachmentPayload(kind: .hookOutput, source: hookName(), text: s)]

        case "skill_listing":
            guard let s = att["content"] as? String, !s.isEmpty else { return [] }
            return [AttachmentPayload(kind: .hookOutput, source: "skills", text: s)]

        default:
            return []
        }
    }

    /// The path to show for an injected file body, in preference order:
    ///
    /// 1. A `displayPath` that stays inside the repo (`.github/CLAUDE.md`) —
    ///    already the nicest form, and what the row has always rendered.
    /// 2. The absolute path with `$HOME` collapsed to `~`, when `displayPath`
    ///    is missing or *escapes* the repo. Claude Code writes escaping paths
    ///    relative to the cwd, so a file in `/private/tmp` arrives as
    ///    `../../../../../../private/tmp/…`, which truncates to nothing useful.
    /// 3. The `filename`, or the display path's last component.
    ///
    /// Never returns a `../` prefix. The daemon runs as the same user as the
    /// app, so `NSHomeDirectory()` abbreviates identically on either side.
    ///
    /// The abbreviation goes through `abbreviatingWithTildeInPath`, which only
    /// matches on path-component boundaries. A substring replace would turn
    /// `/Users/melog-archive/x` into `~log-archive/x` and
    /// `/Volumes/T7/Users/me/x` into `/Volumes/T7~/x`.
    static func injectedPathSource(
        displayPath: String?, absolutePath: String?, filename: String?
    ) -> String? {
        if let displayPath, !displayPath.isEmpty, !displayPath.hasPrefix("../") { return displayPath }
        if let absolutePath, !absolutePath.isEmpty {
            return (absolutePath as NSString).abbreviatingWithTildeInPath
        }
        if let filename, !filename.isEmpty { return filename }
        if let displayPath, !displayPath.isEmpty { return (displayPath as NSString).lastPathComponent }
        return nil
    }

    /// The injection mechanism behind one attachment row: which hook ran, with
    /// what command and exit status, or which memory tier / file path was
    /// loaded — plus the tool call that triggered it, resolved through
    /// `attachment.toolUseID`.
    ///
    /// Deliberately NOT carried on `TranscriptItem`: it is only ever read when
    /// a row is opened, so it rides the `terminal.transcriptItemFullBody`
    /// round-trip the overlay already makes instead of costing a switch site
    /// per associated value.
    ///
    /// `toolSummaries` maps `tool_use.id` → its short summary. Attribution is
    /// resolved strictly through that map: `nil` when the row carries no
    /// `toolUseID` (every `nested_memory` / `file` row) or when the id names a
    /// `tool_use` the scan never saw. Position and proximity are never used —
    /// no field links a CLAUDE.md load to the Read that touched its directory,
    /// and guessing one would look authoritative while being wrong.
    static func attachmentMetadata(
        from json: [String: Any], toolSummaries: [String: String]
    ) -> TranscriptAttachmentMetadata? {
        guard json["type"] as? String == "attachment",
              let att = json["attachment"] as? [String: Any],
              let rawType = att["type"] as? String else {
            return nil
        }

        func text(_ key: String) -> String? {
            guard let s = att[key] as? String,
                  !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return s
        }

        let inner = att["content"] as? [String: Any]
        let file = inner?["file"] as? [String: Any]
        let metadata = TranscriptAttachmentMetadata(
            hookName: text("hookName"),
            hookEvent: text("hookEvent"),
            command: text("command"),
            exitCode: att["exitCode"] as? Int,
            durationMs: att["durationMs"] as? Int,
            stderr: text("stderr"),
            // Only meaningful for a memory row ("Project", "User", …); a
            // `file` row's inner type is just "text".
            memoryType: rawType == "nested_memory" ? inner?["type"] as? String : nil,
            path: (att["path"] as? String) ?? (inner?["path"] as? String) ?? (file?["filePath"] as? String),
            triggeredBy: (att["toolUseID"] as? String).flatMap { toolSummaries[$0] }
        )
        return metadata.isEmpty ? nil : metadata
    }

    /// `"Read ai-review-gate.yml"` — a tool call named by the scrap of input
    /// that identifies it. Intentionally a small local summarizer: the richer
    /// app-side one lives in `ActivityRowFormatter` (module `TBDApp`) and is
    /// not reachable from the daemon.
    static func toolInputSummary(name: String, input: [String: Any]) -> String {
        func short(_ s: String, limit: Int = 40) -> String {
            let oneLine = s.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return oneLine.count > limit ? "\(oneLine.prefix(limit))…" : oneLine
        }
        let detail: String? = {
            if let p = input["file_path"] as? String, !p.isEmpty { return (p as NSString).lastPathComponent }
            if let d = input["description"] as? String, !d.isEmpty { return short(d) }
            if let c = input["command"] as? String, !c.isEmpty { return short(c) }
            if let p = input["pattern"] as? String, !p.isEmpty { return short(p) }
            if let p = input["path"] as? String, !p.isEmpty { return (p as NSString).lastPathComponent }
            return nil
        }()
        guard let detail, !detail.isEmpty else { return name }
        return name.isEmpty ? detail : "\(name) \(detail)"
    }

    // MARK: - helpers

    static let bodyCharCap = 2000
    static let bodyLineCap = 20

    static func extractToolResult(from block: [String: Any]) -> ToolResult {
        let isError = (block["is_error"] as? Bool) ?? false
        let raw: String
        if let s = block["content"] as? String {
            raw = s
        } else if let array = block["content"] as? [[String: Any]] {
            raw = array.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
            raw = ""
        }

        let (truncated, originalCount) = truncate(raw)
        return ToolResult(
            text: truncated,
            truncatedTo: originalCount == truncated.count ? nil : originalCount,
            isError: isError
        )
    }

    /// Returns (truncatedText, originalCharLength). The caller compares
    /// lengths to decide whether to set `truncatedTo`.
    static func truncate(_ text: String) -> (String, Int) {
        let originalCount = text.count
        var capped = text
        if originalCount > bodyCharCap {
            capped = String(text.prefix(bodyCharCap))
        }
        let lines = capped.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > bodyLineCap {
            capped = lines.prefix(bodyLineCap).joined(separator: "\n")
        }
        return (capped, originalCount)
    }

    /// Walks `input` recursively and replaces any string value exceeding the
    /// configured caps with its truncated form. Returns (newInput, anyTruncated).
    static func truncateInputStrings(_ input: Any) -> (Any, Bool) {
        if let s = input as? String {
            let (capped, originalCount) = truncate(s)
            return (capped, originalCount != capped.count)
        }
        if let dict = input as? [String: Any] {
            var out: [String: Any] = [:]
            var anyTrunc = false
            for (k, v) in dict {
                let (newV, t) = truncateInputStrings(v)
                out[k] = newV
                if t { anyTrunc = true }
            }
            return (out, anyTrunc)
        }
        if let arr = input as? [Any] {
            var out: [Any] = []
            var anyTrunc = false
            for v in arr {
                let (newV, t) = truncateInputStrings(v)
                out.append(newV)
                if t { anyTrunc = true }
            }
            return (out, anyTrunc)
        }
        return (input, false)
    }

    static func extractUserText(from json: [String: Any]) -> String? {
        guard let message = json["message"] as? [String: Any] else { return nil }
        if let s = message["content"] as? String { return s }
        if let array = message["content"] as? [[String: Any]] {
            return array.first(where: { $0["type"] as? String == "text" })
                .flatMap { $0["text"] as? String }
        }
        return nil
    }

    /// Returns the un-truncated body text for an item id, or nil if not found.
    /// itemID forms:
    ///  - `tool_use_id` (e.g. "toolu_abc") → returns the matching tool_result content
    ///  - `<tool_use_id>#input` → returns the un-truncated `tool_use.input` JSON
    ///  - `<lineUUID>#<blockIndex>` → returns the assistant block's text/thinking,
    ///    or the Nth injected payload of a multi-payload attachment row
    ///  - bare `lineUUID` → returns the user message content, or the sole
    ///    injected payload of an attachment row
    static func lookupFullBody(filePath: String, itemID: String) -> String? {
        lookupDetail(filePath: filePath, itemID: itemID).text
    }

    /// What one opened row can recover from the JSONL: its un-truncated body
    /// plus, for `attachment` rows, how the context got injected.
    struct ItemDetail {
        let text: String?
        let attachment: TranscriptAttachmentMetadata?
    }

    /// `lookupFullBody` plus the injection metadata. Same single pass, same id
    /// forms — see `lookupFullBody` for the id grammar.
    static func lookupDetail(filePath: String, itemID: String) -> ItemDetail {
        guard let data = FileManager.default.contents(atPath: filePath),
              let content = String(data: data, encoding: .utf8) else {
            return ItemDetail(text: nil, attachment: nil)
        }

        // Detect the `#input` suffix variant first — when present, we ONLY scan
        // assistant tool_use blocks for a matching id and return their full input
        // JSON. Other branches are skipped because the unsuffixed id would
        // otherwise fall into the tool_result / uuid scans.
        let inputSuffix = "#input"
        let isInputLookup = itemID.hasSuffix(inputSuffix)
        let toolUseIDForInput: String? = isInputLookup
            ? String(itemID.dropLast(inputSuffix.count))
            : nil

        // Parse the composite id form for the non-input branches.
        let lineUUID: String
        let blockIndex: Int?
        if !isInputLookup, let hashIdx = itemID.firstIndex(of: "#") {
            lineUUID = String(itemID[..<hashIdx])
            blockIndex = Int(itemID[itemID.index(after: hashIdx)...])
        } else {
            lineUUID = itemID
            blockIndex = nil
        }

        // `tool_use.id` → short summary, for resolving an attachment row's
        // `toolUseID`. Accumulated as the scan walks down: a hook fires after
        // the assistant emitted the tool call, so the triggering `tool_use`
        // line is always already behind us when its attachment row appears.
        var toolSummaries: [String: String] = [:]

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            if let toolUseID = toolUseIDForInput {
                // Only scan assistant tool_use blocks; ignore tool_result/uuid branches.
                if let message = json["message"] as? [String: Any],
                   let array = message["content"] as? [[String: Any]] {
                    for block in array where block["type"] as? String == "tool_use" {
                        if (block["id"] as? String) == toolUseID {
                            let input = block["input"] ?? [:]
                            if let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
                               let s = String(data: data, encoding: .utf8) {
                                return ItemDetail(text: s, attachment: nil)
                            }
                        }
                    }
                }
                continue
            }

            if let message = json["message"] as? [String: Any],
               let array = message["content"] as? [[String: Any]] {
                for block in array {
                    switch block["type"] as? String {
                    case "tool_use":
                        guard let id = block["id"] as? String else { continue }
                        toolSummaries[id] = toolInputSummary(
                            name: (block["name"] as? String) ?? "",
                            input: (block["input"] as? [String: Any]) ?? [:])
                    case "tool_result":
                        // tool_use_id match — the un-truncated result content.
                        guard (block["tool_use_id"] as? String) == itemID else { continue }
                        if let s = block["content"] as? String {
                            return ItemDetail(text: s, attachment: nil)
                        }
                        if let inner = block["content"] as? [[String: Any]] {
                            return ItemDetail(
                                text: inner.compactMap { $0["text"] as? String }.joined(separator: "\n"),
                                attachment: nil)
                        }
                    default:
                        continue
                    }
                }
            }

            // line UUID match.
            if (json["uuid"] as? String) == lineUUID {
                // Attachment rows carry no `message`, so the branches below
                // can never recover their (truncated) body. Re-run the same
                // extraction `buildItems` used and return it whole, alongside
                // the injection metadata the overlay renders.
                // A queued prompt is an attachment row too, but it renders as
                // the user's own bubble rather than an injected-context row.
                if let queued = queuedCommandText(from: json) {
                    return ItemDetail(text: queued, attachment: nil)
                }

                let payloads = attachmentPayloads(from: json)
                if !payloads.isEmpty {
                    let meta = attachmentMetadata(from: json, toolSummaries: toolSummaries)
                    if payloads.count > 1 {
                        guard let blockIndex, blockIndex < payloads.count else {
                            return ItemDetail(text: nil, attachment: meta)
                        }
                        return ItemDetail(text: payloads[blockIndex].text, attachment: meta)
                    }
                    return ItemDetail(text: payloads[0].text, attachment: meta)
                }

                if let blockIndex,
                   let message = json["message"] as? [String: Any],
                   let blocks = message["content"] as? [[String: Any]],
                   blockIndex < blocks.count {
                    let block = blocks[blockIndex]
                    return ItemDetail(
                        text: (block["text"] as? String) ?? (block["thinking"] as? String),
                        attachment: nil)
                }
                if let message = json["message"] as? [String: Any] {
                    if let s = message["content"] as? String {
                        return ItemDetail(text: s, attachment: nil)
                    }
                    if let array = message["content"] as? [[String: Any]] {
                        return ItemDetail(
                            text: array.first(where: { $0["type"] as? String == "text" })
                                .flatMap { $0["text"] as? String },
                            attachment: nil)
                    }
                }
            }
        }
        return ItemDetail(text: nil, attachment: nil)
    }

    /// Parse `<command-name>foo</command-name><command-args>bar</command-args>` envelopes.
    /// Returns the command name (without leading `/`) and optional args text.
    static func parseSlashEnvelope(_ text: String) -> (name: String, args: String?) {
        func extract(_ tag: String) -> String? {
            let open = "<\(tag)>"
            let close = "</\(tag)>"
            guard let openRange = text.range(of: open),
                  let closeRange = text.range(of: close, range: openRange.upperBound..<text.endIndex) else {
                return nil
            }
            return String(text[openRange.upperBound..<closeRange.lowerBound])
        }
        let raw = extract("command-name") ?? ""
        let name = raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
        let args = extract("command-args")
        return (name, args?.isEmpty == true ? nil : args)
    }
}
