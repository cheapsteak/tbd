import ArgumentParser
import Foundation
import Testing

@testable import TBDCLI

/// The soak switches under `tbd gc` are the only hand-reachable way to turn a
/// process-killing reclaimer on, so what these assert is that the switch is
/// *reachable* — registered on the group under the name a soak participant is
/// told to type, taking the same `on | off` positional as its siblings. The
/// state word's mapping to a Bool happens inside `run()`, behind a socket call
/// to a live daemon, and is not exercised here.
@Suite("tbd gc soak-switch registration and parsing")
struct GCCommandsTests {
    /// Every gate that kills something needs a CLI leg, or "enable it for the
    /// soak" means hand-editing `state.db` — which this project's rules put out
    /// of bounds. Named by string so the assertion is about the typed command,
    /// not about which Swift type happens to back it.
    @Test func killingSoakSwitchesAreAllRegisteredOnTheGCGroup() {
        let names = GCCommand.configuration.subcommands.map { $0._commandName }
        #expect(names.contains("orphan-processes"))
        #expect(names.contains("profile-dirs"))
        #expect(names.contains("retained-transcripts"))
    }

    /// The holder legs take no switch of their own: holder-ness is a transport
    /// property, so the rendezvous and row-less sweeps run under `gcEnabled`
    /// and the reaper's holder leg runs unconditionally. A `tbd gc` group that
    /// still offered a name for any of them would advertise a gate that no
    /// longer exists.
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

    @Test func orphanProcessSwitchTakesTheStateWordAsARequiredPositional() throws {
        #expect(try GCOrphanProcesses.parse(["on"]).state == "on")
        #expect(try GCOrphanProcesses.parse(["off"]).state == "off")
        // No argument is not "leave it as it is" — it is a usage error, so a
        // bare `tbd gc orphan-processes` cannot read as a query that silently
        // changed nothing.
        #expect(throws: (any Error).self) { try GCOrphanProcesses.parse([]) }
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

    @Test func hangStackSwitchTakesTheStateWordAsARequiredPositional() throws {
        #expect(try GCHangStacks.parse(["on"]).state == "on")
        #expect(try GCHangStacks.parse(["off"]).state == "off")
        #expect(throws: (any Error).self) { try GCHangStacks.parse([]) }
    }
}
