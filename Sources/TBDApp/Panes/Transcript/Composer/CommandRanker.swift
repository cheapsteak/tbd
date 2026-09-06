import Foundation
import TBDShared

/// Orders the completion menu.
///
/// **Match quality first, frecency only as a tiebreak.** The order is: exact
/// name, exact alias, name prefix with the shortest first, alias prefix, fuzzy
/// score, then frecency. A command used heavily yesterday must never outrank the
/// one whose name the person just typed in full — that is the single property
/// that makes the menu feel obedient rather than opinionated.
///
/// Matching is case-insensitive against the name, its segments split on colon,
/// dash, underscore, dot and slash, its aliases, and its description at low
/// weight — so `brain` finds the brainstorming skill inside its plugin
/// namespace, and `sup:br` matches segment by segment.
///
/// Pure, and in the app target with its tests, following both existing palette
/// precedents (`JumpMenuViewModel`, `PaneHistoryPaletteFilter`).
enum CommandRanker {

    // MARK: - Tier

    /// Match quality, highest first. The tier is compared before any score, which
    /// is what makes "prefix beats fuzzy" a structural property rather than an
    /// artifact of the numbers.
    private enum Tier: Int, Comparable {
        case exactName = 0
        case exactAlias = 1
        case namePrefix = 2
        case aliasPrefix = 3
        case fuzzy = 4
        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Row: Equatable, Identifiable {
        let command: CompletionCommand
        /// UTF-16 offsets into `command.name` that matched, for highlighting.
        let matchedRanges: [NSRange]
        /// The alias that matched, shown in parentheses. nil when the name did.
        let matchedAlias: String?

        /// The command name IS the identity — derived, never passed, so a row can
        /// never disagree with the command it carries.
        var id: String { command.name }
    }

    // MARK: - Scoring constants
    //
    // Copied from the design and not tuned here. Changing one is a deliberate
    // edit with a reviewer, because the ORDERING tests pin relationships these
    // numbers produce, not the numbers themselves.

    private static let perCharacter = 16
    private static let adjacentPair = 4
    private static let gapPenaltyBase = 3
    private static let boundaryBonus = 8
    private static let camelBonus = 6
    /// Awarded when every colon-separated query segment prefixes a distinct
    /// candidate segment, in order.
    private static let segmentRunBonus = 200

    private static let separators = CharacterSet(charactersIn: ":_-./")

    static func segments(_ name: String) -> [String] {
        name.components(separatedBy: separators).filter { !$0.isEmpty }
    }

    /// A greedy leftmost subsequence match. nil when `query` is not a subsequence
    /// of `candidate` at all.
    static func fuzzyScore(query: String, candidate: String) -> Int? {
        let needle = Array(query.lowercased())
        let hay = Array(candidate)
        // Lowercased element-wise, not `Array(candidate.lowercased())` — a
        // lowercasing that changes grapheme count (e.g. İ) would desync the two
        // arrays and index `hayLower` out of step with `hay`.
        let hayLower = hay.map { Character(String($0).lowercased()) }
        guard !needle.isEmpty else { return 0 }

        var score = 0
        var hayIndex = 0
        var lastMatch = -2
        for character in needle {
            var found = false
            while hayIndex < hay.count {
                defer { hayIndex += 1 }
                guard hayLower[hayIndex] == character else { continue }
                score += perCharacter
                if hayIndex == lastMatch + 1 { score += adjacentPair }
                if hayIndex == 0 {
                    score += boundaryBonus
                } else {
                    let previous = hay[hayIndex - 1]
                    if String(previous).rangeOfCharacter(from: separators) != nil {
                        score += boundaryBonus
                    } else if previous.isLowercase && hay[hayIndex].isUppercase {
                        score += camelBonus
                    }
                }
                if lastMatch >= 0, hayIndex > lastMatch + 1 {
                    let gap = hayIndex - lastMatch - 1
                    score -= gapPenaltyBase + gap
                }
                lastMatch = hayIndex
                found = true
                break
            }
            guard found else { return nil }
        }
        // A shortness bonus, so `cat` prefers `cat` over `catalogue`.
        score += max(0, 32 - hay.count)
        return score
    }

    static func rank(
        commands: [CompletionCommand], query: String, frecency: (String) -> Double
    ) -> [Row] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return defaultRows(commands: commands, frecency: frecency) }
        let needle = trimmed.lowercased()

        struct Scored {
            let row: Row
            let tier: Tier
            let score: Int
            let nameLength: Int
            let frecency: Double
        }

