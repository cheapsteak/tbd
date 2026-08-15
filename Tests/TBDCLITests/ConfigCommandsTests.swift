import Foundation
import Testing

@testable import TBDCLI

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
        for key in ["auto-archive-on-merge", "auto-hibernate-on-merge"] {
            let on = ConfigSet.confirmation(key: key, value: .on)
            let off = ConfigSet.confirmation(key: key, value: .off)
            #expect(on != off, "\(key) reports the same thing whichever state it was set to")
            #expect(on.hasSuffix(" on.") || on.contains(" to on. "),
                    "\(key) on: \(on)")
            #expect(off.hasSuffix(" off.") || off.contains(" to off. "),
                    "\(key) off: \(off)")
        }
    }
}
