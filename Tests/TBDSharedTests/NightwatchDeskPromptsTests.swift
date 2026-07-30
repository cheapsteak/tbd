import Foundation
import Testing
import TBDShared

/// Tier 1 — pure string construction, no external state.
///
/// These prompts are injected into every desk session on every tick, so a wrong
/// instruction here is indistinguishable from a wrong policy: it silently drives
/// agent behavior fleet-wide. Nothing asserted on their content until
/// 2026-07-25, and by then the judge prompt had spent five days telling sessions
/// to run `tbd terminal close --all` — a command that has never existed — as its
/// context-ceiling remedy.
///
/// Each expectation below therefore pins a *policy invariant*, not phrasing.
/// Which means: when the policy itself changes, these change with it. They did on
/// 2026-07-29, when Adam authorized the nightwatch judge to merge his own
/// loop-perfect PRs. The invariant did not disappear — it narrowed, from "never
/// merge" to "merge only `zionts`-authored, only loop-perfect, never `--admin`,
/// and only on the nightwatch shift". A test that had merely banned the substring
/// `gh pr merge` would have had nothing left to say about that.
@Suite("Nightwatch desk prompt policy invariants")
struct NightwatchDeskPromptsTests {
    /// Modes that actually reach a desk session. `.off` is a programmer-error
    /// sentinel (`jobDescription` returns an ERROR string for it).
    static let liveModes: [NightwatchMode] = [.daywatch, .nightwatch]

    /// Every prompt string a desk session can receive, for one mode.
    private func prompts(mode: NightwatchMode, skillDir: String) -> [(label: String, text: String)] {
        [
            ("initialPrompt", NightwatchDeskPrompts.initialPrompt(mode: mode, skillDir: skillDir)),
            ("judgePrompt", NightwatchDeskPrompts.judgePrompt(mode: mode, skillDir: skillDir))
        ]
    }

