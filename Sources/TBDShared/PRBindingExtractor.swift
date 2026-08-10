import Foundation

/// A pull-request URL recovered from agent tool output.
public struct ParsedPRURL: Sendable, Equatable, Hashable {
    public let host: String
    public let owner: String
    public let repo: String
    public let number: Int
    public let url: String

    public init(host: String, owner: String, repo: String, number: Int, url: String) {
        self.host = host
        self.owner = owner
        self.repo = repo
        self.number = number
        self.url = url
    }
}

/// Pure extraction of PR bindings from a Claude Code `PostToolUse` hook payload.
///
/// This reads the hook's structured `tool_input` / `tool_response` JSON — a
/// machine interface — and never inspects rendered terminal output. The rule is
/// deliberately narrow: the *command* must be a `gh pr create`, and URLs are
/// taken from the *result*. A PR URL merely mentioned in unrelated output must
/// not bind, or every `git log` that quotes a PR link would attach one.
public enum PRBindingExtractor {

    /// `gh` … `pr` … `create` as consecutive shell words, allowing any spacing
    /// and any surrounding pipeline. Word boundaries keep `gh-pr-create` out.
    private static let createPattern = #"\bgh\s+pr\s+create\b"#

    /// Host-locked to github.com for now; the binding's `host` column exists so
    /// enterprise support is a later additive change. The lookaheads reject `.`
    /// and `..` segments, which would otherwise parse as an owner or repo name.
    private static let urlPattern =
        #"https://github\.com/(?!\.{1,2}/)([\w.-]+)/(?!\.{1,2}/)([\w.-]+)/pull/(\d+)"#

    public static func isPRCreateCommand(_ command: String) -> Bool {
        command.range(of: createPattern, options: .regularExpression) != nil
    }

    /// Every distinct PR URL in `text`, in first-seen order.
    public static func parsePRURLs(in text: String) -> [ParsedPRURL] {
        guard let regex = try? NSRegularExpression(pattern: urlPattern) else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        var out: [ParsedPRURL] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges == 4,
                  let number = Int(ns.substring(with: match.range(at: 3))) else { continue }
            let owner = ns.substring(with: match.range(at: 1))
            let repo = ns.substring(with: match.range(at: 2))
            let url = ns.substring(with: match.range(at: 0))
            let parsed = ParsedPRURL(host: "github.com", owner: owner, repo: repo,
                                     number: number, url: url)
            guard seen.insert(parsed.url.lowercased()).inserted else { continue }
            out.append(parsed)
        }
        return out
    }

    /// Extract bindings from a raw hook payload. Returns empty for anything
    /// unexpected — a hook must never fail the tool call it observes.
    public static func extract(fromHookPayload data: Data) -> [ParsedPRURL] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let input = root["tool_input"] as? [String: Any],
              let command = input["command"] as? String,
              isPRCreateCommand(command) else { return [] }
        return parsePRURLs(in: responseText(root["tool_response"]))
    }

    /// `tool_response` is an object for most tools and a bare string for some;
    /// accept either and scan everything textual inside it.
    private static func responseText(_ value: Any?) -> String {
        switch value {
        case let string as String:
            return string
        case let dict as [String: Any]:
            return dict.values.map { responseText($0) }.joined(separator: "\n")
        case let array as [Any]:
            return array.map { responseText($0) }.joined(separator: "\n")
        default:
            return ""
        }
    }
}
