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
/// deliberately narrow: the *command* must be a `gh pr create` or a
/// `glab mr create`, and URLs are taken from the *result*. A PR URL merely
/// mentioned in unrelated output must not bind, or every `git log` that quotes
/// a PR link would attach one.
public enum PRBindingExtractor {

    /// GitHub pull-request URLs. Host-locked to github.com; the binding's `host`
    /// column exists so enterprise support is a later additive change. The
    /// lookaheads reject `.` and `..` segments, which would otherwise parse as
    /// an owner or repo name.
    private static let githubURLPattern =
        #"https://github\.com/(?!\.{1,2}/)([\w.-]+)/(?!\.{1,2}/)([\w.-]+)/pull/(\d+)"#

    /// GitLab merge-request URLs on any host. `/-/merge_requests/` is the
    /// anchor: GitLab always inserts `/-/` between the project path and the
    /// resource, and no other forge uses that segment, so the URL identifies
    /// its own forge with no host list. Group 1 is the host, group 2 the
    /// namespace path — which may nest, GitLab allows up to 20 levels and the
    /// pattern does not cap it — group 3 the project, group 4 the number.
    /// Every segment gets the same dot-segment rejection the GitHub pattern
    /// applies to two, so no level of a nested namespace can smuggle a `..`.
    private static let gitlabURLPattern =
        #"https://([\w.-]+)/((?:(?!\.{1,2}/)[\w.-]+/)*?(?!\.{1,2}/)[\w.-]+)/(?!\.{1,2}/)([\w.-]+)/-/merge_requests/(\d+)"#

    /// Shell metacharacters that end one command and begin the next. Runs of
    /// them collapse on their own, so `&&`, `||` and `|` need no special case.
    private static let segmentSeparators: Set<Character> = [";", "&", "|", "\n"]

    /// `gh` global flags that consume the word after them, so the subcommand
    /// path of `gh --repo acme/acme-prod pr create` still reads `pr create`.
    private static let valueTakingFlags: Set<String> = ["-R", "--repo", "--hostname"]

    /// True when the command actually *runs* `gh pr create` or
    /// `glab mr create`, as opposed to merely containing that phrase.
    ///
    /// Substring matching was wrong in both directions. It fired on
    /// `git log --grep 'gh pr create'` — a false positive that can bind a
    /// merged PR quoted in unrelated output and hand `allResolved` an
    /// auto-archive the user never asked for — and it missed
    /// `gh -R acme/acme-prod pr create`, the normal way to target another repo.
    ///
    /// So the command is tokenized instead: heredoc bodies are dropped, because
    /// they are data the command writes rather than commands it runs; a quoted
    /// run stays one word, which is what keeps a quoted phrase from ever looking
    /// like a command; the string is cut into segments at shell separators; and a
    /// segment counts only when its first word is `gh` and its subcommand path —
    /// flags and their values skipped — is exactly `pr create`. This is a
    /// pragmatic tokenizer, not a shell parser: an unusual construction fails
    /// closed.
    public static func isPRCreateCommand(_ command: String) -> Bool {
        commandSegments(of: withoutHeredocBodies(command)).contains(where: isForgeCreateSegment)
    }