    @Test("No prompt references a `tbd terminal close` subcommand", arguments: liveModes)
    func noPhantomCloseCommand(mode: NightwatchMode) {
        for (label, text) in prompts(mode: mode, skillDir: "/skill") {
            #expect(
                !text.contains("terminal close"),
                "\(mode) \(label) references `tbd terminal close`, which does not exist"
            )
        }
    }

    /// The context ceiling has exactly one correct remedy: the handoff relay.
    ///
    /// Asserted as "the relay is named" rather than "the old wording is absent",
    /// because the banned-substring form is defeated by any rephrasing — a
    /// reintroduction reading "mark for respawn" or "the daemon will restart
    /// you" sails past `!contains("flag for respawn")`. Pinning the positive
    /// invariant catches every phrasing, including ones nobody has written yet.
    @Test("The only context-ceiling remedy offered is the handoff relay", arguments: liveModes)
    func ceilingRemedyIsTheRelay(mode: NightwatchMode) {
        for (label, text) in prompts(mode: mode, skillDir: "/skill") {
            let mentionsCeiling = text.contains("600k") || text.lowercased().contains("context ceiling")
            #expect(mentionsCeiling, "\(mode) \(label) never states the context ceiling")

            #expect(
                text.contains("handoff.py"),
                "\(mode) \(label) raises the context ceiling without naming the handoff relay"
            )
            // No prompt may point the session at machine-local infrastructure as
            // its remedy. Asserted on concrete artifacts rather than on phrasing:
            // a blacklist of wordings like "will restart you" is defeated from
            // BOTH sides — a reworded reintroduction slips through, and the
            // sentence that *forbids* the promise trips it, because a prohibition
            // quotes what it prohibits.
            //
            // These names were listed in 2026-07-25 as things that "were never
            // built". That was wrong — `~/.fleet/babysitter_daemon.py` and its
            // watchdog are real, launchd-loaded, and predate the claim by a month
            // (see SKILL.md, "The babysitter daemon is machine-local"). The list
            // survives on a *different* rationale, which is the durable one: this
            // skill ships to any machine, and none of these paths is installed by
            // it, so naming one in a shipped prompt points most readers at
            // nothing. The relay is the remedy; a daemon is never the answer to a
            // context ceiling either way.
            for phantom in ["daemon.py", "watchdog.sh", "~/.fleet", "babysitter_daemon"] {
                #expect(
                    !text.contains(phantom),
                    "\(mode) \(label) points at \(phantom), which this skill does not install"
                )
            }
            // The 2026-07-25 error that this file's own comment propagated: the
            // prompts told the judge "nothing will restart you", which reads as
            // "your handoff is pointless" — the exact inference that makes a
            // session push through its ceiling. No prompt may deny that a
            // successor is reachable.
            for despair in ["Nothing will restart you", "nothing will restart you",
                            "no respawner", "there is no babysitter daemon"] {
                #expect(
                    !text.contains(despair),
                    "\(mode) \(label) tells the judge nothing can succeed it (\"\(despair)\"), which makes the handoff relay look pointless"
                )
            }
        }
    }

    /// The path a prompt tells a session to run must be a path the daemon
    /// installs. This is the structural guard for the phantom-command class:
    /// `tbd terminal close --all` was one, and a prompt naming an unshipped
    /// `scripts/handoff.py` would have been the next.
    @Test("Every script named in a desk prompt is actually shipped", arguments: liveModes)
    func promptedScriptsAreShipped(mode: NightwatchMode) {
        let shipped = Set(NightwatchSkillContent.scripts.map(\.name))
        let pattern = /scripts\/([A-Za-z0-9_.-]+\.(?:py|sh))/

        for (label, text) in prompts(mode: mode, skillDir: "/skill") {
            let named = Set(text.matches(of: pattern).map { String($0.1) })
            #expect(!named.isEmpty, "\(mode) \(label) names no script; the relay reference was lost")
            for script in named {
                #expect(
                    shipped.contains(script),
                    "\(mode) \(label) tells the session to run scripts/\(script), which PluginDirWriter does not install"
                )
            }
        }
    }

    @Test("Judge prompt points the context ceiling at the handoff relay", arguments: liveModes)
    func judgePromptNamesHandoffRelay(mode: NightwatchMode) {
        let text = NightwatchDeskPrompts.judgePrompt(mode: mode, skillDir: "/skill")
        #expect(text.contains("/skill/scripts/handoff.py"), "handoff.py path not interpolated from skillDir")
        #expect(text.contains("--check"))
        #expect(text.contains("--act --notes-file"))
        #expect(text.contains("--close-predecessor"))
        // The ordering rule is the whole point of the relay: a predecessor that
        // closes itself before the successor is up leaves the desk unwatched.
        #expect(text.contains("NEVER closes itself"))
    }

    /// Merging is authorized as of 2026-07-29, but narrowly. The dangerous
    /// failure is no longer "the prompt permits a merge" — it is a prompt that
    /// permits one while dropping any of the three limits, because a judge acting
    /// on a partial rule merges someone else's PR, or merges toward green, and
    /// both are irreversible on a repo behind a merge queue.
    ///
    /// So each limit is pinned separately: an author scope, a completeness bar,
    /// and the `--admin` prohibition. Dropping any single clause reds this test.
    @Test("Every prompt states all three limits on the merge authorization", arguments: liveModes)
    func mergeAuthorizationIsBounded(mode: NightwatchMode) {
        for (label, text) in prompts(mode: mode, skillDir: "/skill") {
            #expect(
                text.contains("`zionts`"),
                "\(mode) \(label) authorizes merging without naming whose PRs qualify"
            )
            #expect(
                text.contains("loop-perfect"),
                "\(mode) \(label) authorizes merging without the completeness bar"
            )
            #expect(
                text.contains("Never `--admin`") || text.contains("never `--admin`"),
                "\(mode) \(label) does not forbid `--admin`, which bypasses the gate entirely"
            )
            #expect(
                !text.contains("Merge PRs cleared"),
                "\(mode) \(label) authorizes merging cleared PRs in general, ignoring the author scope"
            )
        }
    }

    /// `gh pr merge` on a merge-queue repo *enqueues*, and prints
    /// `! The merge strategy for main is set by the merge queue` while succeeding.
    /// A judge that reads that `!` as a failure retries the merge, or reports a
    /// merged PR as blocked — so the prompt has to say which it is.
    @Test("Every prompt disambiguates the merge-queue warning", arguments: liveModes)
    func mergeQueueWarningExplained(mode: NightwatchMode) {
        for (label, text) in prompts(mode: mode, skillDir: "/skill") {
            #expect(
                text.contains("merge queue"),
                "\(mode) \(label) tells the judge to merge without mentioning the merge queue"
            )
            #expect(
                text.contains("warning, not a failure"),
                "\(mode) \(label) does not tell the judge the merge-queue notice is not an error"
            )
        }
    }

    /// Pins the *prohibition*, not the mere presence of the word. `contains("/closeout")`
    /// is satisfied by a prompt that tells the session to fire `/closeout` — the
    /// exact rule's opposite — so it proves nothing on its own.
    @Test("Every prompt forbids /closeout, and says why", arguments: liveModes)
    func closeoutForbidden(mode: NightwatchMode) {
        for (label, text) in prompts(mode: mode, skillDir: "/skill") {
            #expect(
                text.contains("NEVER trigger `/closeout`") || text.contains("Never trigger `/closeout`")
                    || text.contains("never trigger `/closeout`"),
                "\(mode) \(label) does not forbid /closeout"
            )
            #expect(
                text.lowercased().contains("archive question for the human"),
                "\(mode) \(label) states the /closeout rule without the reason it exists"
            )
            // A prohibition plus a licence elsewhere in the same prompt is not a
            // prohibition. `/closeout` may appear only in the forbidding sense.
            for licence in ["trigger `/closeout` on", "fire `/closeout`", "run `/closeout`",
                            "small_safe action"] {
                #expect(
                    !text.contains(licence),
                    "\(mode) \(label) forbids /closeout but also licenses it (\"\(licence)\")"
                )
            }
        }
    }

    /// The compiled SKILL.md is what the daemon writes to disk on every start,
    /// and `initialPrompt` sends the session there for its "full job description".
    /// It must not contradict the prompt.
    @Suite("Shipped nightwatch skill content")
    struct SkillContentTests {
        /// Two errors, in opposite directions, both of which SKILL.md has made.
        ///
        /// Before 2026-07-25 it advertised a "durable spine already on launchd"
        /// that this skill has never installed, and ticks escalated restarts for
        /// software with no install to restore. The 2026-07-25 correction then
        /// overshot into "none of it ever existed" — also false, since the
        /// operator's `com.fleet-babysitter` LaunchAgents predate that claim by a
        /// month — and that overshoot propagated into the desk prompts as
        /// "nothing will restart you".
        ///
        /// The true statement sits between them and is the one pinned here: *this
        /// skill ships no daemon*, which is a fact about the package rather than
        /// about any machine, and is therefore still true wherever it installs.
        @Test("SKILL.md claims neither a shipped daemon nor a universally absent one")
        func babysitterDaemonClaimIsScoped() {
            let md = NightwatchSkillContent.skillMd
            for claim in ["durable spine (already on launchd",
                          "These keep the critical safety net running",
                          "`scripts/daemon.py` (babysitter) — auto-approves"] {
                #expect(!md.contains(claim), "SKILL.md still asserts a shipped babysitter daemon: \(claim)")
            }
            #expect(!md.contains("None of it ever existed"),
                    "SKILL.md again claims no babysitter daemon exists anywhere; the operator's runs under launchd")
            #expect(md.contains("this skill does not ship one"),
                    "SKILL.md lost the scoped claim — that the absence is the package's, not the machine's")
        }

        @Test("SKILL.md carries the standing rules the prompts echo")
        func standingRulesPresent() {
            let md = NightwatchSkillContent.skillMd
            #expect(md.contains("NEVER trigger `/closeout`"))
            #expect(md.contains("handoff.py"))
        }

        @Test("tick.py ships the composer ghost-guard")
        func tickShipsGhostGuard() {
            // Without these, STRANDED counts dim ghost suggestions and SGR mouse
            // reports as human input, and the dispatch path types them into live
            // sessions. Measured on the fleet: STRANDED 14 -> 5, nine phantom.
            let tick = NightwatchSkillContent.tickPy
            for marker in ["ANSI_RE", "DIM_RE", "MOUSE_RE", "STATUS_RE",
                           #""capture-pane","-p","-e""#,
                           "def _composer(lines, raw_lines=None)",
                           "DIM_RE.search(raw_lines[j])",
                           "if len(raw_lines) != len(lines): raw_lines = None"] {
                #expect(tick.contains(marker), "tick.py lost the ghost-guard: \(marker)")
            }
            // The retired babysitter's log path must not come back with it.
            #expect(!tick.contains("DAEMON_LOG"))
        }

        @Test("handoff.py is shipped and exposes the three relay verbs")
        func handoffShipped() {
            #expect(NightwatchSkillContent.scripts.contains { $0.name == "handoff.py" })
            let py = NightwatchSkillContent.handoffPy
            for flag in ["--check", "--act", "--close-predecessor"] {
                #expect(py.contains(flag), "handoff.py missing \(flag)")
            }
            #expect(py.contains("refusing to close myself"),
                    "handoff.py lost the self-close guard the relay depends on")
        }

        /// The ceiling is the one number in this skill that both prompts quote in
        /// prose, so a change to `DEFAULT_THRESHOLD` that misses the prose leaves
        /// the judge acting on a figure the script disagrees with.
        ///
        /// The literal fixture is also pinned. `handoff.py --selftest` asserted
        /// "over ceiling exits 10" against a hardcoded 250_000, which the raise to
        /// 600k turned into an *under*-ceiling case — the selftest would have kept
        /// passing while testing the opposite of its label, so the fixture is now
        /// derived from `DEFAULT_THRESHOLD` and that derivation is what's checked.
        @Test("The context ceiling is 600k in the script and in every prompt")
        func ceilingIsConsistent() {
            #expect(NightwatchSkillContent.handoffPy.contains("DEFAULT_THRESHOLD = 600_000"),
                    "handoff.py's ceiling moved off 600k")
            #expect(NightwatchSkillContent.handoffPy.contains("over_total = DEFAULT_THRESHOLD + 50_000"),
                    "the selftest's over-ceiling fixture is a literal again; it will rot on the next raise")
            #expect(NightwatchSkillContent.skillMd.contains("~600k tokens"),
                    "SKILL.md quotes a ceiling other than the script's")

            for mode in NightwatchDeskPromptsTests.liveModes {
                for (label, text) in [
                    ("initialPrompt", NightwatchDeskPrompts.initialPrompt(mode: mode, skillDir: "/skill")),
                    ("judgePrompt", NightwatchDeskPrompts.judgePrompt(mode: mode, skillDir: "/skill"))
                ] {
                    #expect(!text.contains("200k"),
                            "\(mode) \(label) still quotes the retired 200k ceiling as current")
                    #expect(text.contains("600k"),
                            "\(mode) \(label) does not state the 600k ceiling")
                }
            }
        }

        /// The never-/closeout standing rule has to hold for the whole shipped
        /// skill, not just the desk prompts. `wake.py --act` dispatches its
        /// composed prompt into a hibernated session with no human in the loop,
        /// so a "Run /closeout now" there is a harvest fired on the human's
        /// behalf — the exact thing the rule forbids, reached by a different
        /// door. Behavioural coverage lives in `wake.py --selftest` (scenario 9,
        /// run by `PluginDirWriterTests.wakePySelftest`); this pins the prose
        /// that documents it, which is what a reader consults.
        @Test("SKILL.md does not advertise an automatic DONE → /closeout")
        func skillMdDoesNotPromiseCloseout() {
            let md = NightwatchSkillContent.skillMd
            #expect(!md.contains("DONE → /closeout"),
                    "SKILL.md still describes wake.py as auto-firing /closeout on DONE")
            #expect(md.contains("NEVER trigger `/closeout`"))
        }

        @Test("wake.py's standing rule forbids /closeout rather than prescribing it")
        func wakePyStandingRuleForbidsCloseout() {
            let py = NightwatchSkillContent.wakePy
            #expect(py.contains("do not run /closeout"),
                    "wake.py's STANDING_RULE no longer carries the prohibition")
            // The composed-prompt invariant itself is asserted executably in
            // wake.py's own selftest, which whitelists the prohibition as the
            // only permitted mention — a blacklist here would trip on that very
            // sentence, as it did three times while writing this suite.
            #expect(py.contains("9/9 classification scenarios passed"),
                    "the selftest scenario pinning the rule was removed")
        }

        @Test("Script names are unique")
        func scriptNamesUnique() {
            let names = NightwatchSkillContent.scripts.map(\.name)
            #expect(Set(names).count == names.count, "duplicate script name would clobber a sibling")
        }
    }

    /// The per-tick nudge is a pointer, not a prompt.
    ///
    /// It is deliberately NOT in `prompts(mode:skillDir:)` above, so the policy
    /// invariants — forbid `/closeout`, state the merge limits, name the relay —
    /// are not asserted on it. That is the point of the split: those rules live in
    /// the file it points at, and re-stating them every tick is the ~5 KB cost
    /// this change exists to remove.
    ///
    /// What must hold instead is that the pointer is *self-sufficient for one
    /// tick*: it carries the mode and act flag (the only per-tick variables) and
    /// an unambiguous absolute path to everything else.
    @Test("The per-tick nudge carries the variables and points at the rest", arguments: liveModes)
    func judgeNudgeIsAPointer(mode: NightwatchMode) {
        let path = "/desk/\(NightwatchDeskPrompts.judgeInstructionsFileName)"
        let nudge = NightwatchDeskPrompts.judgeNudge(mode: mode, instructionsPath: path)

        #expect(nudge.contains(path), "nudge does not name the instructions file it points at")
        #expect(nudge.contains("mode: \(mode.rawValue)"), "nudge does not carry the mode")
        #expect(nudge.contains("act=\(mode == .nightwatch)"), "nudge does not carry the act flag")

        // The whole reason for the split. `judgePrompt` is ~5 KB; if the nudge
        // ever drifts back toward inlining it, this is what notices. The bound is
        // deliberately loose — it catches a wall, not a reworded sentence.
        #expect(nudge.utf8.count < 400,
                "nudge is \(nudge.utf8.count) bytes; it is meant to be one line, not the instructions")

        // Moving the body to a file only saves context if the file is read once
        // per session rather than once per tick. Without this instruction the
        // paste cost simply becomes a Read cost.
        #expect(nudge.contains("Don't re-read"),
                "nudge does not tell the judge to skip re-reading; the saving evaporates into per-tick Reads")
    }

    /// The pointer and the file have to be described the same way in both places,
    /// or the judge is told to read one file and handed another.
    @Test("The initial prompt explains the pointer the judge will receive", arguments: liveModes)
    func initialPromptExplainsTheNudgeProtocol(mode: NightwatchMode) {
        let initial = NightwatchDeskPrompts.initialPrompt(mode: mode, skillDir: "/skill")
        #expect(initial.contains(NightwatchDeskPrompts.judgeInstructionsFileName),
                "initial prompt never names the file the per-tick nudge will point at")
        #expect(initial.contains("ONCE"),
                "initial prompt does not tell the judge to read the instructions once rather than per tick")
    }

    /// Merging is the one action the two shifts differ on (Adam, 2026-07-29:
    /// nightwatch only). Daywatch runs while a human is around, so a loop-perfect
    /// PR is something it *reports*; the unattended shift is the one that acts.
    ///
    /// Both prompts still carry the full qualifying rule — see `mergeRule`'s doc
    /// comment for why — so "daywatch does not merge" cannot be pinned by the
    /// absence of merge vocabulary. It is pinned on the authorization sentence,
    /// which is the only part that differs.
    @Test("Only nightwatch is authorized to act on the merge rule")
    func modeSpecificScope() {
        let day = NightwatchDeskPrompts.judgePrompt(mode: .daywatch, skillDir: "/skill")
        let night = NightwatchDeskPrompts.judgePrompt(mode: .nightwatch, skillDir: "/skill")

        #expect(day.contains("triage only"))
        #expect(day.contains("Merging is a NIGHTWATCH action"),
                "daywatch judge prompt does not withhold the merge authorization")
        #expect(!day.contains("you MAY run `gh pr merge"),
                "daywatch judge prompt authorizes an unattended merge")

        #expect(night.contains("you MAY run `gh pr merge"),
                "nightwatch judge prompt withholds the authorization Adam granted 2026-07-29")
        #expect(!night.contains("act on everything the gate allows"))
        #expect(!night.contains("act on everything the gate approves"))
    }

    @Test("The gate's enqueue precondition is stated, not just implied", arguments: liveModes)
    func gatePreconditionStated(mode: NightwatchMode) {
        let text = NightwatchDeskPrompts.judgePrompt(mode: mode, skillDir: "/skill")
        #expect(text.contains("claude-review = APPROVED"))
        #expect(text.contains("CURRENT SHA") || text.contains("current SHA"))
        #expect(text.contains("Human approval never substitutes"))
    }
}
