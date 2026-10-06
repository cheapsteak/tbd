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

    /// Each read path reads its own `Config` field: flip one field at a time
    /// and only that command's line changes.
    @Test func eachReadPathReadsItsOwnConfigField() {
        func onOff(_ value: Bool) -> String { value ? "on" : "off" }
        var base = Config()
        base.gcOrphanProcessesEnabled = false
        base.gcProfileDirsEnabled = false
        base.gcRetainedTranscriptsEnabled = false
        base.gcHangStacksEnabled = false
        #expect(GCOrphanProcesses.statusLine(base)
            == "Orphan-process GC: off (default \(onOff(Config.gcOrphanProcessesEnabledDefault)))")
        #expect(GCProfileDirs.statusLine(base)
            == "Profile-dir GC: off (default \(onOff(Config.gcProfileDirsEnabledDefault)))")
        #expect(GCRetainedTranscripts.statusLine(base)
            == "Retained-transcript GC: off (default \(onOff(Config.gcRetainedTranscriptsEnabledDefault)))")
        #expect(GCHangStacks.statusLine(base)
            == "Hang-stack GC: off (default \(onOff(Config.gcHangStacksEnabledDefault)))")

        var config = base
        config.gcOrphanProcessesEnabled = true
        #expect(GCOrphanProcesses.statusLine(config).hasPrefix("Orphan-process GC: on"))
        #expect(GCProfileDirs.statusLine(config).hasPrefix("Profile-dir GC: off"))

        config = base
        config.gcProfileDirsEnabled = true
        #expect(GCProfileDirs.statusLine(config).hasPrefix("Profile-dir GC: on"))
        #expect(GCOrphanProcesses.statusLine(config).hasPrefix("Orphan-process GC: off"))

        config = base
        config.gcRetainedTranscriptsEnabled = true
        #expect(GCRetainedTranscripts.statusLine(config).hasPrefix("Retained-transcript GC: on"))
        #expect(GCHangStacks.statusLine(config).hasPrefix("Hang-stack GC: off"))

        config = base
        config.gcHangStacksEnabled = true
        #expect(GCHangStacks.statusLine(config).hasPrefix("Hang-stack GC: on"))
        #expect(GCRetainedTranscripts.statusLine(config).hasPrefix("Retained-transcript GC: off"))
    }
}