    /// Drop every heredoc *body* from a command, keeping the lines that really
    /// are commands.
    ///
    /// Segments are cut at newlines, so without this a documentation line inside
    /// a heredoc reads as a command:
    /// `cat <<'EOF' | tee -a CONTRIBUTING.md` whose body explains how to run
    /// `gh pr create …` would gate open, and any PR URL in that command's output
    /// would bind a PR the worktree never opened. That is the expensive
    /// direction — a false bind can auto-archive a worktree, while a missed real
    /// bind costs one `tbd pr attach`.
    ///
    /// So the rule fails **closed** wherever it is unsure. A heredoc that is
    /// never terminated swallows the rest of the command, and a `<<` that is not
    /// a heredoc at all (a shift inside `$(( … ))`) is read as one — both lose
    /// binds rather than inventing them. `<<<` is a here-string: one word of
    /// data on the same line, no body, nothing to skip.
    private static func withoutHeredocBodies(_ command: String) -> String {
        var lines: [String] = []
        var pending: [(delimiter: String, stripTabs: Bool)] = []
        for line in command.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(line)
            if let open = pending.first {
                // Body, including the terminator itself — never a command.
                let candidate = open.stripTabs ? String(line.drop { $0 == "\t" }) : line
                if candidate == open.delimiter { pending.removeFirst() }
                continue
            }
            lines.append(line)
            pending.append(contentsOf: heredocOpeners(in: line))
        }
        return lines.joined(separator: "\n")
    }

    /// The heredoc delimiters a command line opens, in the order their bodies
    /// will arrive (`cmd <<A <<B` reads A's body first). Quoting is tracked so a
    /// `<<` inside a string opens nothing, and the delimiter word is unquoted the
    /// way the shell unquotes it — `<<'EOF'`, `<<"EOF"` and `<<EOF` all end at a
    /// line reading `EOF`.
    private static func heredocOpeners(in line: String) -> [(delimiter: String, stripTabs: Bool)] {
        var openers: [(delimiter: String, stripTabs: Bool)] = []
        let chars = Array(line)
        var index = 0
        var quote: Character?

        while index < chars.count {
            let character = chars[index]
            if let open = quote {
                if character == "\\" && open == "\"" { index += 2; continue }
                if character == open { quote = nil }
                index += 1
                continue
            }
            if character == "\\" { index += 2; continue }
            if character == "'" || character == "\"" { quote = character; index += 1; continue }
            guard character == "<", index + 1 < chars.count, chars[index + 1] == "<" else {
                index += 1
                continue
            }
            index += 2
            if index < chars.count && chars[index] == "<" { index += 1; continue }  // here-string
            var stripTabs = false
            if index < chars.count && chars[index] == "-" { stripTabs = true; index += 1 }
            while index < chars.count && (chars[index] == " " || chars[index] == "\t") { index += 1 }
            var delimiter = ""
            var delimiterQuote: Character?
            while index < chars.count {
                let word = chars[index]
                if let open = delimiterQuote {
                    if word == open { delimiterQuote = nil } else { delimiter.append(word) }
                    index += 1
                    continue
                }
                if word == "'" || word == "\"" { delimiterQuote = word; index += 1; continue }
                if word == "\\" {
                    index += 1
                    if index < chars.count { delimiter.append(chars[index]); index += 1 }
                    continue
                }
                if word.isWhitespace || segmentSeparators.contains(word)
                    || word == "<" || word == ">" || word == ")" { break }
                delimiter.append(word)
                index += 1
            }
            if !delimiter.isEmpty { openers.append((delimiter, stripTabs)) }
        }
        return openers
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

    /// One segment invokes a merge-request create: `gh` (or a path ending in
    /// `/gh`) followed by `pr create`, or `glab` (or `/glab`) followed by
    /// `mr create`. The verb must match its own CLI — `gh mr create` and
    /// `glab pr create` are both rejected, and so is any other command word.
    private static func isForgeCreateSegment(_ words: [String]) -> Bool {
        guard let command = words.first else { return false }
        let expected: [String]
        if command == "gh" || command.hasSuffix("/gh") {
            expected = ["pr", "create"]
        } else if command == "glab" || command.hasSuffix("/glab") {
            expected = ["mr", "create"]
        } else {
            return false
        }
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
        return path == expected
    }

    /// Every distinct PR or MR URL in `text`, in first-seen order. The two
    /// patterns are scanned separately, so the results are re-sorted by where
    /// they were found rather than by which forge matched them.
    public static func parsePRURLs(in text: String) -> [ParsedPRURL] {
        let ns = text as NSString
        var seen = Set<String>()
        var out: [(location: Int, parsed: ParsedPRURL)] = []

        func collect(_ pattern: String, groups: Int,
                     build: (NSTextCheckingResult, NSString) -> ParsedPRURL?) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard match.numberOfRanges == groups, let parsed = build(match, ns) else { continue }
                guard seen.insert(parsed.url.lowercased()).inserted else { continue }
                out.append((match.range.location, parsed))
            }
        }

        collect(githubURLPattern, groups: 4) { match, ns in
            guard let number = Int(ns.substring(with: match.range(at: 3))) else { return nil }
            return ParsedPRURL(host: "github.com",
                               owner: ns.substring(with: match.range(at: 1)),
                               repo: ns.substring(with: match.range(at: 2)),
                               number: number,
                               url: ns.substring(with: match.range(at: 0)))
        }
        collect(gitlabURLPattern, groups: 5) { match, ns in
            guard let number = Int(ns.substring(with: match.range(at: 4))) else { return nil }
            return ParsedPRURL(host: ns.substring(with: match.range(at: 1)),
                               owner: ns.substring(with: match.range(at: 2)),
                               repo: ns.substring(with: match.range(at: 3)),
                               number: number,
                               url: ns.substring(with: match.range(at: 0)))
        }

        return out.sorted { $0.location < $1.location }.map(\.parsed)
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
