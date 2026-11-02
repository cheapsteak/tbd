import ArgumentParser
import Foundation
import Testing
import TBDShared

@testable import TBDCLI

/// The soak switches under `tbd gc` are the only hand-reachable way to turn a
/// process-killing reclaimer on, so what these assert is that the switch is
/// *reachable* — registered on the group under the name a soak participant is
/// told to type, taking the same optional `on | off` positional as its
/// siblings (omitted, it prints the current value). The
/// state word's mapping to a Bool happens inside `run()`, behind a socket call
/// to a live daemon, and is not exercised here.
@Suite("tbd gc soak-switch registration and parsing")
struct GCCommandsTests {
    /// Every GC leg that soaks behind a switch of its own needs a CLI leg, or
    /// "enable it for the soak" means hand-editing `state.db` — which this
    /// project's rules put out of bounds. Named by string so the assertion is
    /// about the typed command, not about which Swift type happens to back it.
    @Test func soakSwitchesAreAllRegisteredOnTheGCGroup() {
        let names = GCCommand.configuration.subcommands.map { $0._commandName }
        #expect(names.contains("orphan-processes"))
        #expect(names.contains("profile-dirs"))
        #expect(names.contains("retained-transcripts"))
    }

    /// The holder legs take no switch of their own: holder-ness is a transport
    /// property, so the rendezvous and row-less sweeps run under `gcEnabled`
    /// and the reaper's holder leg runs unconditionally. A `tbd gc` group that
    /// offered a name for any of them would advertise a gate that does not
    /// exist.
    @Test func theHolderLegsHaveNoSwitchOfTheirOwn() {
        let names = GCCommand.configuration.subcommands.map { $0._commandName }
        #expect(!names.contains("holders"))
        #expect(!names.contains("rowless-holders"))
        #expect(!names.contains("holder-children"))
        #expect(!names.contains("holder-rows"))
    }

    /// The name is a noun phrase naming *what gets reclaimed*, like every
    /// sibling — not a verb phrase naming the act.
    @Test func orphanProcessSwitchIsNamedForWhatItReclaims() {
        #expect(GCOrphanProcesses.configuration.commandName == "orphan-processes")
    }

    @Test func orphanProcessSwitchTakesTheStateWordAsAnOptionalPositional() throws {
        #expect(try GCOrphanProcesses.parse(["on"]).state == "on")
        #expect(try GCOrphanProcesses.parse(["off"]).state == "off")
        // No argument is the read form: a bare `tbd gc orphan-processes`
        // prints the current value and changes nothing.
        #expect(try GCOrphanProcesses.parse([]).state == nil)
    }

    /// The hang-stack reclaimer deletes files rather than killing anything, so
    /// it sits outside the group above — but it needs a leg for the same
    /// reason. `gcEnabled` resolves as `gc_enabled ?? true`, so this phase's
    /// own gate is what buys it a soak at all, and `tbd gc hang-stacks on` is
    /// the only supported way to lift that gate out of NULL.
    @Test func hangStackSwitchIsRegisteredOnTheGCGroup() {
        let names = GCCommand.configuration.subcommands.map { $0._commandName }
        #expect(names.contains("hang-stacks"))
    }

    /// A noun phrase naming what gets reclaimed, like every sibling.
    @Test func hangStackSwitchIsNamedForWhatItReclaims() {
        #expect(GCHangStacks.configuration.commandName == "hang-stacks")
    }

    @Test func hangStackSwitchTakesTheStateWordAsAnOptionalPositional() throws {
        #expect(try GCHangStacks.parse(["on"]).state == "on")
        #expect(try GCHangStacks.parse(["off"]).state == "off")
        #expect(try GCHangStacks.parse([]).state == nil)
    }

    // Discriminates: dropping the registration removes the name.
    @Test func keepListIsRegisteredOnTheGCGroup() {
        let names = GCCommand.configuration.subcommands.map { $0._commandName }
        #expect(names.contains("keep-list"))
    }

    // Discriminates: bare `keep-list` must parse to the report command, `customize` to the writer.
    @Test func keepListWithoutASubcommandIsTheReportAndCustomizeIsTheWriter() throws {
        #expect(try GCKeepListCommand.parseAsRoot([]) is GCKeepListCommand)
        #expect(try GCKeepListCommand.parseAsRoot(["customize"]) is GCKeepListCustomize)
    }

    // Discriminates: asserts path line, shipped-defaults state line, and every pattern indented.
    @Test func reportForShippedDefaults() {
        let lines = GCKeepListCommand.report(path: "/x/gc-keep-processes", loaded: .list(.shipped, .shippedDefaults))
            .components(separatedBy: "\n")
        #expect(lines[0] == "/x/gc-keep-processes")
        #expect(lines[1] == "In effect: shipped defaults (run `tbd gc keep-list customize` to edit them)")
        #expect(Array(lines.dropFirst(2)) == GCKeepList.shippedPatterns.map { "  \($0)" })
    }

    // Discriminates: the file state line differs from the defaults line and lists only the file's patterns.
    @Test func reportForYourFile() {
        let lines = GCKeepListCommand.report(
            path: "/x/f", loaded: .list(GCKeepList(patterns: ["foo", "bar"]), .file))
            .components(separatedBy: "\n")
        #expect(lines == ["/x/f", "In effect: your file", "  foo", "  bar"])
    }

    // Discriminates: an unreadable file prints the reason and the skip consequence, and no pattern lines.
    @Test func reportForUnreadable() {
        let lines = GCKeepListCommand.report(path: "/x/f", loaded: .unreadable(reason: "Permission denied"))
            .components(separatedBy: "\n")
        #expect(lines == ["/x/f",
            "Unreadable (Permission denied): the orphan-process sweep is skipped until it can be read"])
    }

    // Discriminates: the two outcomes print different messages.
    @Test func customizeMessages() {
        #expect(GCKeepListCustomize.message(path: "/x/f", wrote: true) == "Wrote /x/f")
        #expect(GCKeepListCustomize.message(path: "/x/f", wrote: false)
            == "/x/f already exists; TBD never rewrites it.")
    }
}
