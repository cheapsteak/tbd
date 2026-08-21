import AppKit
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

/// REGRESSION GUARD on `TableTranscriptView.Coordinator.estimate(for:width:)`.
///
/// `heightOfRow` serves that cheap arithmetic estimate for every row whose exact
/// height is not yet cached, and NSTableView reserves exactly that much space
/// until the row realizes and is corrected to the measured height. A biased
/// estimate is therefore a scroll-position bug in waiting: every correction moves
/// the rows below it, and a systematic bias moves them all the same way. The
/// estimator once over-reserved by 15% on ordinary prose, 31% on a fenced code
/// block and 81% on a GFM table (whose source lines it counted twice), which the
/// reader saw as content sliding upward under the cursor.
///
/// So this file pins two things, and both are contracts rather than incidents:
///
/// 1. the SIGNED error `estimate - exact` for every row kind the pane can show,
///    at both of the column geometries it is laid out at (680 on a host with
///    overlay scrollers, 663 with legacy ones), each against a stated budget;
/// 2. the DIRECTION of whatever error remains — never above the measurement, so
///    the on-realize correction GROWS the row. A row that grows pushes
///    not-yet-read content further down, off screen; a row that shrinks pulls
///    content up into the reading area, which the reader sees as a jump.
///
/// Tier 1: deterministic, in-process, no sleeps, no `~/tbd`.
///
///     scripts/test.sh --filter TranscriptEstimatorAccuracyTests
///
/// ## Why no run loop
/// Everything here is synchronous. The exact heights come from
/// `precomputeBottomWindow()`, which calls the SAME private `measuredHeight` that
/// `viewFor` calls when a row realizes, and caches it under the same
/// `(id, contentVersion, width)` key — so `cachedExactHeight(for:)` after a
/// precompute IS the realized height. `realizeAllRows` is run afterwards purely
/// to prove that: it must not change a single cached height. That avoids
/// `RunLoop.current.run(until:)`, which inside a `@MainActor` test resumes every
/// other suspended `@MainActor` test in the process inside this test's body.
///
/// ## Why the width is pinned by hand
/// The scroll view's settled column width depends on the host's scroller style
/// and on whether the document has outgrown the viewport yet. This file needs two
/// EXACT widths, so it lays the scroll view out once at the target and then pins
/// the table's own frame and column to it, asserting the coordinator's effective
/// width before any number is recorded. The `scrollerStyle = .legacy` pin from the
/// sibling harness is kept.
@Suite("Transcript row-height estimator accuracy")
@MainActor
struct TranscriptEstimatorAccuracyTests {
    private static let viewportHeight: CGFloat = 600
    /// The two column geometries the pane is measured at.
    private static let widths: [CGFloat] = [680, 663]

    // MARK: - Per-kind signed error

    /// The point budget each row kind's estimate must stay inside, and the
    /// percentage of the measured height that budget represents at the smaller of
    /// the two geometries. Every budget is set just above what the estimator
    /// actually achieves, so slack is not quietly available for a regression to
    /// hide in.
    private struct Budget {
        let id: String
        /// Largest permitted |estimate - exact|, in points.
        let points: CGFloat
        /// The same budget as a share of the row's measured height, for the
        /// failure message — a 2 pt budget means something different on a 22 pt
        /// activity row than on a 528 pt bubble.
        let percent: CGFloat
        /// What the estimator scores today, quoted so a future reader can see how
        /// much of the budget is headroom rather than achievement.
        let achieved: String
    }

    /// Prose, structured-markdown and image bubbles all land EXACTLY on the
    /// measurement: the estimator models the same block structure the renderer
    /// builds (one paragraph unit per non-blank source line, its trailing
    /// paragraph or list spacing, fenced-code lines without their delimiters, GFM
    /// grid rows counted once) out of font-derived line metrics.
    ///
    /// The 2 pt budget is rounding slack and NOTHING more. In particular it does
    /// not make these fixtures font-size-independent: several of them
    /// (`user/wrap-boundary` by construction, `assistant/long` and the
    /// code-block fixture by length) sit near a wrap boundary at the DEFAULT
    /// system text size, and at a larger one they land on the other side of it and
    /// miss by a whole rendered line. That is a property of the fixture text, not
    /// of the estimator — which derives every constant from the theme font and
    /// tracks the change — so `perKindErrorStaysWithinBudget` states the
    /// precondition and stands down rather than reporting someone else's bug.
    /// `wrapArithmeticStaysCalibrated` carries the guarantee on such a host: it
    /// compares against measurement at whatever size the host runs.
    ///
    /// Activity rows are exact BY CONSTRUCTION — the row is one truncated line of
    /// fixed chrome — so they get no budget at all.
    ///
    /// AskUserQuestion is the one genuinely estimated kind: a hosted SwiftUI card
    /// whose height depends on how its question and option text wraps, which no
    /// arithmetic over the raw JSON can see. It gets a calibrated constant and a
    /// budget covering the measured spread of card shapes.
    private static let budgets: [Budget] = [
        Budget(id: "assistant/short", points: 2, percent: 4.2, achieved: "0.0"),
        Budget(id: "assistant/two-para", points: 2, percent: 1.6, achieved: "0.0"),
        Budget(id: "assistant/long", points: 2, percent: 0.4, achieved: "0.0"),
        Budget(id: "assistant/code-block", points: 2, percent: 1.1, achieved: "0.0"),
        Budget(id: "assistant/indented-code", points: 2, percent: 0.6, achieved: "0.0"),
        Budget(id: "assistant/setext-headings", points: 2, percent: 1.5, achieved: "0.0"),
        Budget(id: "assistant/pipeless-table", points: 2, percent: 1.4, achieved: "0.0"),
        Budget(id: "assistant/bullet-list", points: 2, percent: 1.3, achieved: "0.0"),
        Budget(id: "assistant/list-continuation", points: 2, percent: 1.1, achieved: "0.0"),
        Budget(id: "assistant/gfm-table", points: 2, percent: 1.2, achieved: "0.0"),
        Budget(id: "assistant/image", points: 2, percent: 1.0, achieved: "0.0"),
        Budget(id: "assistant/soft-breaks", points: 2, percent: 0.9, achieved: "0.0"),
        Budget(id: "assistant/crlf", points: 2, percent: 0.8, achieved: "0.0"),
        Budget(id: "assistant/badge-control", points: 2, percent: 3.1, achieved: "0.0"),
        Budget(id: "assistant/badge", points: 2, percent: 2.2, achieved: "0.0"),
        Budget(id: "assistant/badge-after-bullets", points: 2, percent: 1.7, achieved: "0.0"),
        Budget(id: "assistant/badge-after-fence", points: 2, percent: 1.9, achieved: "0.0"),
        Budget(id: "user/short", points: 2, percent: 4.2, achieved: "0.0"),
        Budget(id: "user/long", points: 2, percent: 2.1, achieved: "0.0"),
        Budget(id: "user/wrap-boundary", points: 2, percent: 1.4, achieved: "0.0"),
        Budget(id: "activity/systemReminder", points: 0.5, percent: 2.3, achieved: "0.0"),
        Budget(id: "activity/bash", points: 0.5, percent: 2.3, achieved: "0.0"),
        Budget(id: "activity/task", points: 0.5, percent: 2.3, achieved: "0.0"),
        Budget(id: "grp-0#activity-group", points: 0.5, percent: 2.3, achieved: "0.0"),
        Budget(id: "activity/subagentSummary", points: 0.5, percent: 3.8, achieved: "0.0"),
        Budget(id: "card/askUserQuestion", points: 10, percent: 4.7, achieved: "-8.0"),
        Budget(id: "card/askUserQuestion-min", points: 10, percent: 5.8, achieved: "-8.0"),
        Budget(id: "card/askUserQuestion-max", points: 10, percent: 1.8, achieved: "-8.0"),
        Budget(id: "card/askUserQuestion-wrapping", points: 40, percent: 16.6, achieved: "-36.0"),
        Budget(id: "card/askUserQuestion-malformed", points: 20, percent: 30.3, achieved: "-16.0"),
        Budget(id: "assistant/links", points: 2, percent: 1.6, achieved: "0.0"),
        Budget(id: "assistant/raw-html", points: 2, percent: 1.8, achieved: "0.0"),
        Budget(id: "assistant/html-interrupting", points: 2, percent: 1.5, achieved: "0.0"),
        Budget(id: "assistant/angle-bracket-prose", points: 2, percent: 1.6, achieved: "0.0"),
        Budget(id: "assistant/indented-after-heading", points: 2, percent: 1.4, achieved: "0.0"),
        Budget(id: "card/askUserQuestion-bare-options", points: 10, percent: 5.5, achieved: "-8.0"),
        Budget(id: "card/askUserQuestion-optional-typed", points: 20, percent: 24.2, achieved: "-16.0")
    ]

