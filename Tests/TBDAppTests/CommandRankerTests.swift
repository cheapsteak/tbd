import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Ranking, stated as the orderings a person would notice.
///
/// The absolute scores are not the contract — the ORDER is. Asserting exact
/// numbers would pin an incident; asserting that a prefix beats a fuzzy match
/// pins the property.
@Suite("CommandRanker")
struct CommandRankerTests {

    private func command(
        _ name: String, description: String = "", aliases: [String] = []
    ) -> CompletionCommand {
        CompletionCommand(name: name, description: description, aliases: aliases)
    }

    /// `checkout` earns its place: `co` fuzzy-matches it and does NOT prefix it,
    /// which is what makes `prefixBeatsFuzzy`'s "find a non-prefix row"
    /// satisfiable rather than vacuous.
    private let inventory = [
        CompletionCommand(name: "compact", description: "Compact the conversation"),
        CompletionCommand(name: "code-review", description: "Review the diff",
                          aliases: ["review"]),
        CompletionCommand(name: "config", description: "Open settings"),
        CompletionCommand(name: "superpowers:brainstorming",
                          description: "Explore intent before implementing"),
        CompletionCommand(name: "clear", description: "Clear the conversation"),
        CompletionCommand(name: "checkout", description: "Switch branches"),
    ]

    private func names(_ query: String, frecency: @escaping (String) -> Double = { _ in 0 })
        -> [String] {
        CommandRanker.rank(commands: inventory, query: query, frecency: frecency)
            .map(\.id)
    }

    // MARK: - Segments

