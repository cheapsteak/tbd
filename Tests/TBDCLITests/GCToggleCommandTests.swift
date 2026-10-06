import ArgumentParser
import Foundation
import Testing
import TBDShared

@testable import TBDCLI

/// The four `tbd gc <collector>` switches: `on | off` sets, and no argument
/// reads the current value back.
@Suite("GC collector switch commands")
struct GCToggleCommandTests {
    @Test func noArgumentParsesAsTheReadForm() throws {
        #expect(try GCOrphanProcesses.parse([]).state == nil)
        #expect(try GCProfileDirs.parse([]).state == nil)
        #expect(try GCRetainedTranscripts.parse([]).state == nil)
        #expect(try GCHangStacks.parse([]).state == nil)
    }

    @Test func anArgumentParsesAsTheSetForm() throws {
        #expect(try GCOrphanProcesses.parse(["on"]).state == "on")
        #expect(try GCHangStacks.parse(["off"]).state == "off")
    }

    @Test func stateParsingAcceptsOnAndOffSpellings() throws {
        for word in ["on", "ON", "true", "enable"] { #expect(try parseGCToggleState(word)) }
        for word in ["off", "Off", "false", "disable"] { #expect(try !parseGCToggleState(word)) }
        #expect(throws: ValidationError.self) { try parseGCToggleState("maybe") }
    }

    @Test func statusLineNamesValueAndShippedDefault() {
        #expect(gcToggleStatusLine(label: "Orphan-process GC", enabled: true, shippedDefault: false)
            == "Orphan-process GC: on (default off)")
        #expect(gcToggleStatusLine(label: "Hang-stack GC", enabled: false, shippedDefault: false)
            == "Hang-stack GC: off (default off)")
    }
}
