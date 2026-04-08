import Foundation

/// Determines whether a decoded JSONL line is a real user-authored message
/// vs. a tool result, system reminder, or other system-generated content.
///
/// This is the single place to update detection heuristics. The fixture at
/// Tests/Fixtures/sample-session.jsonl documents the classification decisions.
enum UserMessageClassifier {

    /// Prefixes that mark system-generated content in the user role.
    private static let systemPrefixes: [String] = [
        "<system-reminder",
        "<command-",
        "<tool_result",
        "<local-command-",
        "<environment_details",
    ]

    /// Case-insensitive substrings that mark injected context blocks (checked after trimming leading `# `).
    private static let injectedContextPrefixes: [String] = [
        "git repository context",
        "repository context",
        "current working directory:",
    ]

    /// Returns true if the parsed JSONL object is a real user message.
    static func isRealUserMessage(_ line: [String: Any]) -> Bool {
        guard
            line["type"] as? String == "user",
            let message = line["message"] as? [String: Any],
            message["role"] as? String == "user"
        else { return false }

        if let content = message["content"] as? String {
            return !hasSystemPrefix(content)
        }

        if let array = message["content"] as? [[String: Any]] {
            // All tool_result blocks → not a real message
            if array.allSatisfy({ $0["type"] as? String == "tool_result" }) {
                return false
            }
            // Check the first text block's content
            if let firstText = array.first(where: { $0["type"] as? String == "text" }),
               let text = firstText["text"] as? String {
                return !hasSystemPrefix(text)
            }
            return false
        }

        return false
    }

    /// Extracts display text from a real user message line. Returns nil if empty.
    /// Precondition: call only on lines that pass `isRealUserMessage` — behavior
    /// on other line types is undefined.
    static func extractText(_ line: [String: Any]) -> String? {
        guard let message = line["message"] as? [String: Any] else { return nil }

        if let text = message["content"] as? String {
            return text.isEmpty ? nil : text
        }

        if let array = message["content"] as? [[String: Any]] {
            return array
                .first(where: { $0["type"] as? String == "text" })
                .flatMap { $0["text"] as? String }
                .flatMap { $0.isEmpty ? nil : $0 }
        }

        return nil
    }

    private static func hasSystemPrefix(_ text: String) -> Bool {
        if systemPrefixes.contains(where: { text.hasPrefix($0) }) { return true }
        // Strip leading markdown heading markers before checking injected context prefixes
        let stripped = text.hasPrefix("#") ? text.drop(while: { $0 == "#" || $0 == " " }) : text[...]
        let lower = stripped.lowercased()
        return injectedContextPrefixes.contains(where: { lower.hasPrefix($0) })
    }
}