    @Test func namesSplitOnEverySeparator() {
        #expect(CommandRanker.segments("superpowers:brainstorming")
            == ["superpowers", "brainstorming"])
        #expect(CommandRanker.segments("code-review") == ["code", "review"])
        #expect(CommandRanker.segments("a_b.c/d") == ["a", "b", "c", "d"])
    }

    // MARK: - Order

    @Test func anExactNameWins() {
        #expect(names("compact").first == "compact")
    }

    @Test func anExactAliasBeatsAPrefix() throws {
        let ranked = names("review")
        #expect(ranked.first == "code-review",
                "the exact alias must win over anything that merely contains it")
    }

    /// **Prefix beats fuzzy.** `co` prefixes three commands; a command it only
    /// fuzzy-matches must sort below all of them.
    @Test func prefixBeatsFuzzy() throws {
        let ranked = names("co")
        let prefixes = Set(["compact", "code-review", "config"])
        let firstNonPrefix = try #require(ranked.firstIndex { !prefixes.contains($0) })
        #expect(firstNonPrefix >= 3, "every prefix match must sort above every fuzzy one: \(ranked)")
    }

    /// Among prefix matches, the shortest name first — it is the one the person
    /// most likely meant with the fewest characters typed.
    @Test func amongPrefixesTheShortestFirst() {
        let ranked = names("c")
        let clear = try? #require(ranked.firstIndex(of: "clear"))
        let codeReview = try? #require(ranked.firstIndex(of: "code-review"))
        #expect((clear ?? 0) < (codeReview ?? 0))
    }

    /// `brain` finds the brainstorming skill inside its plugin namespace — the
    /// case the segment matching exists for.
    @Test func aSegmentMatchFindsANamespacedSkill() {
        #expect(names("brain").contains("superpowers:brainstorming"))
    }

    /// `sup:br` matches segment by segment, in order.
    @Test func aColonQueryMatchesSegmentBySegment() {
        let ranked = names("sup:br")
        #expect(ranked.first == "superpowers:brainstorming", "got \(ranked)")
    }

    /// **Frecency breaks ties ONLY.** A heavily-used command must not outrank an
    /// exact name match. Run with a frecency that strongly favours the wrong row.
    @Test func frecencyNeverOutranksAMatchQuality() {
        let ranked = names("compact", frecency: { $0 == "clear" ? 1000 : 0 })
        #expect(ranked.first == "compact",
                "frecency must be a tiebreak, not a rank: \(ranked)")
    }

    /// Two names of EQUAL length, so the "shortest name first" rule inside the
    /// prefix tier cannot settle the tie before frecency gets to.
    @Test func frecencyDoesBreakARealTie() {
        let pair = [command("alpha"), command("alphb")]
        let favouringB = CommandRanker.rank(
            commands: pair, query: "alp", frecency: { $0 == "alphb" ? 100 : 0 })
        #expect(favouringB.first?.id == "alphb")
        let favouringA = CommandRanker.rank(
            commands: pair, query: "alp", frecency: { $0 == "alpha" ? 100 : 0 })
        #expect(favouringA.first?.id == "alpha")
    }

    // MARK: - Tier boundaries, each stated so removing the tier reddens it
    //
    // The orderings above are the ones a person notices; these are the ones that
    // keep the LADDER honest. Each pairs two commands that the tier rule alone
    // separates, and each hands the loser a large frecency so a pass cannot be an
    // accident of the tiebreak.

    /// Not tier-discriminating: the source's own sentinel scores (`Int.max/2`
    /// for an exact name, `Int.max/4` for an exact alias) already sort in the
    /// same order as the tiers do, so a sort that dropped the tier comparison
    /// and fell back to score alone would still pass this. No pair of commands
    /// can equalize those two constants from the outside. What this pins is the
    /// observable order — `deploy` before `ship` — and that a heavy frecency on
    /// the loser cannot override it.
    @Test func anExactNameBeatsAnExactAlias() {
        let ranked = CommandRanker.rank(
            commands: [command("deploy"), command("ship", aliases: ["deploy"])],
            query: "deploy", frecency: { $0 == "ship" ? 100 : 0 })
        #expect(ranked.map(\.id) == ["deploy", "ship"])
    }

    @Test func anExactAliasBeatsANamePrefixOutright() {
        let ranked = CommandRanker.rank(
            commands: [command("review-all"), command("code-review", aliases: ["review"])],
            query: "review", frecency: { $0 == "review-all" ? 100 : 0 })
        #expect(ranked.map(\.id) == ["code-review", "review-all"])
    }

    /// The name is what the person is typing; an alias is a courtesy. `zebra` is
    /// the SHORTER name, so without the tier the prefix rule would hand it first
    /// place.
    @Test func aNamePrefixBeatsAnAliasPrefix() {
        let ranked = CommandRanker.rank(
            commands: [command("confetti"), command("zebra", aliases: ["configure"])],
            query: "conf", frecency: { $0 == "zebra" ? 100 : 0 })
        #expect(ranked.map(\.id) == ["confetti", "zebra"])
    }

    // MARK: - No match

    @Test func aQueryThatMatchesNothingRanksNothing() {
        #expect(names("zzzzqqq").isEmpty)
    }

    // MARK: - The bare sigil

    @Test func anEmptyQueryLeadsWithTheTopFiveByFrecency() {
        let rows = CommandRanker.defaultRows(
            commands: inventory, frecency: { $0 == "clear" ? 100 : 0 })
        #expect(rows.first?.id == "clear")
        #expect(rows.count == inventory.count, "every command is still reachable by scrolling")
    }

    // MARK: - Highlighting

    @Test func matchedRangesPointAtTheMatchedCharacters() throws {
        let row = try #require(CommandRanker.rank(
            commands: [command("compact")], query: "cmp", frecency: { _ in 0 }).first)
        #expect(!row.matchedRanges.isEmpty)
        let name = "compact" as NSString
        let matched = row.matchedRanges.map { name.substring(with: $0) }.joined()
        #expect(matched == "cmp")
    }

    @Test func aMatchedAliasIsNamed() throws {
        let row = try #require(CommandRanker.rank(
            commands: [command("code-review", aliases: ["review"])],
            query: "review", frecency: { _ in 0 }).first)
        #expect(row.matchedAlias == "review")
    }
}
