import Foundation

/// Determines whether a decoded JSONL line is a real user-authored message
/// vs. a tool result, system reminder, compaction summary, or other
/// system-generated content.
///
/// This is the single place to update detection heuristics. The fixture at
/// Tests/Fixtures/sample-session.jsonl documents the classification decisions.
///
/// A compaction summary is recognized by the structured `isCompactSummary`
/// flag Claude Code sets on its line, never by its text. Only the
/// dictionary-shaped entry points can see that flag; the `text:` entry points
/// serve `queued_command` attachments, which never carry it.
public enum UserMessageClassifier {

    /// Prefixes that mark system-generated content in the user role.
    private static let systemPrefixes: [String] = [
        "<system-reminder",
        "<command-",
        "<tool_result",
        "<local-command-",
        "<environment_details",
        // Background-task notification envelopes injected into the user role
        // (both the bare tag and the SYSTEM NOTIFICATION preamble form).
        "<task-notification",
        "[SYSTEM NOTIFICATION",
    ]

    /// Case-insensitive substrings that mark injected context blocks (checked after trimming leading `# `).
    private static let injectedContextPrefixes: [String] = [
        "git repository context",
        "repository context",
        "current working directory:",
    ]

    /// Returns true if the parsed JSONL object is a real user message.
    ///
    /// A compaction summary is not: Claude Code writes it into the user role,
    /// but nobody typed it.
    public static func isRealUserMessage(_ line: [String: Any]) -> Bool {
        guard
            line["type"] as? String == "user",
            let message = line["message"] as? [String: Any],
            message["role"] as? String == "user"
        else { return false }

        if isCompactSummary(line) { return false }

        if let content = message["content"] as? String {
            return isRealUserMessage(text: content)
        }

        if let array = message["content"] as? [[String: Any]] {
            // All tool_result blocks → not a real message
            if array.allSatisfy({ $0["type"] as? String == "tool_result" }) {
                return false
            }
            // Check the first text block's content
            if let firstText = array.first(where: { $0["type"] as? String == "text" }),
               let text = firstText["text"] as? String {
                return isRealUserMessage(text: text)
            }
            return false
        }

        return false
    }

    /// Returns true if a prompt *body* is user-authored rather than a system
    /// envelope.
    ///
    /// Claude Code records the same prompt two different ways depending on when
    /// it lands: typed while the agent is idle it becomes a `type:"user"` line,
    /// while a prompt queued mid-turn is only ever recorded as a
    /// `queued_command` attachment carrying the raw text. Both shapes must
    /// classify identically, so the rule lives here on the text and the
    /// dictionary-shaped entry points above delegate to it.
    public static func isRealUserMessage(text: String) -> Bool {
        !hasSystemPrefix(text)
    }

    /// Extracts display text from a real user message line. Returns nil if empty.
    /// Precondition: call only on lines that pass `isRealUserMessage` — behavior
    /// on other line types is undefined.
    public static func extractText(_ line: [String: Any]) -> String? {
        guard let message = line["message"] as? [String: Any] else { return nil }

        if let text = message["content"] as? String {
            return text.isEmpty ? nil : text
        }

        if let array = message["content"] as? [[String: Any]] {
            return joinTextBlocks(array)
        }

        return nil
    }

