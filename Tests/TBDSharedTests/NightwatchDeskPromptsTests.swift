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

    @Test("No prompt tells the session to flag for respawn", arguments: liveModes)
    func noRespawnFlagging(mode: NightwatchMode) {
        // There is no babysitter daemon and no respawner — flagging is a no-op
        // that leaves the session running past its ceiling.
        for (label, text) in prompts(mode: mode, skillDir: "/skill") {
            #expect(
                !text.lowercased().contains("flag for respawn"),
                "\(mode) \(label) tells the session to flag for respawn; nothing respawns it"
            )
            #expect(
                !text.lowercased().contains("daemon respawn"),
                "\(mode) \(label) claims a daemon respawns the desk; no such daemon exists"
            )
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

    @Test("Every prompt carries the never-/closeout standing rule", arguments: liveModes)
    func closeoutForbidden(mode: NightwatchMode) {
        for (label, text) in prompts(mode: mode, skillDir: "/skill") {
            #expect(
                text.contains("/closeout"),
                "\(mode) \(label) omits the never-/closeout rule"
            )
            #expect(
                text.lowercased().contains("archive question for the human"),
                "\(mode) \(label) states the /closeout rule without the reason it exists"
            )
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
