import Foundation
import TBDShared

/// Reads the harness-written `origin` dictionary off a single decoded
/// transcript row and, when that row is a message from another Claude session,
/// returns the sender's attribution plus the message body with its delivery
/// envelope removed.
///
/// **Pure function of one row.** `TranscriptParser.buildItems` carries a rule
/// that every item must be derivable from its own row, because a tail parse
/// sees only the lines inside its byte window and any cross-row state starts
/// empty there. This reads the row's `origin` dictionary and its content
/// string, and nothing else: no registry lookup, no worktree matching, no
/// filesystem access. `ClaudeSessionScanner` calls the same entry point, so the
/// transcript bubble and the session-picker rows cannot drift apart in how they
/// read an envelope.
///
/// **`origin` is written by the receiving harness, not by the sending model.**
/// The `body` it records is agent-authored, so envelope handling below is
/// prefix/suffix work on known markers rather than a search through the body: a
/// peer can write `</cross-session-message>` — or quote the security preamble —
/// inside its own message, and must not be able to make that text disappear or
/// take the rest of the message with it.
enum PeerOriginExtractor {
    struct Extracted: Equatable {
        let sender: PeerSender
        let text: String
        /// The untouched original content, retained for the detail overlay, or
        /// nil when it would merely repeat `text`.
        let deliveredPayload: String?
    }

    /// The line the harness prepends to every delivered peer message.
    private static let framingLine = "Another Claude session sent a message:"
    /// The envelope's open tag, which the harness writes on its own line with
    /// `from`, `from-name` and `from-mode` attributes.
    private static let openTagName = "<cross-session-message"
    private static let closeTag = "</cross-session-message>"
    /// The anti-escalation preamble the harness appends to every peer message.
    /// Stable text; matched as a prefix from the END of the content so the rest
    /// of its ~90 words can be reworded without breaking extraction.
    private static let preamblePrefix = "This came from another Claude session —"

    static func extract(from json: [String: Any]) -> Extracted? {
        guard let origin = json["origin"] as? [String: Any],
              origin["kind"] as? String == "peer" else { return nil }

        // `from` is sender-asserted and unverified — anything running as the
        // same OS user can set it, and a uds path there is not evidence of
        // anything. What the harness verifies is the peer socket and pid, which
        // is why only the verified shape carries BOTH `name` and
        // `verifiedPeerPid`. Requiring both is the whole verification rule.
        let from = origin["from"] as? String ?? ""
        let name = (origin["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let pid = origin["verifiedPeerPid"] as? Int
        let sender = PeerSender(name: name, from: from,
                                verified: name != nil && pid != nil, pid: pid)

        let rawContent = contentString(json)
        let body = (origin["body"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let text = body ?? stripEnvelope(rawContent ?? "")

        return Extracted(sender: sender, text: text,
                         deliveredPayload: rawContent == text ? nil : rawContent)
    }

    /// `message.content` appears both as a bare string and as an array of
    /// content blocks; both shapes are measured in the local corpus.
    private static func contentString(_ json: [String: Any]) -> String? {
        guard let message = json["message"] as? [String: Any] else { return nil }
        if let s = message["content"] as? String { return s }
        if let blocks = message["content"] as? [[String: Any]] {
            let texts = blocks
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        }
        return nil
    }

    /// Removes the delivery envelope from a raw peer content string: the
    /// leading framing line, the trailing security preamble, and the
    /// `<cross-session-message …>` open tag with its matching close tag.
    ///
    /// Every step is anchored at one end of the string. Nothing searches the
    /// interior, so agent-authored text that happens to name a marker survives
    /// intact, and an envelope the harness stops writing simply leaves the
    /// content alone rather than being guessed at.
    private static func stripEnvelope(_ content: String) -> String {
        var body = Substring(content)

        if body.hasPrefix(framingLine) {
            body = body.dropFirst(framingLine.count)
        }

        // Anchored at the end: the preamble is always last, so the LAST
        // occurrence of its prefix is the real one even if the body quotes it.
        if let preamble = body.range(of: preamblePrefix, options: .backwards) {
            body = body[body.startIndex..<preamble.lowerBound]
        }

        var trimmed = trim(body)

        // The open tag occupies the first line. Strip the close tag only if the
        // open tag was there to pair with — an unpaired trailing close tag is
        // the body's own text.
        if let afterOpenTag = dropOpenTag(trimmed) {
            trimmed = trim(afterOpenTag)
            if trimmed.hasSuffix(closeTag) {
                trimmed = trim(trimmed.dropLast(closeTag.count))
            }
        }

        return trimmed
    }

    /// Returns the content with its leading `<cross-session-message …>` line
    /// removed, or nil when the first line is not that tag.
    private static func dropOpenTag(_ content: String) -> String? {
        guard content.hasPrefix(openTagName) else { return nil }
        // Reject `<cross-session-messageXYZ>`: the tag name must end where a
        // tag name can end.
        let afterName = content.index(content.startIndex, offsetBy: openTagName.count)
        guard let boundary = content[afterName...].first,
              boundary == " " || boundary == ">" else { return nil }

        let lineEnd = content.firstIndex(of: "\n") ?? content.endIndex
        guard content[content.startIndex..<lineEnd].hasSuffix(">") else { return nil }
        return String(content[lineEnd...])
    }

    private static func trim(_ s: some StringProtocol) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
