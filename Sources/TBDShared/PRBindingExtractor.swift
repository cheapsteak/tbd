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

    /// Host-locked to github.com for now; the binding's `host` column exists so
    /// enterprise support is a later additive change. The lookaheads reject `.`
    /// and `..` segments, which would otherwise parse as an owner or repo name.
    private static let urlPattern =
        #"https://github\.com/(?!\.{1,2}/)([\w.-]+)/(?!\.{1,2}/)([\w.-]+)/pull/(\d+)"#

    /// Shell metacharacters that end one command and begin the next. Runs of
    /// them collapse on their own, so `&&`, `||` and `|` need no special case.
    private static let segmentSeparators: Set<Character> = [";", "&", "|", "\n"]

    /// `gh` global flags that consume the word after them, so the subcommand
    /// path of `gh --repo acme/acme-prod pr create` still reads `pr create`.
    private static let valueTakingFlags: Set<String> = ["-R", "--repo", "--hostname"]

    /// True when the command actually *runs* `gh pr create`, as opposed to
    /// merely containing that phrase.
    ///
    /// Substring matching was wrong in both directions. It fired on
    /// `git log --grep 'gh pr create'` — a false positive that can bind a
    /// merged PR quoted in unrelated output and hand `allResolved` an
    /// auto-archive the user never asked for — and it missed
    /// `gh -R acme/acme-prod pr create`, the normal way to target another repo.
    ///
    /// So the command is tokenized instead: a quoted run stays one word, which
    /// is what keeps a quoted phrase from ever looking like a command; the
    /// string is cut into segments at shell separators; and a segment counts
    /// only when its first word is `gh` and its subcommand path — flags and
    /// their values skipped — is exactly `pr create`. This is a pragmatic
    /// tokenizer, not a shell parser: an unusual construction fails closed.
    public static func isPRCreateCommand(_ command: String) -> Bool {
        commandSegments(of: command).contains(where: isGHPRCreateSegment)
    }

    /// Split into per-command word lists, honoring quotes so that neither a
    /// separator nor a space inside a quoted string breaks anything apart.
    private static func commandSegments(of command: String) -> [[String]] {
        var segments: [[String]] = []
        var words: [String] = []
        var word = ""
        var wordStarted = false
        var quote: Character?
        var escaped = false

        func endWord() {
            guard wordStarted else { return }
            words.append(word)
            word = ""
            wordStarted = false
        }
        func endSegment() {
            endWord()
            guard !words.isEmpty else { return }
            segments.append(words)
            words = []
        }

        for character in command {
            if escaped {
                word.append(character)
                wordStarted = true
                escaped = false
            } else if let open = quote {
                if character == open {
                    quote = nil                       // the word stays open
                } else if open == "\"" && character == "\\" {
                    escaped = true
                } else {
                    word.append(character)
                    wordStarted = true
                }
            } else if character == "\\" {
                escaped = true
            } else if character == "'" || character == "\"" {
                quote = character
                wordStarted = true                    // `""` is an empty word
            } else if segmentSeparators.contains(character) {
                endSegment()
            } else if character.isWhitespace {
                endWord()
            } else {
                word.append(character)
                wordStarted = true
            }
        }
        endSegment()
        return segments
    }

    /// One segment invokes `gh pr create`: `gh` (or a path ending in `/gh`) is
    /// the command word, and the first two non-flag words after it are `pr`
    /// then `create`.
    private static func isGHPRCreateSegment(_ words: [String]) -> Bool {
        guard let command = words.first,
              command == "gh" || command.hasSuffix("/gh") else { return false }
        var path: [String] = []
        var index = 1
        while index < words.count && path.count < 2 {
            let word = words[index]
            if word.count > 1 && word.hasPrefix("-") {
                index += valueTakingFlags.contains(word) ? 2 : 1
            } else {
                path.append(word)
                index += 1
            }
        }
        return path == ["pr", "create"]
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