        var scored: [Scored] = []
        for command in commands {
            let name = command.name
            let lowerName = name.lowercased()
            let matchedAlias = command.aliases.first { $0.lowercased() == needle }
                ?? command.aliases.first { $0.lowercased().hasPrefix(needle) }

            let tier: Tier
            let score: Int
            if lowerName == needle {
                tier = .exactName
                score = Int.max / 2
            } else if command.aliases.contains(where: { $0.lowercased() == needle }) {
                tier = .exactAlias
                score = Int.max / 4
            } else if lowerName.hasPrefix(needle) {
                tier = .namePrefix
                score = 0
            } else if command.aliases.contains(where: { $0.lowercased().hasPrefix(needle) }) {
                tier = .aliasPrefix
                score = 0
            } else {
                // Fuzzy, across every field at its own weight. Doubled integers
                // rather than Doubles so the ordering is exact: name 3, display
                // and segments and aliases 2, description ½ — expressed as 6, 4,
                // 4, 4, 1 over a common denominator of 2.
                var best = 0
                var matched = false
                if let nameScore = fuzzyScore(query: trimmed, candidate: name) {
                    best = max(best, nameScore * 6)
                    matched = true
                }
                for segment in segments(name) {
                    if let segmentScore = fuzzyScore(query: trimmed, candidate: segment) {
                        best = max(best, segmentScore * 4)
                        matched = true
                    }
                }
                for alias in command.aliases {
                    if let aliasScore = fuzzyScore(query: trimmed, candidate: alias) {
                        best = max(best, aliasScore * 4)
                        matched = true
                    }
                }
                if let descriptionScore = fuzzyScore(query: trimmed, candidate: command.description) {
                    best = max(best, descriptionScore * 1)
                    matched = true
                }
                // A colon in the query means the person is spelling out a
                // namespace. Every query segment must prefix a distinct candidate
                // segment, in order, and that earns a large bonus — it is a much
                // stronger statement of intent than a subsequence.
                if trimmed.contains(":") {
                    let querySegments = segments(trimmed)
                    let candidateSegments = segments(name).map { $0.lowercased() }
                    var cursor = 0
                    var allMatched = !querySegments.isEmpty
                    for piece in querySegments.map({ $0.lowercased() }) {
                        guard cursor <= candidateSegments.count,
                              let hit = candidateSegments[cursor...].firstIndex(where: {
                                  $0.hasPrefix(piece)
                              })
                        else {
                            allMatched = false
                            break
                        }
                        cursor = hit + 1
                    }
                    if allMatched {
                        best += segmentRunBonus
                        matched = true
                    }
                }
                guard matched else { continue }
                tier = .fuzzy
                score = best
            }
            scored.append(Scored(
                row: Row(
                    command: command,
                    matchedRanges: highlightRanges(query: trimmed, in: name),
                    matchedAlias: lowerName.hasPrefix(needle) ? nil : matchedAlias),
                tier: tier,
                score: score,
                nameLength: name.count,
                frecency: frecency(name)))
        }

        return scored.sorted { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            // Within the prefix tiers the shortest name wins; elsewhere the
            // higher score does.
            if lhs.tier == .namePrefix || lhs.tier == .aliasPrefix {
                if lhs.nameLength != rhs.nameLength { return lhs.nameLength < rhs.nameLength }
            } else if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            if lhs.frecency != rhs.frecency { return lhs.frecency > rhs.frecency }
            return lhs.row.id < rhs.row.id
        }.map(\.row)
    }

    /// A bare sigil: the top five by frecency, then everything else
    /// alphabetically. Every command stays reachable by scrolling — the five is
    /// a lead, not a cap.
    static func defaultRows(
        commands: [CompletionCommand], frecency: (String) -> Double
    ) -> [Row] {
        let byFrecency = commands
            .filter { frecency($0.name) > 0 }
            .sorted { frecency($0.name) > frecency($1.name) }
            .prefix(5)
        let leadNames = Set(byFrecency.map(\.name))
        let rest = commands
            .filter { !leadNames.contains($0.name) }
            .sorted { $0.name < $1.name }
        return (Array(byFrecency) + rest).map {
            Row(command: $0, matchedRanges: [], matchedAlias: nil)
        }
    }

    /// UTF-16 ranges of the greedy leftmost subsequence, for highlighting. Empty
    /// when the query does not appear as a subsequence of `name` — highlights
    /// apply only when the query is a subsequence of the name, whether or not
    /// the row's match actually came from an alias.
    private static func highlightRanges(query: String, in name: String) -> [NSRange] {
        let nsName = name as NSString
        let needle = Array(query.lowercased())
        var ranges: [NSRange] = []
        var needleIndex = 0
        var offset = 0
        while offset < nsName.length, needleIndex < needle.count {
            let range = nsName.rangeOfComposedCharacterSequence(at: offset)
            if nsName.substring(with: range).lowercased() == String(needle[needleIndex]) {
                ranges.append(range)
                needleIndex += 1
            }
            offset = range.location + range.length
        }
        return needleIndex == needle.count ? ranges : []
    }
}