    /// Joins EVERY `text` block of a content-block array, not just the first.
    /// Claude Code emits one text block PER attached image when it records
    /// where it spooled them (`[Image: source: …]`), so taking only the first
    /// silently dropped every image after the first in a multi-image paste. In
    /// the measured corpus that meta line is the only user message that ever
    /// carries more than one text block, so joining is a strict repair.
    ///
    /// The same rule serves `queued_command.prompt`'s array form, which the
    /// original measurement did not cover. Re-measured for that call site: the
    /// array form appears on 11 queued rows in the local corpus and none carry
    /// more than one text block, so joining is a strict repair there too.
    ///
    /// Returns nil when no non-empty text block is present.
    public static func joinTextBlocks(_ blocks: [[String: Any]]) -> String? {
        let texts = blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .filter { !$0.isEmpty }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    /// Returns the typed system kind for a user-role JSONL line if it's a
    /// system-injected envelope rather than a real user prompt; returns nil
    /// for real user messages.
    ///
    /// A compaction summary is `.compactSummary`, decided by the line's
    /// `isCompactSummary` flag before any of the text-based rules run: its
    /// body is ordinary prose that no text rule would catch.
    public static func classify(_ line: [String: Any]) -> SystemKind? {
        guard
            line["type"] as? String == "user",
            let message = line["message"] as? [String: Any],
            message["role"] as? String == "user"
        else { return nil }

        if isCompactSummary(line) { return .compactSummary }

        let text: String
        if let s = message["content"] as? String {
            text = s
        } else if let array = message["content"] as? [[String: Any]] {
            // Pure tool_result blocks aren't user-typed messages and aren't system reminders either.
            if array.allSatisfy({ $0["type"] as? String == "tool_result" }) {
                return nil
            }
            text = (array.first(where: { $0["type"] as? String == "text" })?["text"] as? String) ?? ""
        } else {
            return nil
        }

        return classify(text: text)
    }

    /// Returns the typed system kind for a prompt *body*, or nil when it is a
    /// real user prompt. See `isRealUserMessage(text:)` for why the rule lives
    /// on the text: a queued prompt never gets a `type:"user"` line, so the
    /// only thing the two recording shapes share is the body itself.
    public static func classify(text: String) -> SystemKind? {
        // Background-task notifications are harness-injected into the user role.
        // Surface them as a dedicated system kind so they render as a clickable
        // activity row (with the full text available in the detail overlay).
        if text.hasPrefix("<task-notification") || text.hasPrefix("[SYSTEM NOTIFICATION") {
            return .taskNotification
        }

        if text.hasPrefix("Base directory for this skill:") { return .skillBody }
        if text.hasPrefix("<system-reminder") { return .toolReminder }
        if text.hasPrefix("<command-") { return .slashEnvelope }
        if text.hasPrefix("<environment_details") { return .environmentDetails }
        if text.hasPrefix("<local-command-") { return .hookOutput }

        // Heuristic injected-context detection (markdown headings stripped).
        let stripped = text.hasPrefix("#")
            ? String(text.drop(while: { $0 == "#" || $0 == " " }))
            : text
        let lower = stripped.lowercased()
        if injectedContextPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return .environmentDetails
        }

        // The known prefixes above match real Claude Code injections. The
        // generic-tag heuristic below is for future injections we haven't
        // seen yet — but it also catches user-typed XML/HTML prompts. If
        // isRealUserMessage already accepts this text as a real user
        // message, prefer that over the speculative system-injection
        // catch-all. New unknown injections degrade to plain user prompts
        // rather than being hidden as system noise.
        if isRealUserMessage(text: text) { return nil }

        // Unknown tag-like prefix → generic "other" injection. The tag must
        // start with `<`, contain only letters/underscores/hyphens, and end at
        // a `>` or whitespace.
        if text.hasPrefix("<"),
           let endOfTag = text.firstIndex(where: { $0 == ">" || $0 == " " }),
           text.distance(from: text.startIndex, to: endOfTag) > 1,
           text[text.index(after: text.startIndex)..<endOfTag].allSatisfy({ $0.isLetter || $0 == "_" || $0 == "-" }) {
            return .other
        }

        return nil
    }

    /// True when a user-role prompt body was not typed by a person but is still
    /// a real user row: an image-attachment meta line, an interrupt marker, or
    /// the continuation preamble Claude Code writes after running out of
    /// context. Blank text counts too. Used only by the transcript prompt rail;
    /// transcript rendering does not call it.
    ///
    /// Markers are recognised only in their structural position (every line is
    /// an image marker, or the text begins with the marker), so a typed prompt
    /// that merely mentions one stays a typed prompt.
    public static func isUntypedPromptMarker(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed.hasPrefix("[Request interrupted by user") { return true }
        if trimmed.hasPrefix("This session is being continued from a previous conversation") {
            return true
        }
        return trimmed
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .allSatisfy { line in
                line.hasPrefix("[Image: source: ")
                    && line.hasSuffix("]")
                    && line.count > "[Image: source: ]".count
            }
    }

    /// True for the line Claude Code writes when it compacts a conversation
    /// (`/compact` or auto-compact): a `type:"user"` line carrying the summary
    /// of everything before it, flagged `"isCompactSummary": true`. Other
    /// lines may carry the key as `null`, which reads as false.
    private static func isCompactSummary(_ line: [String: Any]) -> Bool {
        line["isCompactSummary"] as? Bool == true
    }

    private static func hasSystemPrefix(_ text: String) -> Bool {
        if systemPrefixes.contains(where: { text.hasPrefix($0) }) { return true }
        // Strip leading markdown heading markers before checking injected context prefixes
        let stripped = text.hasPrefix("#") ? text.drop(while: { $0 == "#" || $0 == " " }) : text[...]
        let lower = stripped.lowercased()
        return injectedContextPrefixes.contains(where: { lower.hasPrefix($0) })
    }
}
