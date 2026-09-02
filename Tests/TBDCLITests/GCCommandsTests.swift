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
        #expect(names.contains("holder-children"))
        #expect(names.contains("rowless-holders"))
        #expect(names.contains("orphan-processes"))
    }

    /// The name is a noun phrase naming *what gets reclaimed*, like every
    /// sibling (`profile-dirs`, `orphan-processes`, `holders`,
    /// `rowless-holders`) — not a verb phrase naming the act.
    @Test func holderChildrenSwitchIsNamedForWhatItReclaims() {
        #expect(GCHolderChildren.configuration.commandName == "holder-children")
    }

    @Test func holderChildrenSwitchTakesTheStateWordAsARequiredPositional() throws {
        #expect(try GCHolderChildren.parse(["on"]).state == "on")
        #expect(try GCHolderChildren.parse(["off"]).state == "off")
        // No argument is not "leave it as it is" — it is a usage error, so a
        // bare `tbd gc holder-children` cannot read as a query that silently
        // changed nothing.
        #expect(throws: (any Error).self) { try GCHolderChildren.parse([]) }
    }
}
