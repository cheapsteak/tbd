import ArgumentParser
import Foundation
import Testing

@testable import TBDCLI
@testable import TBDShared

/// Tier 1. `config set` reports what it did, and a report is only worth
/// printing if it is different when the thing done is different.
@Suite("ConfigSet confirmations")
struct ConfigCommandsTests {

    /// The whole message, for every key and both values.
    ///
    /// Asserted as composed output rather than by hunting for a forbidden
    /// phrase: the failure this guards against is a key printing one state's
    /// explanation for both, and any blacklist narrow enough to catch that
    /// would be one more thing to keep in step with the wording.
    @Test func everyKeyAndValueDescribesTheBranchItTook() {
        #expect(ConfigSet.confirmation(key: "auto-archive-on-merge", value: .on)
            == "Set auto-archive-on-merge default to on.")
        #expect(ConfigSet.confirmation(key: "auto-archive-on-merge", value: .off)
            == "Set auto-archive-on-merge default to off.")
        #expect(ConfigSet.confirmation(key: "auto-hibernate-on-merge", value: .on)
            == "Set auto-hibernate-on-merge default to on.")
        #expect(ConfigSet.confirmation(key: "auto-hibernate-on-merge", value: .off)
            == "Set auto-hibernate-on-merge default to off.")
    }

    /// The property behind the pinned strings, stated once so a future key
    /// cannot quietly inherit one state's explanation for both: no key may
    /// produce the same sentence for `on` and for `off`, and each sentence has
    /// to open by naming the value it was actually given.
    @Test func noKeySaysTheSameThingForBothStates() {
        for key in ConfigSet.onOffKeys {
            let on = ConfigSet.confirmation(key: key, value: .on)
            let off = ConfigSet.confirmation(key: key, value: .off)
            #expect(on != off, "\(key) reports the same thing whichever state it was set to")
            #expect(on.hasSuffix(" on.") || on.contains(" to on. "),
                    "\(key) on: \(on)")
            #expect(off.hasSuffix(" off.") || off.contains(" to off. "),
                    "\(key) off: \(off)")
        }
    }

    // MARK: - update-mode: three states, and the key decides the vocabulary

    /// Same property as above, extended to a key whose values are not on/off:
    /// no two modes may produce the same sentence, and each must say what the
    /// daemon will now do rather than only naming the value it was given.
    @Test func everyUpdateModeDescribesWhatTheDaemonWillDo() {
        let sentences = UpdateMode.allCases.map { ConfigSet.confirmation(mode: $0) }
        #expect(Set(sentences).count == UpdateMode.allCases.count,
                "two modes report the same thing: \(sentences)")
        for (mode, sentence) in zip(UpdateMode.allCases, sentences) {
            #expect(sentence.contains("update-mode to \(mode.rawValue)"),
                    "\(mode.rawValue): \(sentence)")
        }
        // The two that act say what they will do; the one that does not says so.
        #expect(ConfigSet.confirmation(mode: .off).contains("will not check"))
        #expect(ConfigSet.confirmation(mode: .check).contains("not install"))
        #expect(ConfigSet.confirmation(mode: .auto).contains("install"))
    }

    /// The key decides which values are accepted. `on` is a fine value for the
    /// merge defaults and a meaningless one for `update-mode`; the rejection
    /// has to say which vocabulary was expected.
    @Test func eachKeyRejectsTheOtherKeysVocabulary() throws {
        #expect(throws: CLIError.self) {
            _ = try ConfigSet.parseUpdateMode("on")
        }
        #expect(throws: CLIError.self) {
            _ = try ConfigSet.parseOnOff("auto", key: "auto-archive-on-merge")
        }
        #expect(try ConfigSet.parseUpdateMode("auto") == .auto)
        #expect(try ConfigSet.parseOnOff("off", key: "auto-archive-on-merge") == .off)
    }

    @Test func rejectionsNameTheValuesTheKeyAccepts() {
        do {
            _ = try ConfigSet.parseUpdateMode("on")
            Issue.record("expected a rejection")
        } catch let error as CLIError {
            #expect(error.description.contains("off, check, auto"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        do {
            _ = try ConfigSet.parseOnOff("auto", key: "auto-hibernate-on-merge")
            Issue.record("expected a rejection")
        } catch let error as CLIError {
            #expect(error.description.contains("auto-hibernate-on-merge"))
            #expect(error.description.contains("on, off"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    /// The unknown-key message lists every key the command knows, so adding a
    /// key cannot leave the help text behind.
    @Test func theUnknownKeyMessageListsEveryKnownKey() {
        let message = ConfigSet.unknownKeyMessage("nonsense")
        for key in ConfigSet.allKeys {
            #expect(message.contains(key), "'\(key)' missing from: \(message)")
        }
    }

    /// `config get` prints the update mode alongside the older keys — the read
    /// half a user checks after setting it.
    @Test func configGetPrintsTheUpdateMode() {
        var config = Config()
        config.updateMode = .check
        let rendered = ConfigGet.render(config)
        #expect(rendered.contains("update-mode: check"))
        #expect(rendered.contains("auto-archive-on-merge: off"))
    }

    // MARK: - pr-poll-schedule: the soak switch for schedule-based PR polling

    @Test func prPollScheduleDescribesBothStates() {
        #expect(ConfigSet.confirmation(key: "pr-poll-schedule", value: .on)
            == "Set pr-poll-schedule to on. TBD checks each pull request as often as its "
            + "status needs, within a GitHub API budget. Takes effect now.")
        #expect(ConfigSet.confirmation(key: "pr-poll-schedule", value: .off)
            == "Set pr-poll-schedule to off. TBD checks every worktree's pull request "
            + "every 30 seconds while the app is in front, and every 5 minutes otherwise. "
            + "Takes effect now.")
    }

    @Test func prPollScheduleIsAnOnOffKey() throws {
        #expect(ConfigSet.onOffKeys.contains("pr-poll-schedule"))
        #expect(try ConfigSet.parseOnOff("on", key: "pr-poll-schedule") == .on)
        #expect(try ConfigSet.parseOnOff("off", key: "pr-poll-schedule") == .off)
        #expect(throws: CLIError.self) {
            _ = try ConfigSet.parseOnOff("auto", key: "pr-poll-schedule")
        }
    }

    @Test func configGetPrintsPRPollScheduleInBothStates() {
        var config = Config()
        #expect(ConfigGet.render(config).contains("pr-poll-schedule: off"))
        config.prPollScheduleEnabled = true
        #expect(ConfigGet.render(config).contains("pr-poll-schedule: on"))
    }

    // MARK: - transcript-prompt-answer: the soak switch for answering prompts from the transcript

    @Test func transcriptPromptAnswerDescribesBothStates() {
        let on = ConfigSet.confirmation(key: "transcript-prompt-answer", value: .on)
        let off = ConfigSet.confirmation(key: "transcript-prompt-answer", value: .off)
        #expect(on.hasPrefix("Set transcript-prompt-answer to on."))
        #expect(off.hasPrefix("Set transcript-prompt-answer to off."))
        #expect(on != off)
    }

    @Test func transcriptPromptAnswerIsAnOnOffKey() throws {
        #expect(ConfigSet.onOffKeys.contains("transcript-prompt-answer"))
        #expect(try ConfigSet.parseOnOff("on", key: "transcript-prompt-answer") == .on)
        #expect(try ConfigSet.parseOnOff("off", key: "transcript-prompt-answer") == .off)
        #expect(throws: CLIError.self) {
            _ = try ConfigSet.parseOnOff("auto", key: "transcript-prompt-answer")
        }
    }

    @Test func configGetPrintsTranscriptPromptAnswerInBothStates() {
        var config = Config()
        #expect(ConfigGet.render(config).contains("transcript-prompt-answer: off"))
        config.transcriptPromptAnswerEnabled = true
        #expect(ConfigGet.render(config).contains("transcript-prompt-answer: on"))
    }

    // MARK: - composer-draft: the soak switch for saving and restoring composer drafts

    @Test func composerDraftDescribesBothStates() {
        let on = ConfigSet.confirmation(key: "composer-draft", value: .on)
        let off = ConfigSet.confirmation(key: "composer-draft", value: .off)
        #expect(on.hasPrefix("Set composer-draft to on."))
        #expect(off.hasPrefix("Set composer-draft to off."))
        #expect(on != off)
    }

    @Test func composerDraftIsAnOnOffKey() throws {
        #expect(ConfigSet.onOffKeys.contains("composer-draft"))
        #expect(try ConfigSet.parseOnOff("on", key: "composer-draft") == .on)
        #expect(try ConfigSet.parseOnOff("off", key: "composer-draft") == .off)
        #expect(throws: CLIError.self) {
            _ = try ConfigSet.parseOnOff("auto", key: "composer-draft")
        }
    }

    @Test func configGetPrintsComposerDraftInBothStates() {
        var config = Config()
        #expect(ConfigGet.render(config).contains("composer-draft: off"))
        config.composerDraftEnabled = true
        #expect(ConfigGet.render(config).contains("composer-draft: on"))
    }

    // MARK: - session-usage: the soak switch for recording session usage

    @Test func sessionUsageDescribesBothStates() {
        let on = ConfigSet.confirmation(key: "session-usage", value: .on)
        let off = ConfigSet.confirmation(key: "session-usage", value: .off)
        #expect(on.hasPrefix("Set session-usage to on."))
        #expect(off.hasPrefix("Set session-usage to off."))
        #expect(on != off)
    }

    @Test func sessionUsageIsAnOnOffKey() throws {
        #expect(ConfigSet.onOffKeys.contains("session-usage"))
        #expect(try ConfigSet.parseOnOff("on", key: "session-usage") == .on)
        #expect(try ConfigSet.parseOnOff("off", key: "session-usage") == .off)
        #expect(throws: CLIError.self) {
            _ = try ConfigSet.parseOnOff("auto", key: "session-usage")
        }
    }

    @Test func configGetPrintsSessionUsageInBothStates() {
        var config = Config()
        #expect(ConfigGet.render(config).contains("session-usage: off"))
        config.sessionModUsageEnabled = true
        #expect(ConfigGet.render(config).contains("session-usage: on"))
    }

    // MARK: - clone-checkout: the soak switch for clone-backed worktree checkout

    @Test func cloneCheckoutDescribesBothStates() {
        #expect(ConfigSet.confirmation(key: "clone-checkout", value: .on)
            == "Set clone-checkout to on. New worktrees are cloned from a per-repo template "
            + "checkout where the volume supports it, so unchanged files share disk blocks. "
            + "Takes effect at the next worktree.")
        #expect(ConfigSet.confirmation(key: "clone-checkout", value: .off)
            == "Set clone-checkout to off. New worktrees write every tracked file with "
            + "git worktree add. Takes effect at the next worktree.")
    }

    @Test func cloneCheckoutIsAnOnOffKey() throws {
        #expect(ConfigSet.onOffKeys.contains("clone-checkout"))
        #expect(try ConfigSet.parseOnOff("on", key: "clone-checkout") == .on)
        #expect(throws: CLIError.self) {
            _ = try ConfigSet.parseOnOff("auto", key: "clone-checkout")
        }
    }

    @Test func configGetPrintsCloneCheckoutInBothStates() {
        var config = Config()
        #expect(ConfigGet.render(config).contains("clone-checkout: off"))
        config.cloneCheckoutEnabled = true
        #expect(ConfigGet.render(config).contains("clone-checkout: on"))
    }

    // MARK: - start-admission and agent-background

    @Test(arguments: ["start-admission", "agent-background"])
    func admissionAndBackgroundAreOnOffKeys(key: String) throws {
        #expect(ConfigSet.onOffKeys.contains(key))
        #expect(ConfigSet.allKeys.contains(key))
        #expect(try ConfigSet.parseOnOff("on", key: key) == .on)
        #expect(try ConfigSet.parseOnOff("off", key: key) == .off)
        #expect(throws: CLIError.self) {
            _ = try ConfigSet.parseOnOff("auto", key: key)
        }
    }

    @Test(arguments: ["start-admission", "agent-background"])
    func admissionAndBackgroundDescribeBothStates(key: String) {
        let on = ConfigSet.confirmation(key: key, value: .on)
        let off = ConfigSet.confirmation(key: key, value: .off)
        #expect(on.hasPrefix("Set \(key) to on."))
        #expect(off.hasPrefix("Set \(key) to off."))
        #expect(on != off)
    }

    @Test func configGetPrintsAdmissionAndBackgroundInBothStates() {
        var config = Config()
        #expect(ConfigGet.render(config).contains("start-admission: off"))
        #expect(ConfigGet.render(config).contains("agent-background: off"))
        config.startAdmissionEnabled = true
        config.agentBackgroundEnabled = true
        #expect(ConfigGet.render(config).contains("start-admission: on"))
        #expect(ConfigGet.render(config).contains("agent-background: on"))
    }

    // MARK: - holder-claim-reconcile: the soak switch for the holder viewer-claim sweep

    @Test func holderClaimReconcileIsAnOnOffKey() throws {
        #expect(ConfigSet.onOffKeys.contains("holder-claim-reconcile"))
        #expect(ConfigSet.allKeys.contains("holder-claim-reconcile"))
        #expect(try ConfigSet.parseOnOff("on", key: "holder-claim-reconcile") == .on)
        #expect(try ConfigSet.parseOnOff("off", key: "holder-claim-reconcile") == .off)
        #expect(throws: CLIError.self) {
            _ = try ConfigSet.parseOnOff("auto", key: "holder-claim-reconcile")
        }
    }

    @Test func holderClaimReconcileDescribesBothStates() {
        let on = ConfigSet.confirmation(key: "holder-claim-reconcile", value: .on)
        let off = ConfigSet.confirmation(key: "holder-claim-reconcile", value: .off)
        #expect(on.hasPrefix("Set holder-claim-reconcile to on."))
        #expect(off.hasPrefix("Set holder-claim-reconcile to off."))
        #expect(on.contains("takes back"))
        #expect(off.contains("only logs"))
        #expect(on != off)
    }

    @Test func configGetPrintsHolderClaimReconcileInBothStates() {
        var config = Config()
        #expect(ConfigGet.render(config).contains("holder-claim-reconcile: off"))
        config.holderClaimReconcileEnabled = true
        #expect(ConfigGet.render(config).contains("holder-claim-reconcile: on"))
    }

    // MARK: - No transport-shaped switch

    /// Hibernation takes one switch — `auto_hibernate_enabled` — for every
    /// transport. A `tbd config holder-hibernation` leg would advertise a
    /// second gate that no rail reads.
    @Test func thereIsNoHolderHibernationSwitch() {
        let names = ConfigCommand.configuration.subcommands.map { $0._commandName }
        #expect(!names.contains("holder-hibernation"))
    }
}
