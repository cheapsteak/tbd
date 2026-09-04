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
}
