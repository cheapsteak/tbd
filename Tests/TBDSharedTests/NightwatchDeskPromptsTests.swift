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
/// context-ceiling remedy, and to merge PRs that the nightwatch gate reserves
/// for the human.
///
/// Each expectation below therefore pins a *policy invariant*, not phrasing.
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
            let mentionsCeiling = text.contains("200k") || text.lowercased().contains("context ceiling")
            #expect(mentionsCeiling, "\(mode) \(label) never states the context ceiling")

            #expect(
                text.contains("handoff.py"),
                "\(mode) \(label) raises the context ceiling without naming the handoff relay"
            )
            // No prompt may point at a recycler that does not exist. Asserted on
            // concrete artifacts rather than on phrasing: a blacklist of wordings
            // like "will restart you" is defeated from BOTH sides — a reworded
            // reintroduction slips through, and the sentence that *forbids* the
            // promise trips it, because a prohibition quotes what it prohibits.
            // These names have no innocent reading in a prompt; none of them exist.
            for phantom in ["daemon.py", "watchdog.sh", "~/.fleet", "babysitter_daemon"] {
                #expect(
                    !text.contains(phantom),
                    "\(mode) \(label) points at \(phantom), which was never built"
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

    @Test("No prompt authorizes a merge — the human merges", arguments: liveModes)
    func noMergeAuthorization(mode: NightwatchMode) {
        for (label, text) in prompts(mode: mode, skillDir: "/skill") {
            #expect(
                text.contains("NEVER run `gh pr merge`") || text.contains("never run `gh pr merge`"),
                "\(mode) \(label) does not forbid `gh pr merge`; the SKILL.md gate reserves merging for the human"
            )
            #expect(
                !text.contains("Merge PRs cleared"),
                "\(mode) \(label) authorizes merging cleared PRs, contradicting the gate"
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
        @Test("SKILL.md does not claim a babysitter daemon exists")
        func noBabysitterDaemonClaim() {
            let md = NightwatchSkillContent.skillMd
            for claim in ["durable spine (already on launchd",
                          "These keep the critical safety net running",
                          "`scripts/daemon.py` (babysitter) — auto-approves"] {
                #expect(!md.contains(claim), "SKILL.md still asserts a babysitter daemon: \(claim)")
            }
            #expect(md.contains("There is no babysitter daemon"))
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

    @Test("Daywatch stays triage-only and nightwatch does not widen to merging")
    func modeSpecificScope() {
        let day = NightwatchDeskPrompts.judgePrompt(mode: .daywatch, skillDir: "/skill")
        let night = NightwatchDeskPrompts.judgePrompt(mode: .nightwatch, skillDir: "/skill")

        #expect(day.contains("triage only"))
        // Nightwatch is the wider role, but "wider" must stop before merging.
        #expect(night.contains("the human merges"))
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
