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
    /// grid rows counted once) out of font-derived line metrics. The 2 pt budget
    /// is there for a host whose font rounds a line differently, not for slack.
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
        Budget(id: "assistant/bullet-list", points: 2, percent: 1.3, achieved: "0.0"),
        Budget(id: "assistant/gfm-table", points: 2, percent: 1.2, achieved: "0.0"),
        Budget(id: "assistant/image", points: 2, percent: 1.0, achieved: "0.0"),
        Budget(id: "assistant/soft-breaks", points: 2, percent: 0.9, achieved: "0.0"),
        Budget(id: "assistant/crlf", points: 2, percent: 0.8, achieved: "0.0"),
        Budget(id: "assistant/badge-control", points: 2, percent: 3.1, achieved: "0.0"),
        Budget(id: "assistant/badge", points: 2, percent: 2.2, achieved: "0.0"),
        Budget(id: "user/short", points: 2, percent: 4.2, achieved: "0.0"),
        Budget(id: "user/long", points: 2, percent: 2.1, achieved: "0.0"),
        Budget(id: "user/wrap-boundary", points: 2, percent: 1.4, achieved: "0.0"),
        Budget(id: "activity/systemReminder", points: 0.5, percent: 2.3, achieved: "0.0"),
        Budget(id: "activity/bash", points: 0.5, percent: 2.3, achieved: "0.0"),
        Budget(id: "activity/task", points: 0.5, percent: 2.3, achieved: "0.0"),
        Budget(id: "grp-0#activity-group", points: 0.5, percent: 2.3, achieved: "0.0"),
        Budget(id: "activity/subagentSummary", points: 0.5, percent: 3.8, achieved: "0.0"),
        Budget(id: "card/askUserQuestion", points: 20, percent: 16.9, achieved: "-14.0")
    ]

    @Test("every row kind's estimate stays inside its point budget at both column widths")
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

    @Test("no row kind reserves more space than it measures, at either column width")
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
                            MarkdownAttributedRenderer.renderBlocks(text, theme: .chatBubble),
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
        let summary = """
            \(total) single-paragraph messages across 2 column widths × 2 roles: \
            \(exact) exact, \(under) one line short, \(over) one line long \
            (exact rate \(String(format: "%.1f", exactRate * 100))%, \
            mean \(String(format: "%+.3f", meanLineError)) lines). \
            Worst: \(Self.sf(worst?.delta ?? 0)) pt at width \(Self.f(worst?.width ?? 0)) \
            on a \(worst?.text.count ?? 0)-character paragraph.
            """

        // Achieved: 94.1% exact, mean -0.011 lines, 34 one line short against 23 one
        // line long, worst miss exactly one line.
        #expect(exactRate >= 0.92, Comment(rawValue: "the wrapped-line arithmetic has drifted off "
            + "its calibration plateau. \(summary)"))
        #expect(meanLineError <= 0, Comment(rawValue: "the wrapped-line arithmetic now over-counts "
            + "lines on average, so corrections shrink rows. \(summary)"))
        #expect(under > over, Comment(rawValue: "the residual no longer leans toward the growing "
            + "side. \(summary)"))
        // A miss is a wrap boundary landing on the wrong side, which is worth
        // exactly one rendered line. Anything larger is a modelling error.
        #expect(abs(worst?.delta ?? 0) <= Self.renderedLineHeight,
                Comment(rawValue: "a paragraph missed by more than one rendered line. \(summary)"))
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
            MarkdownAttributedRenderer.renderBlocks(markdown, theme: .chatBubble), bodyWidth: bodyWidth)
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
        items.append(.toolCall(
            id: "card/askUserQuestion",
            name: "AskUserQuestion",
            inputJSON: #"""
            {"questions":[{"question":"Which sizing path should drive row height?",\
            "header":"Sizing","multiSelect":false,\
            "options":[{"label":"Authoritative heightOfRow","description":"Measure the real height up front, cached."},\
            {"label":"Estimate then correct","description":"Cheap estimate, patch via noteHeightOfRows."}]}]}
            """#,
            inputTruncatedTo: nil,
            result: ToolResult(text: "Authoritative heightOfRow", truncatedTo: nil, isError: false),
            subagent: nil,
            timestamp: nil))

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
            appState: appState
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

    private static func f(_ value: CGFloat) -> String { String(format: "%.1f", value) }
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