    /// The AskUserQuestion fixtures are only worth anything if the card can
    /// actually DECODE them. A payload that does not decode renders a fallback
    /// block, and a fixture measuring the fallback pins nothing about the card —
    /// which is exactly how the constant these budgets replaced came to be
    /// calibrated against the wrong thing, by 439 pt at worst.
    @Test("the AskUserQuestion fixtures decode as cards, not as the fallback block")
    func askCardFixturesAreValidJSON() throws {
        // The card's OWN question type, not a mirror of it. A mirror carrying only
        // the required fields decodes payloads the card rejects — `decodeIfPresent`
        // throws on a present-but-wrong-typed optional and returns nil only for an
        // absent or null one — so a `decodes:` flag checked against a mirror cannot
        // see that class of drift at all. `card/askUserQuestion-optional-typed` is
        // exactly that payload, and it caught this copy when it was added.
        struct Input: Decodable { let questions: [AskUserQuestionCard.Question] }

        for fixture in Self.askCardFixtures {
            #expect(!fixture.json.contains("\n") && !fixture.json.contains("\\"),
                    Comment(rawValue: "\(fixture.id): the payload must be ONE line with no literal "
                        + "backslash — a `#\"\"\"` raw string does not honour a trailing `\\` as a "
                        + "line continuation, and the embedded characters make it undecodable"))
            let decoded = try? JSONDecoder().decode(Input.self, from: Data(fixture.json.utf8))
            // `decodes: false` is ONE fixture and it is named: the malformed
            // payload deliberately pins the fallback path. Every other fixture
            // must decode, or it silently measures that fallback instead of a card.
            #expect((decoded != nil) == fixture.decodes,
                    Comment(rawValue: "\(fixture.id): expected decodes == \(fixture.decodes) but "
                        + "the payload \(decoded == nil ? "did not decode" : "decoded"). A fixture "
                        + "that stops decoding measures the card's raw-JSON fallback block rather "
                        + "than a card."))
        }
    }

    /// The system body size these fixtures are calibrated against. Everything the
    /// ESTIMATOR uses is derived from the theme font, so it follows a host that
    /// differs; the fixture TEXT cannot, since where a given sentence breaks is a
    /// property of the size it was written at.
    nonisolated private static let calibratedBodyPointSize: CGFloat = 13

    /// Whether this host runs at the text size the fixtures were calibrated for.
    nonisolated private static var hostIsAtCalibratedTextSize: Bool {
        NSFont.preferredFont(forTextStyle: .body).pointSize == calibratedBodyPointSize
    }

    nonisolated private static var textSizePreconditionMessage: String {
        "these fixtures are calibrated for a \(f(calibratedBodyPointSize)) pt system body font and "
            + "this host renders at \(f(NSFont.preferredFont(forTextStyle: .body).pointSize)) pt, "
            + "where the fixture sentences fall on different wrap boundaries. NOTE what this "
            + "stands down: the entire BLOCK model — list and paragraph spacing, fenced and "
            + "indented code, tables, headings, links, raw HTML, the usage badge and the "
            + "AskUserQuestion card — is pinned only by these fixtures and by "
            + "`structuredCorpusNeverMateriallyOverReserves`, which is generated and therefore "
            + "coarse. `wrapArithmeticStaysCalibrated` covers the wrapped-line arithmetic ONLY: "
            + "its corpus is single-paragraph prose with no newlines, so it sees none of the "
            + "block model. To pin this suite too, re-derive the fixture text and budgets at "
            + "your size."
    }

    @Test("every row kind's estimate stays inside its point budget at both column widths",
          .enabled(if: hostIsAtCalibratedTextSize, Comment(rawValue: textSizePreconditionMessage)))
    func perKindErrorStaysWithinBudget() throws {
        let measurements = try Self.measureEveryKind()
        var failures: [String] = []
        let budgetByID = Dictionary(uniqueKeysWithValues: Self.budgets.map { ($0.id, $0) })

        for measurement in measurements {
            guard let budget = budgetByID[measurement.id] else {
                failures.append("\(measurement.id) @\(Self.f(measurement.width)): no budget declared "
                    + "— every row kind must be pinned, add one")
                continue
            }
            guard abs(measurement.delta) > budget.points else { continue }
            failures.append("""
                \(measurement.id) @\(Self.f(measurement.width)): \
                exact \(Self.f(measurement.exact)), estimate \(Self.f(measurement.estimate)), \
                delta \(Self.sf(measurement.delta)) \
                (\(Self.sf(measurement.percent))%) — budget is ±\(Self.f(budget.points)) pt \
                (±\(Self.f(budget.percent))% of this row), and the estimator used to score \
                \(budget.achieved)
                """)
        }

        // Every declared budget must correspond to a row actually measured, or the
        // fixture has drifted away from the thing being guarded.
        let measured = Set(measurements.map(\.id))
        for budget in Self.budgets where !measured.contains(budget.id) {
            failures.append("\(budget.id): budgeted but never measured — the fixture no longer "
                + "produces this row kind")
        }

        #expect(failures.isEmpty, Comment(rawValue: "\n" + failures.joined(separator: "\n")
            + "\n\n" + Self.table(measurements)))
    }

    @Test("no row kind reserves more space than it measures, at either column width",
          .enabled(if: hostIsAtCalibratedTextSize, Comment(rawValue: textSizePreconditionMessage)))
    func residualBiasKeepsCorrectionsGrowing() throws {
        let measurements = try Self.measureEveryKind()
        // 0.5 pt of slack because `correctRowHeightIfNeeded` itself ignores
        // differences that small — below it there is no correction to have a
        // direction. Collected as strings, not as the measurement values, so the
        // failure reads as a list of rows rather than a wall of struct dumps.
        let overshooting = measurements
            .filter { $0.delta > 0.5 }
            .map { "\($0.id) @\(Self.f($0.width)): \(Self.sf($0.delta)) pt" }
        #expect(overshooting.isEmpty, Comment(rawValue: """
            these rows reserve MORE space than they measure, so realizing them SHRINKS the row \
            and pulls not-yet-read content up into the reading area:
            \(overshooting.map { "  " + $0 }.joined(separator: "\n"))

            \(Self.table(measurements))
            """))
    }

    // MARK: - Wrapped-line arithmetic

    /// The per-kind fixtures above are specific messages. This one guards the
    /// arithmetic underneath them — `ceil(length / charsPerLine)` against the
    /// character advance the estimator derives from the theme's body font — over a
    /// generated corpus that crosses every wrap boundary in range.
    ///
    /// It is the test the `wrapCalibration` constant's doc comment points at. The
    /// calibration factor sits on a broad plateau: pushing it 4% either way costs
    /// more than ten points of exactness, so the thresholds here catch a constant
    /// that has drifted off the plateau as well as a font-derivation that has
    /// broken outright.
    @Test("wrapped-line arithmetic matches the laid-out line count for ~94% of paragraphs, and errs low")
    func wrapArithmeticStaysCalibrated() throws {
        var exact = 0
        var over = 0
        var under = 0
        var signedLineError = 0
        var worst: (text: String, width: CGFloat, delta: CGFloat)?

        for width in Self.widths {
            for role in [TranscriptBubbleGeometry.Role.assistant, .user] {
                let bodyWidth = TranscriptBubbleGeometry.bodyWidth(columnWidth: width, role: role)
                for text in Self.paragraphCorpus {
                    let item: TranscriptItem = role == .user
                        ? .userPrompt(id: "p", text: text, timestamp: nil)
                        : .assistantText(id: "p", text: text, timestamp: nil, usage: nil)
                    let node = TranscriptRenderNode(id: "p", kind: .chatBubble(item), badgeUsage: nil)
                    let estimate = TableTranscriptView.Coordinator.estimate(for: node, width: width)
                    let measured = TranscriptBubbleGeometry.rowHeight(
                        blocksHeight: MessageBlockMeasurer().blocksHeight(
                            MarkdownAttributedRenderer.renderBlocks(
                                text, theme: .chatBubble, linkResolver: nil),
                            bodyWidth: bodyWidth))
                    let delta = estimate - measured
                    signedLineError += Int((delta / Self.renderedLineHeight).rounded())
                    if delta > 0.5 {
                        over += 1
                    } else if delta < -0.5 {
                        under += 1
                    } else {
                        exact += 1
                    }
                    if abs(delta) > abs(worst?.delta ?? 0) {
                        worst = (text, width, delta)
                    }
                }
            }
        }

        let total = exact + over + under
        let exactRate = Double(exact) / Double(total)
        let meanLineError = CGFloat(signedLineError) / CGFloat(total)
        // Deliberately NOT gated on the host text size, unlike the fixture tests:
        // it generates its corpus and compares against measurement, so it is one of
        // the two things here that still guard anything on a large-text host. The
        // thresholds were swept at 13 pt, so a red at another size may be
        // re-calibration rather than regression — say so rather than let the reader
        // guess.
        let sizeCaveat = NSFont.preferredFont(forTextStyle: .body).pointSize
            == Self.calibratedBodyPointSize
            ? ""
            : " NOTE: `wrapCalibration` was swept at \(Self.f(Self.calibratedBodyPointSize)) pt and "
                + "this host renders at "
                + "\(Self.f(NSFont.preferredFont(forTextStyle: .body).pointSize)) pt, so re-derive "
                + "the factor before treating this as a regression."
        let summary = "\(total) single-paragraph messages across 2 column widths x 2 roles: "
            + "\(exact) exact, \(under) one line short, \(over) one line long (exact rate "
            + "\(String(format: "%.1f", exactRate * 100))%, mean "
            + "\(String(format: "%+.3f", meanLineError)) lines). Worst: \(Self.sf(worst?.delta ?? 0)) "
            + "pt at width \(Self.f(worst?.width ?? 0)) on a \(worst?.text.count ?? 0)-character "
            + "paragraph."

        #expect(exactRate >= 0.92, Comment(rawValue: "the wrapped-line arithmetic has drifted off "
            + "its calibration plateau. \(summary)\(sizeCaveat)"))
        #expect(meanLineError <= 0, Comment(rawValue: "the wrapped-line arithmetic now over-counts "
            + "lines on average, so corrections shrink rows. \(summary)\(sizeCaveat)"))
        #expect(under > over, Comment(rawValue: "the residual no longer leans toward the growing "
            + "side. \(summary)\(sizeCaveat)"))
        // A miss is a wrap boundary landing on the wrong side, which is worth
        // exactly one rendered line. Anything larger is a modelling error.
        #expect(abs(worst?.delta ?? 0) <= Self.renderedLineHeight,
                Comment(rawValue: "a paragraph missed by more than one rendered line. "
                    + "\(summary)\(sizeCaveat)"))
    }

    // MARK: - Generated structured corpus

    /// The counterpart to `wrapArithmeticStaysCalibrated`, and the answer to how
    /// the link and raw-HTML over-reservations went unnoticed: they were unnoticed
    /// because no HAND-WRITTEN fixture happened to contain a link or a `<details>`
    /// block, and one fixture per structural branch will always have that hole.
    /// That corpus is single-paragraph prose, so it sees the wrap arithmetic and
    /// nothing else. This one generates whole MESSAGES out of randomly combined
    /// blocks — prose, bullet and ordered lists, fenced and indented code, GFM
    /// tables, headings, links, raw HTML, inline markup and blockquotes, at both
    /// column widths, both roles, with and without a usage badge — and asserts the
    /// property that actually matters rather than exactness.
    ///
    /// It cannot assert exactness: generated text lands on wrap boundaries all the
    /// time, and every such landing is worth a whole rendered line. What it CAN
    /// assert is that the estimator does not MATERIALLY over-reserve, because
    /// over-reserving is the defect this whole guard exists for — a row that
    /// shrinks when it realizes pulls unread content up into the reading area.
    ///
    /// Three thresholds, each sized just past what is achieved today:
    ///
    /// - no single message over-reserves by more than three rendered lines. A new
    ///   unmodelled block kind shows up here first and loudly: disabling the
    ///   raw-HTML branch takes the worst case to +288 pt;
    /// - fewer than 9.5% of messages over-reserve at all (8.2% today). Disabling
    ///   the link handling alone takes it to 17.6%, because that shape recurs;
    /// - the mean signed error stays at or under +0.5 pt per message (-0.4 today,
    ///   i.e. the estimator under-reserves on average across structured text).
    ///
    /// The residual is not noise and is worth knowing before re-tuning: 150 of the
    /// 262 over-reservations are exactly one rendered line (+16) or one line plus a
    /// list gap (+20), and the larger ones are the nested-list / loose-continuation
    /// shape `chatBubbleEstimate` documents as deliberately unmodelled, where the
    /// RENDERER collapses content this estimate correctly predicts.
    ///
    /// Ungated on host text size for the same reason as
    /// `wrapArithmeticStaysCalibrated`: it measures rather than assumes, so it is
    /// one of the two things still guarding the estimator when the fixture suites
    /// stand down.
    @Test("a generated corpus of structured messages never materially over-reserves")
    func structuredCorpusNeverMateriallyOverReserves() throws {
        var overReserving: [(label: String, exact: CGFloat, estimate: CGFloat, delta: CGFloat)] = []
        var signedTotal: CGFloat = 0
        var total = 0
        var generator = SplitMix64(seed: 0x5EED_1234)

        for _ in 0..<Self.corpusMessageCount {
            let (shape, text) = Self.randomMessage(&generator)
            for width in Self.widths {
                for role in [TranscriptBubbleGeometry.Role.assistant, .user] {
                    for badged in [false, true] {
                        // A user prompt never carries a usage badge.
                        let usage: TokenUsage? = (badged && role == .assistant)
                            ? TokenUsage(inputTokens: 124_000, cacheCreationTokens: 0, cacheReadTokens: 0)
                            : nil
                        let item: TranscriptItem = role == .user
                            ? .userPrompt(id: "corpus", text: text, timestamp: nil)
                            : .assistantText(id: "corpus", text: text, timestamp: nil, usage: usage)
                        let node = TranscriptRenderNode(id: "corpus", kind: .chatBubble(item),
                                                        badgeUsage: usage)
                        let estimate = TableTranscriptView.Coordinator.estimate(for: node, width: width)
                        let measured = TranscriptBubbleGeometry.rowHeight(
                            blocksHeight: MessageBlockMeasurer().blocksHeight(
                                TranscriptBubbleGeometry.composedBlocks(
                                    for: item, badgeUsage: usage, linkResolver: nil),
                                bodyWidth: TranscriptBubbleGeometry.bodyWidth(
                                    columnWidth: width, role: role)))
                        total += 1
                        signedTotal += estimate - measured
                        if estimate - measured > 0.5 {
                            overReserving.append((
                                "\(shape) @\(Self.f(width)) \(role == .user ? "user" : "assistant")"
                                    + (usage != nil ? " +badge" : ""),
                                measured, estimate, estimate - measured))
                        }
                    }
                }
            }
        }

        // Two of the three thresholds below are absolute point counts swept at
        // 13 pt (only `worst` scales with the font), so say so when the host
        // differs rather than let a re-calibration read as a regression.
        let sizeCaveat = NSFont.preferredFont(forTextStyle: .body).pointSize
            == Self.calibratedBodyPointSize
            ? ""
            : " NOTE: the rate and mean thresholds are absolute and were swept at "
                + "\(Self.f(Self.calibratedBodyPointSize)) pt; this host renders at "
                + "\(Self.f(NSFont.preferredFont(forTextStyle: .body).pointSize)) pt, so re-derive "
                + "them before treating this as a regression."
        let worst = overReserving.map(\.delta).max() ?? 0
        let rate = Double(overReserving.count) / Double(total)
        let mean = signedTotal / CGFloat(total)
        var histogram: [Int: Int] = [:]
        for row in overReserving { histogram[Int(row.delta.rounded()), default: 0] += 1 }
        let bySize = histogram.sorted { $0.key < $1.key }
            .map { "+\($0.key): \($0.value)" }.joined(separator: ", ")
        let offenders = overReserving.sorted { $0.delta > $1.delta }.prefix(8)
            .map { "  \($0.label): measured \(Self.f($0.exact)), estimate \(Self.f($0.estimate)), "
                + Self.sf($0.delta) }
            .joined(separator: "\n")
        let summary = "\(total) generated messages (\(Self.corpusMessageCount) shapes x 2 widths "
            + "x 2 roles x badge): \(overReserving.count) over-reserve "
            + "(\(String(format: "%.1f", rate * 100))%), worst \(Self.sf(worst)) pt, mean "
            + "\(Self.sf(mean)) pt. Over-reservations by size: \(bySize).\nWorst offenders:\n"
            + offenders

        // Achieved: worst +40 pt, rate 8.2% (262 of 3200), mean -0.4 pt.
        #expect(worst <= 3 * Self.renderedLineHeight, Comment(rawValue: "a generated message "
            + "over-reserved by more than three rendered lines, which is what a whole unmodelled "
            + "block kind looks like. \(summary)\(sizeCaveat)"))
        #expect(rate < 0.095, Comment(rawValue: "too many generated messages over-reserve — a "
            + "structural shape has stopped being modelled. \(summary)\(sizeCaveat)"))
        #expect(mean <= 0.5, Comment(rawValue: "the estimator now over-reserves on average across "
            + "structured messages. \(summary)\(sizeCaveat)"))
    }

    private static let corpusMessageCount = 400

    /// A deterministic PRNG, so the corpus is the same on every run and on every
    /// machine — a fuzzer that finds a different defect each run cannot be a
    /// regression guard.
    private struct SplitMix64 {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int {
            range.lowerBound + Int(next() % UInt64(range.count))
        }
        mutating func pick<T>(_ items: [T]) -> T { items[int(0...(items.count - 1))] }
    }

    private static let corpusWords = ("the quick brown fox jumps over a lazy dog while nine bright "
        + "ravens watch from the old stone wall and consider whether the transcript estimator will "
        + "finally agree with the measurement it stands in for because a biased reservation reads "
        + "to a reader as motion")
        .split(separator: " ").map(String.init)

    private static func corpusSentence(_ rng: inout SplitMix64, _ count: Int) -> String {
        (0..<count).map { _ in rng.pick(corpusWords) }.joined(separator: " ")
    }

    /// One to five randomly chosen blocks. The label names the blocks in order,
    /// and the separator between each pair, so a failure says which combination
    /// broke and whether a blank line was involved.
    ///
    /// A third of the joins are a SINGLE newline. That is not variety for its own
    /// sake: several branches in `chatBubbleEstimate` only fire at the start of a
    /// block, and joining every pair with a blank line meant no seed could ever
    /// produce a block that INTERRUPTS a paragraph. Raw HTML interrupting a
    /// paragraph was a +96 pt over-reservation — twice this test's own ceiling —
    /// and it sat inside the corpus's blind spot rather than outside its sample.
    private static func randomMessage(_ rng: inout SplitMix64) -> (String, String) {
        var label = ""
        var text = ""
        for index in 0...rng.int(0...4) {
            let (name, block) = randomBlock(&rng)
            if index > 0 {
                // A single newline one time in three, so block-start-gated
                // branches are exercised in their interrupting position too.
                let tight = rng.int(0...2) == 0
                text += tight ? "\n" : "\n\n"
                label += tight ? ">" : "+"
            }
            label += name
            text += block
        }
        return (label, text)
    }

    private static func randomBlock(_ rng: inout SplitMix64) -> (String, String) {
        switch rng.int(0...10) {
        case 0:
            return ("prose", corpusSentence(&rng, rng.int(3...60)))
        case 1:
            return ("list", (0...rng.int(1...5))
                .map { _ in "- " + corpusSentence(&rng, rng.int(3...20)) }.joined(separator: "\n"))
        case 2:
            let count = rng.int(2...5)
            return ("ordered", (1...count)
                .map { index in "\(index). " + corpusSentence(&rng, rng.int(3...15)) }
                .joined(separator: "\n"))
        case 3:
            let code = (0...rng.int(1...8)).map { _ in "let \(rng.pick(corpusWords)) = \(rng.int(0...999))" }
            return ("fence", "```swift\n" + code.joined(separator: "\n") + "\n```")
        case 4:
            return ("indented", (0...rng.int(1...6))
                .map { _ in "    let \(rng.pick(corpusWords)) = \(rng.int(0...999))" }
                .joined(separator: "\n"))
        case 5:
            let columns = rng.int(2...4)
            let header = "| " + (0..<columns).map { _ in rng.pick(corpusWords) }.joined(separator: " | ") + " |"
            let separator = "| " + (0..<columns).map { _ in "---" }.joined(separator: " | ") + " |"
            let rows = (0...rng.int(1...4)).map { _ in
                "| " + (0..<columns).map { _ in rng.pick(corpusWords) }.joined(separator: " | ") + " |"
            }
            return ("table", ([header, separator] + rows).joined(separator: "\n"))
        case 6:
            return ("heading", String(repeating: "#", count: rng.int(1...3)) + " "
                + corpusSentence(&rng, rng.int(2...8)))
        case 7:
            let path = (0...rng.int(1...6)).map { _ in rng.pick(corpusWords) }.joined(separator: "/")
            return ("link", "See [\(corpusSentence(&rng, rng.int(1...4)))](https://example.com/\(path).md) "
                + corpusSentence(&rng, rng.int(3...25)))
        case 8:
            return ("html", "<details>\n<summary>\(corpusSentence(&rng, 3))</summary>\n\n"
                + corpusSentence(&rng, rng.int(5...20)) + "\n\n</details>")
        case 9:
            return ("quote", "> " + corpusSentence(&rng, rng.int(5...40)))
        default:
            return ("inline", corpusSentence(&rng, rng.int(3...15))
                + " `\(rng.pick(corpusWords))_\(rng.pick(corpusWords))()` "
                + corpusSentence(&rng, rng.int(3...15))
                + " **\(rng.pick(corpusWords))** and *\(rng.pick(corpusWords))*.")
        }
    }

    /// Height of one wrapped body line, read off the production renderer rather
    /// than assumed, so this file does not hard-code the 16 pt that only holds at
    /// the default system text size.
    private static let renderedLineHeight: CGFloat = {
        let one = proseHeight("one", bodyWidth: 656)
        let two = proseHeight("one\ntwo", bodyWidth: 656)
        // Two source lines render as two paragraph units: two lines plus one
        // paragraph spacing. Subtracting the theme's own spacing leaves the line.
        return two - one - TranscriptTextTheme.chatBubble.paragraphSpacing
    }()

    /// Paragraphs of every length in range, from two vocabularies with different
    /// word-length distributions, so the corpus crosses each wrap boundary at
    /// several different break patterns. Deterministic.
    private static let paragraphCorpus: [String] = {
        let words = ("the quick brown fox jumps over a lazy dog while nine bright ravens watch from "
            + "the old stone wall and consider whether the transcript estimator will finally agree "
            + "with the measurement it is standing in for today because a systematically biased "
            + "reservation shows up to a reader as content sliding underneath the cursor rather "
            + "than as an incorrect number displayed anywhere at all in the interface")
            .split(separator: " ").map(String.init)
        var texts: [String] = []
        for count in 1...120 {
            texts.append((0..<count).map { words[$0 % words.count] }.joined(separator: " "))
            texts.append((0..<count).map { words[(count + $0 * 3) % words.count] }.joined(separator: " "))
        }
        return texts
    }()

    // MARK: - Measurement

    private struct Measurement {
        let id: String
        let kind: String
        let width: CGFloat
        let exact: CGFloat
        let estimate: CGFloat
        var delta: CGFloat { estimate - exact }
        var percent: CGFloat { exact > 0 ? delta / exact * 100 : 0 }
    }

    /// Measures every fixture row at both column widths: the EXACT height a
    /// realized row would get, and the estimate `heightOfRow` would have served
    /// before it realized.
    private static func measureEveryKind() throws -> [Measurement] {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let imagePath = scratch.appendingPathComponent("shot.png").path
        try writePNG(width: 400, height: 300, to: imagePath)

        var measurements: [Measurement] = []
        for width in widths {
            let suiteName = "estimator-accuracy-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let appState = AppState(userDefaults: defaults)

            let nodes = characterizationNodes(imagePath: imagePath)
            #expect(nodes.count <= TableTranscriptView.Coordinator.bottomEagerWindow,
                    Comment(rawValue: "fixture must fit the bottom-window precompute so EVERY row is "
                        + "measured exactly (\(nodes.count) nodes)"))

            let scene = makeScene(appState: appState, nodes: nodes)
            defer { withExtendedLifetime(scene.coordinator) {} }
            let pinned = pin(scene, to: width)
            #expect(pinned.pinnedWidth == width,
                    Comment(rawValue: "column width must be pinned to \(width) before recording "
                        + "(settled=\(pinned.pinnedWidth))"))

            // Exact heights: the same `measuredHeight` a realized row gets.
            scene.coordinator.precomputeBottomWindow()
            var exactByID: [String: CGFloat] = [:]
            for node in nodes {
                let exact = try #require(scene.coordinator.cachedExactHeight(for: node),
                                         "every fixture row must be measured exactly: \(node.id)")
                exactByID[node.id] = exact
            }

            // Realizing every row must not move a single cached height — that is
            // what makes the precompute a legitimate stand-in for realization.
            realizeAllRows(scene, count: nodes.count)
            #expect(scene.tableView.bounds.width == width,
                    Comment(rawValue: "realizing rows moved the column width "
                        + "(\(scene.tableView.bounds.width))"))
            var drifted: [String] = []
            for node in nodes where scene.coordinator.cachedExactHeight(for: node) != exactByID[node.id] {
                drifted.append("\(node.id): \(String(describing: exactByID[node.id])) → "
                    + "\(String(describing: scene.coordinator.cachedExactHeight(for: node)))")
            }
            #expect(drifted.isEmpty,
                    Comment(rawValue: "realization changed an exact height: \(drifted.joined(separator: "; "))"))

            for node in nodes {
                measurements.append(Measurement(
                    id: node.id,
                    kind: label(for: node),
                    width: width,
                    exact: exactByID[node.id] ?? 0,
                    estimate: TableTranscriptView.Coordinator.estimate(for: node, width: width)))
            }
        }
        return measurements
    }

    /// The full signed-error table, attached to any failure so the reader sees the
    /// whole picture rather than the one row that tripped.
    private static func table(_ measurements: [Measurement]) -> String {
        var lines = ["signed error (estimate - exact), all kinds, both column widths:",
                     "host: \(ProcessInfo.processInfo.operatingSystemVersionString)",
                     "body font: \(NSFont.preferredFont(forTextStyle: .body).fontName) "
                        + "\(NSFont.preferredFont(forTextStyle: .body).pointSize) pt"]
        for width in widths {
            lines.append("--- column width \(f(width)) "
                + "(assistant body \(f(TranscriptBubbleGeometry.bodyWidth(columnWidth: width, role: .assistant)))"
                + ", user body \(f(TranscriptBubbleGeometry.bodyWidth(columnWidth: width, role: .user)))) ---")
            lines.append(pad("row kind", 17) + pad("id", 24) + rpad("exact", 9)
                + rpad("estimate", 10) + rpad("delta", 9) + rpad("pct", 9))
            for measurement in measurements where measurement.width == width {
                lines.append(pad(measurement.kind, 17) + pad(measurement.id, 24)
                    + rpad(f(measurement.exact), 9) + rpad(f(measurement.estimate), 10)
                    + rpad(sf(measurement.delta), 9) + rpad(sf(measurement.percent) + "%", 9))
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func proseHeight(_ markdown: String, bodyWidth: CGFloat) -> CGFloat {
        MessageBlockMeasurer().blocksHeight(
            MarkdownAttributedRenderer.renderBlocks(
                markdown, theme: .chatBubble, linkResolver: nil),
            bodyWidth: bodyWidth)
    }

    // MARK: - Fixtures

    private static let shortAssistantText = "Done — the row now measures exactly."

    /// Verbatim from `TableTranscriptHarness.allKindsFixture()`'s `k-assistant`.
    private static let twoParagraphAssistantText = """
        Here is the rundown. Each upstream item becomes a render node, cached by \
        `(id, contentVersion, width)` so a re-poll never rebuilds an unchanged row. \
        This paragraph is intentionally long so the assistant bubble has real height \
        and spans multiple wrapped lines.

        A second paragraph adds vertical extent so the card is comfortably taller than \
        one line and any clip is obvious.
        """

    private static let longAssistantText: String = {
        let paragraphs = [
            "The transcript pane sizes every row through one delegate callback, and that "
                + "callback has two moods. When the row's exact height is already cached it "
                + "returns the measurement; otherwise it returns a cheap arithmetic guess and "
                + "waits for the row to realize.",
            "That split is what keeps opening a long session constant-time. Measuring every "
                + "row of a sixteen-hundred-node transcript up front cost nearly four seconds "
                + "of blocked main thread, which is the freeze the whole redesign exists to "
                + "remove, so only the bottom window is measured eagerly.",
            "The price of the split is that an unrealized row occupies whatever the guess "
                + "said it would. If the guess is systematically large, the document is taller "
                + "than the content, and every realization shrinks a row and pulls the rows "
                + "below it upward past the reader's eye.",
            "A scroll anchor cannot fully hide that. The anchor holds one row still; the "
                + "content above and below still moves, and a reader watching a paragraph "
                + "they were halfway through notices immediately even when the arithmetic "
                + "afterwards is perfectly self-consistent.",
            "So the interesting question is not whether the guess is cheap — it is — but "
                + "how biased it is, in which direction, and whether the bias is dominated by "
                + "the constants it was given or by the shape of the arithmetic that consumes "
                + "them. Those are different repairs.",
            "Measuring that means comparing the guess against the same measurement the "
                + "realized row would produce, across every row kind the pane can show, at "
                + "both of the column widths the pane is ever laid out at, because the user "
                + "bubble's geometry actually changes between them.",
            "The decomposition matters more than the totals. A total tells you the estimate "
                + "is wrong; the terms tell you whether to change a number, change the "
                + "rounding, or stop charging a full blank line for something the renderer "
                + "draws as sixteen points of paragraph spacing.",
            "None of this is a defect in the measurement path itself. The measured height "
                + "and the drawn height agree to within a point, which the sibling harness "
                + "proves row by row; the gap being characterized here lives entirely on the "
                + "estimate side of the callback."
        ]
        return paragraphs.joined(separator: "\n\n")
    }()

    private static let shortUserText = "Can you check the row heights?"

    /// Sized to sit near a wrap boundary at the two USER body widths (582 pt at
    /// column 680, 617 pt at column 663 — the role branch in
    /// `outerHorizontal(for:columnWidth:)` makes a NARROWER column give a user
    /// bubble a WIDER body). Both geometries must land on the same measured height
    /// from different arithmetic, which is what makes it a boundary probe.
    private static let wrapBoundaryUserText = String(
        repeating: "check the wrapped line count here please ", count: 15)
        .trimmingCharacters(in: .whitespaces)

    private static let longUserText = "Walk me through the row-sizing path and the trade-offs, with "
        + "enough detail that this user bubble wraps across several lines in the column, and please "
        + "include what happens when the estimate and the measurement disagree by more than a line, "
        + "because that is the case I keep seeing while the transcript is still streaming."

    /// The fenced block's ``` delimiters and its language tag are NOT drawn, and
    /// the trailing newline the code-block visitor leaves behind IS — counting the
    /// source lines flat put this row 54 pt over.
    private static let codeBlockText = """
        Here is the sizing hook:

        ```swift
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            let width = max(tableView.bounds.width, 1)
            if let exact = cachedExactHeight(forRow: row) { return exact }
            return Self.estimate(for: nodes[row], width: width)
        }
        ```

        The estimate branch is the one being characterized.
        """

    /// List items are spaced with the tight `listItemSpacing`, not a full
    /// paragraph break, and the blank lines around the list draw nothing.
    private static let bulletListText = """
        The estimate is built from four inputs:

        - an assumed average character advance of seven points
        - an assumed rendered line height of eighteen points
        - a per-paragraph ceiling on the wrapped line count
        - a blank line charged for every paragraph break

        Each contributes independently to the total error.
        """

    /// Markdown LINKS, whose destinations are not drawn. Assistant prose is full
    /// of doc, PR and file links, and charging a 100-character URL as 100
    /// characters of prose reserved space that never appeared — measured +16 pt per
    /// link. Covers an inline link, two in one paragraph, a link inside a list
    /// item, and a reference link whose `[1]: url` definition line draws nothing at
    /// all.
    private static let linksText = "See [the design note]"
        + "(https://example.com/acme/docs/specs/2026-07-26-fleet-supervision-design.md) for the "
        + "rationale, and [the requirements]"
        + "(https://example.com/acme/docs/specs/2026-07-26-fleet-supervision-requirements.md) for "
        + "the constraints it had to satisfy."
        + "\n\n- the estimate is corrected on realize, see [the callback]"
        + "(https://example.com/acme/blob/main/Sources/Table/TableTranscriptView.swift)"
        + "\n- the measurement path is unchanged"
        + "\n\nBackground is in [the original issue][1]."
        + "\n\n[1]: https://example.com/acme/issues/129"

    /// RAW HTML, which the renderer draws as NOTHING: it implements no
    /// `visitHTMLBlock`, so `defaultVisit` walks zero children and emits an empty
    /// string. Charging each source line as a paragraph reserved 96 pt of blank
    /// space for a `<details>` block. Covers a multi-line block, a self-closing
    /// tag, and a comment.
    private static let rawHTMLText = """
        Here is the evidence:

        <details>
        <summary>Full measurement table</summary>

        The rows that used to over-reserve are listed here.

        </details>

        <img src="https://example.com/shot.png" width="600">

        <!-- the note below is what actually renders -->

        Everything above this line draws nothing at all.
        """

    /// Raw HTML with NO blank line before it. CommonMark block types 1-6 may
    /// interrupt a paragraph, so gating the branch on a block start charged an
    /// interrupting `<div>` as six lines of prose — +96 pt, twice the ceiling the
    /// generated corpus allows for a whole message.
    private static let htmlInterruptingText = """
        Here is the evidence:
        <div class="measurement">
        <span>the renderer draws none of this</span>
        </div>
        """

    /// Prose that merely BEGINS with an angle bracket — an autolink, then inline
    /// HTML. Neither opens an HTML block, and treating them as one swallowed the
    /// rest of the paragraph and charged it nothing: measured -80 and -68 pt.
    private static let angleBracketProseText = """
        <https://example.com/acme/a/long/reference/path> is the reference we used, and this line         is long enough that it has to wrap at least once in the column.
        <span>note</span> that inline HTML does not open a block either, so this sentence is         prose and has to be charged as prose.
        """

    /// An indented code block immediately after a HEADING. An indented block is
    /// the one construct that cannot interrupt a paragraph — CommonMark reserves
    /// the indentation for lazy continuation — but it opens perfectly well after a
    /// heading, a table or a fence, and gating it on a blank line cost 80 pt.
    private static let indentedAfterHeadingText = """
        ## The sizing hook
            let width = max(tableView.bounds.width, 1)
            if let exact = cachedExactHeight(forRow: row) { return exact }
            return Self.estimate(for: nodes[row], width: width)
        """

    /// A four-space INDENTED code block — the other way markdown spells a code
    /// block, and the one that looks like ordinary prose to a line scan. It draws
    /// in the code face with no paragraph spacing between its lines, so charging
    /// each line as a paragraph cost 32 pt on three lines and 304 on twenty.
    private static let indentedCodeText = """
        The delegate callback reads:

            let width = max(tableView.bounds.width, 1)
            if let exact = cachedExactHeight(forRow: row) { return exact }
            return Self.estimate(for: nodes[row], width: width)

        Indented four spaces, with no fence in sight.
        """

    /// SETEXT headings, whose underline is not drawn and whose text is set in the
    /// scaled heading face. Both levels, plus a thematic break in the same message
    /// so the `---` disambiguation is pinned too: after a paragraph line it
    /// underlines that line, after a blank it is a rule of its own.
    private static let setextHeadingText = """
        A first-level heading
        =====================

        Some body text under it.

        A second-level heading
        ----------------------

        More body text.

        ---

        And a closing paragraph after a thematic break.
        """

    /// A GFM table written WITHOUT leading pipes, which cmark-gfm accepts. Only
    /// the delimiter row underneath identifies the header, so this shape is
    /// invisible to a scan that keys on a leading `|` and was charged as prose.
    private static let pipelessTableText = """
        Comparison, written without leading pipes:

        Path | Up-front cost | Clip risk
        --- | --- | ---
        Authoritative | measure visible rows | none
        Estimate+correct | cheap | high

        The renderer draws it as a grid all the same.
        """

    /// A list whose items carry INDENTED continuation lines, with one in the
    /// middle of the list rather than trailing it. `visitListItem` flattens an
    /// item's inline children, so the soft break before a continuation sits inside
    /// the item's own paragraph style and costs the tight `listItemSpacing` (4) —
    /// classifying the continuation as an ordinary paragraph charged 16 and
    /// over-reserved 12 pt per continuation. `assistant/bullet-list` has no
    /// continuations and cannot see it.
    private static let listContinuationText = """
        The estimator handles three list shapes:

        - a plain item that fits on one line
          and a continuation line belonging to that same item
        - a second item, to prove the continuation did not end the list
        - a third item to close it out

        Each continuation costs a list gap, not a paragraph break.
        """

    /// The table's source lines render as a grid block, NOT as prose. Charging
    /// them as both was 140 pt — an 81% over-reservation, the worst single defect
    /// this file guards.
    private static let tableText = """
        Comparison of the two paths:

        | Path | Up-front cost | Clip risk | Gap risk |
        | --- | --- | --- | --- |
        | Authoritative | measure visible rows | none | none |
        | Estimate+correct | cheap | high (laggy correction) | medium |
        | Greedy unbounded | cheap | low | very high (~600pt) |

        The table view renders this as a grid attachment.
        """

    private static let badgeText = "This assistant message carries a token-usage badge that must "
        + "render fully inside the bubble, beneath the body text."

    /// A badged message whose last paragraph is a LIST ITEM. The badge then pays
    /// the tight `listItemSpacing` (4) rather than a full paragraph break, so the
    /// whole badge costs 15 pt and not 27 — the shape an unconditional
    /// `paragraphSpacing` over-reserved by 12.
    private static let badgeAfterBulletsText = """
        Summary of what changed:

        - the line height now comes from the font
        - the table rows are counted exactly once
        """

    /// A badged message whose last paragraph is a fenced CODE BLOCK, whose style
    /// sets no paragraph spacing at all: the badge costs just its own 11 pt line.
    private static let badgeAfterFenceText = """
        The sizing hook now reads:

        ```swift
        let width = max(tableView.bounds.width, 1)
        return Self.estimate(for: nodes[row], width: width)
        ```
        """

    /// Single newlines with NO blank line between them — typed notes, an
    /// address-style block, a short list someone did not mark up. `visitSoftBreak`
    /// emits the break INSIDE the paragraph, but TextKit still treats it as a
    /// paragraph terminator and stamps the paragraph style's 16 pt
    /// `paragraphSpacing` after every one, so a three-line note is 3 lines PLUS
    /// two full breaks — not the tight 3 lines it looks like. Every other prose
    /// fixture here separates paragraphs with a blank line, so without this one
    /// the soft-break shape is unpinned.
    ///
    /// Line lengths are kept clear of a wrap boundary on purpose: three lines that
    /// draw as one each and one that draws as two, at BOTH body widths. Probing the
    /// boundary is `user/wrap-boundary`'s job — this fixture's job is the spacing,
    /// and a fixture that does two things at once tells you neither when it reds.
    private static let softBreakText = """
        Notes from the call, one per line:
        the estimator reserves space for rows nobody has looked at yet, and a biased guess is \
        therefore something the reader perceives as motion rather than as a wrong number
        the correction lands when the row realizes
        direction matters less than magnitude here
        """

    /// The same structure as the LF fixtures, written with Windows line endings.
    /// `"\r\n"` is ONE Swift `Character`, so `split(separator: "\n")` finds no
    /// separator in it at all and the whole message collapses to a single
    /// estimated line — 48 pt against a rendered 128. Pinned at both widths
    /// because the collapse is width-independent and silent.
    private static let crlfText = "Windows-pasted notes:\r\n\r\n- first item, long enough that it "
        + "does not sit on a wrap boundary\r\n- second item, also comfortably clear of one\r\n\r\n"
        + "```swift\r\nlet a = 1\r\nlet b = 2\r\n```\r\n\r\n| Field | Value |\r\n| --- | --- |\r\n"
        + "| one | two |\r\n\r\nThat is the whole paste."

    /// The smallest card the pane can show, the largest shape worth pinning, and
    /// one whose question text wraps well past what the counts predict.
    ///
    /// Each payload MUST be a single line: a `#"""` raw string does not treat a
    /// trailing `\` as a line continuation (raw strings need `\#`), so the
    /// multi-line form this fixture used to carry embedded literal backslashes and
    /// newlines, did not decode, and silently measured the card's raw-JSON
    /// FALLBACK block instead of a card. `askCardFixturesAreValidJSON` holds that
    /// shut.
    private static let askCardFixtures: [(id: String, json: String, answer: String, decodes: Bool)] = [
        (id: "card/askUserQuestion",
         json: #"{"questions":[{"question":"Which sizing path should drive row height?","header":"Sizing","multiSelect":false,"options":[{"label":"Authoritative heightOfRow","description":"Measure the real height up front, cached."},{"label":"Estimate then correct","description":"Cheap estimate, patch via noteHeightOfRows."}]}]}"#,
         answer: "Authoritative heightOfRow", decodes: true),
        (id: "card/askUserQuestion-min",
         json: #"{"questions":[{"question":"Proceed?","header":"Go","multiSelect":false,"options":[{"label":"Yes","description":"Do it."}]}]}"#,
         answer: "Yes", decodes: true),
        (id: "card/askUserQuestion-max",
         json: #"{"questions":[{"question":"Path?","header":"A","multiSelect":false,"options":[{"label":"One","description":"x"},{"label":"Two","description":"y"}]},{"question":"Bias?","header":"B","multiSelect":false,"options":[{"label":"Low","description":"x"},{"label":"High","description":"y"}]},{"question":"Ship?","header":"C","multiSelect":false,"options":[{"label":"Now","description":"x"},{"label":"Later","description":"y"}]}]}"#,
         answer: "One", decodes: true),
        // Malformed but KEY-BEARING: a renamed top-level key, which is exactly what
        // the card's fallback block exists for. Counting `"question":` /
        // `"label":` out of a payload like this reported a full card and
        // over-reserved 139 pt against the 66 pt block that actually renders.
        (id: "card/askUserQuestion-malformed",
         json: #"{"quesions":[{"question":"Proceed?","header":"Go","multiSelect":false,"options":[{"label":"Yes","description":"a"},{"label":"No","description":"b"}]}]}"#,
         answer: "Yes", decodes: false),
        // Malformed in an OPTIONAL field. `decodeIfPresent` THROWS on a
        // present-but-wrong-typed value, so this decodes against a mirror of the
        // required fields and fails against the card — the drift that re-created
        // the +139 pt over-reservation. Only sharing the card's own types closes it.
        (id: "card/askUserQuestion-optional-typed",
         json: #"{"questions":[{"question":"Proceed?","header":"Go","multiSelect":false,"options":[{"label":"Yes","description":5},{"label":"No","description":6}]}]}"#,
         answer: "Yes", decodes: false),
        // Options with no description draw one line less each.
        (id: "card/askUserQuestion-bare-options",
         json: #"{"questions":[{"question":"Proceed?","header":"Go","multiSelect":false,"options":[{"label":"Yes"},{"label":"No"}]}]}"#,
         answer: "Yes", decodes: true),
        (id: "card/askUserQuestion-wrapping",
         json: #"{"questions":[{"question":"This question is deliberately very long indeed, so long that it must wrap across at least three separate lines inside the card at either of the column widths the transcript pane is ever laid out at, which is the shape a count-based model cannot see.","header":"Sizing","multiSelect":false,"options":[{"label":"A","description":"first"},{"label":"B","description":"second"}]}]}"#,
         answer: "A", decodes: true)
    ]

    /// Every row kind the guard covers, as render nodes. Kept under
    /// `bottomEagerWindow` so the precompute measures all of them exactly.
    private static func characterizationNodes(imagePath: String) -> [TranscriptRenderNode] {
        var items: [TranscriptItem] = []

        items.append(.assistantText(id: "assistant/short", text: shortAssistantText,
                                    timestamp: nil, usage: nil))
        items.append(.assistantText(id: "assistant/two-para", text: twoParagraphAssistantText,
                                    timestamp: nil, usage: nil))
        items.append(.assistantText(id: "assistant/long", text: longAssistantText,
                                    timestamp: nil, usage: nil))
        items.append(.assistantText(id: "assistant/code-block", text: codeBlockText,
                                    timestamp: nil, usage: nil))
        items.append(.assistantText(id: "assistant/bullet-list", text: bulletListText,
                                    timestamp: nil, usage: nil))
        items.append(.assistantText(id: "assistant/gfm-table", text: tableText,
                                    timestamp: nil, usage: nil))
        items.append(.assistantText(
            id: "assistant/image",
            text: "Here is the screenshot.\n\n[Image: source: \(imagePath)]",
            timestamp: nil,
            usage: nil))
        items.append(.assistantText(id: "assistant/html-interrupting", text: htmlInterruptingText,
                                    timestamp: nil, usage: nil))
        items.append(.assistantText(id: "assistant/angle-bracket-prose", text: angleBracketProseText,
                                    timestamp: nil, usage: nil))
        items.append(.assistantText(id: "assistant/indented-after-heading",
                                    text: indentedAfterHeadingText, timestamp: nil, usage: nil))
        items.append(.assistantText(id: "assistant/links", text: linksText,
                                    timestamp: nil, usage: nil))
        items.append(.assistantText(id: "assistant/raw-html", text: rawHTMLText,
                                    timestamp: nil, usage: nil))
        items.append(.assistantText(id: "assistant/indented-code", text: indentedCodeText,
                                    timestamp: nil, usage: nil))
        items.append(.assistantText(id: "assistant/setext-headings", text: setextHeadingText,
                                    timestamp: nil, usage: nil))
        items.append(.assistantText(id: "assistant/pipeless-table", text: pipelessTableText,
                                    timestamp: nil, usage: nil))
        items.append(.assistantText(id: "assistant/list-continuation", text: listContinuationText,
                                    timestamp: nil, usage: nil))
        items.append(.assistantText(id: "assistant/soft-breaks", text: softBreakText,
                                    timestamp: nil, usage: nil))
        items.append(.assistantText(id: "assistant/crlf", text: crlfText,
                                    timestamp: nil, usage: nil))
        items.append(.userPrompt(id: "user/short", text: shortUserText, timestamp: nil))
        items.append(.userPrompt(id: "user/long", text: longUserText, timestamp: nil))
        items.append(.userPrompt(id: "user/wrap-boundary", text: wrapBoundaryUserText, timestamp: nil))
        items.append(.assistantText(id: "assistant/badge-control", text: badgeText,
                                    timestamp: nil, usage: nil))
        items.append(.systemReminder(id: "activity/systemReminder", kind: .other,
                                     text: "This is a system reminder with a couple of sentences of "
                                         + "text so the row has more than a single line of source.",
                                     timestamp: nil))
        items.append(.toolCall(
            id: "activity/bash",
            name: "Bash",
            inputJSON: #"{"command":"swift build 2>&1 | tail -40 && echo done"}"#,
            inputTruncatedTo: nil,
            result: ToolResult(text: "Compiling TBDApp...\nBuild complete! (10.8s)\n",
                               truncatedTo: nil, isError: false),
            subagent: nil,
            timestamp: nil))
        items.append(.toolCall(
            id: "activity/task",
            name: "Task",
            inputJSON: #"{"description":"Investigate sizing","subagent_type":"Explore"}"#,
            inputTruncatedTo: nil,
            result: ToolResult(text: "Found the greedy measurement.", truncatedTo: nil, isError: false),
            subagent: Subagent(
                agentID: "activity/task-agent",
                agentType: "Explore",
                items: [.assistantText(id: "activity/task-a", text: "Looked at fittingHeight.",
                                       timestamp: nil, usage: nil)]),
            timestamp: nil))
        // AskUserQuestion cards, pinned at BOTH ends of the measured range rather
        // than at one sample of it: the card's height is linear in its question and
        // option counts, so a single shape leaves the slope unguarded.
        for fixture in Self.askCardFixtures {
            items.append(.toolCall(
                id: fixture.id,
                name: "AskUserQuestion",
                inputJSON: fixture.json,
                inputTruncatedTo: nil,
                result: ToolResult(text: fixture.answer, truncatedTo: nil, isError: false),
                subagent: nil,
                timestamp: nil))
        }

        var nodes = transcriptRenderNodes(from: items)

        // Badge row: same prose as `assistant/badge-control`, plus a usage badge,
        // so the two rows isolate the badge's own term (a paragraph break plus a
        // 9pt line — 27 pt, where the estimator used to charge one 18 pt line and
        // was the ONLY kind biased low).
        let badgeUsage = TokenUsage(inputTokens: 124_000, cacheCreationTokens: 0, cacheReadTokens: 0)
        let badgeItem = TranscriptItem.assistantText(id: "assistant/badge", text: badgeText,
                                                     timestamp: nil, usage: badgeUsage)
        nodes.append(TranscriptRenderNode(id: "assistant/badge",
                                          kind: .chatBubble(badgeItem),
                                          badgeUsage: badgeUsage))

        // The badge's leading spacing is whatever the paragraph it is appended to
        // carries, not a fixed `paragraphSpacing`: 4 pt after a list item, 0 after
        // a fenced code block whose style sets none. `assistant/badge` above is
        // plain prose and cannot see either.
        for (id, text) in [("assistant/badge-after-bullets", badgeAfterBulletsText),
                           ("assistant/badge-after-fence", badgeAfterFenceText)] {
            nodes.append(TranscriptRenderNode(
                id: id,
                kind: .chatBubble(.assistantText(id: id, text: text, timestamp: nil, usage: badgeUsage)),
                badgeUsage: badgeUsage))
        }

        // Activity-group summary: only `TranscriptPresentation.build` mints one.
        let groupItems: [TranscriptItem] = (0..<3).map { index in
            .toolCall(id: "grp-\(index)", name: "Read",
                      inputJSON: #"{"file_path":"/x/Sources/Part\#(index).swift"}"#,
                      inputTruncatedTo: nil,
                      result: ToolResult(text: "1\timport AppKit\n", truncatedTo: nil, isError: false),
                      subagent: nil, timestamp: nil)
        }
        let groupNodes = TranscriptPresentation.build(items: groupItems).nodes
        if let summary = groupNodes.first(where: {
            if case .activityGroupSummary = $0.kind { return true } else { return false }
        }) {
            nodes.append(summary)
        }

        // `transcriptRenderNodes` no longer emits `.subagentSummary` (a Task tool
        // call renders as an ordinary tool card and its subagent timeline is
        // dropped), but `estimate` still has a branch for the kind. Build one by
        // hand so the branch stays pinned rather than silently rotting.
        nodes.append(TranscriptRenderNode(
            id: "activity/subagentSummary",
            kind: .subagentSummary(parentItemID: "activity/task", count: 4, agentType: "Explore"),
            badgeUsage: nil))

        return nodes
    }

    private static func label(for node: TranscriptRenderNode) -> String {
        switch node.kind {
        case .chatBubble(let item):
            switch item {
            case .userPrompt: return "chatBubble/user"
            default: return "chatBubble/asst"
            }
        case .systemReminder: return "systemReminder"
        case .skillBody: return "skillBody"
        case .toolCall(_, let name, _, _, _, _): return "toolCall/\(name)"
        case .activityGroupSummary: return "activityGroup"
        case .subagentSummary: return "subagentSummary"
        }
    }

    // MARK: - Scene

    private struct Scene {
        let scrollView: NSScrollView
        let tableView: NSTableView
        let column: NSTableColumn
        let coordinator: TableTranscriptView.Coordinator
        let window: NSWindow
    }

    /// Mirrors `TableTranscriptHarness.makeScene` — a real offscreen scroll view +
    /// table over the production Coordinator. The `scrollerStyle = .legacy` pin is
    /// deliberate and kept (commit bbf8474c).
    private static func makeScene(appState: AppState, nodes: [TranscriptRenderNode]) -> Scene {
        let context = TranscriptCardContext(
            terminalID: nil,
            openTranscriptOverlay: { _ in },
            appState: appState,
            linkResolver: nil,
            onLinkClicked: nil
        )
        let coordinator = TableTranscriptView.Coordinator(context: context)

        let tableView = NSTableView()
        tableView.headerView = nil
        tableView.gridStyleMask = []
        tableView.backgroundColor = .clear
        tableView.usesAutomaticRowHeights = false
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.rowSizeStyle = .custom
        let column = NSTableColumn(identifier: TableTranscriptView.Coordinator.columnID)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.dataSource = coordinator
        tableView.delegate = coordinator

        let scrollView = NSScrollView()
        scrollView.scrollerStyle = .legacy
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        coordinator.tableView = tableView
        coordinator.scrollView = scrollView
        coordinator.nodes = nodes
        coordinator.previousNodes = nodes

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: viewportHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView

        return Scene(scrollView: scrollView, tableView: tableView, column: column,
                     coordinator: coordinator, window: window)
    }

    /// Drives the table's column width — the ONLY geometry input the coordinator
    /// reads (`columnWidth` is `tableView.bounds.width`) — to exactly `target`.
    ///
    /// A live pane reaches 663 because a legacy scroller claims 17pt out of a
    /// 680pt scroll view once the document outgrows the viewport, and 680 because
    /// an overlay scroller claims nothing. Rather than reproduce that race, the
    /// scroll view is laid out at `target` and the result checked; if the host's
    /// scroller took a bite anyway, the table is detached from the clip view so
    /// its own frame is authoritative. Either way the returned width is asserted
    /// by the caller before any number is recorded.
    private static func pin(
        _ scene: Scene,
        to target: CGFloat
    ) -> (naturalTableWidth: CGFloat, pinnedWidth: CGFloat, detached: Bool) {
        scene.scrollView.frame = NSRect(x: 0, y: 0, width: target, height: viewportHeight)
        scene.scrollView.layoutSubtreeIfNeeded()
        scene.tableView.layoutSubtreeIfNeeded()
        let natural = scene.tableView.bounds.width
        guard natural != target else { return (natural, natural, false) }

        scene.scrollView.documentView = nil
        scene.column.width = target
        scene.tableView.setFrameSize(NSSize(width: target, height: max(scene.tableView.frame.height, 1)))
        return (natural, scene.tableView.bounds.width, true)
    }

    /// Realizes every row once, as a user who scrolled the whole transcript would.
    private static func realizeAllRows(_ scene: Scene, count: Int) {
        for row in 0..<count {
            _ = scene.coordinator.tableView(scene.tableView, viewFor: nil, row: row)
        }
    }

    // MARK: - Helpers

    private static func makeScratchDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-estimator-accuracy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Solid opaque PNG so `TranscriptImageService`'s header probe reads real
    /// pixel dimensions.
    private static func writePNG(width: Int, height: Int, to path: String) throws {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let png = rep.representation(using: .png, properties: [:]) else {
            throw AccuracyError.couldNotMakePNG
        }
        try png.write(to: URL(fileURLWithPath: path))
    }

    nonisolated private static func f(_ value: CGFloat) -> String { String(format: "%.1f", value) }
    private static func sf(_ value: CGFloat) -> String { String(format: "%+.1f", value) }

    /// Left-aligned fixed-width cell (Swift's `String(format: "%-20@")` does not
    /// pad an `NSString`, so do it here).
    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }

    /// Right-aligned fixed-width cell.
    private static func rpad(_ text: String, _ width: Int) -> String {
        text.count >= width ? " " + text : String(repeating: " ", count: width - text.count) + text
    }

    enum AccuracyError: Error {
        case couldNotMakePNG
    }
}
