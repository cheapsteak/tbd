import Foundation
import Testing
@testable import TBDCLI
import TBDShared

@Suite("tbd link target resolution")
struct LinkCommandTests {
    private let wtA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let wtB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
    private let termA = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000003")!

    private func term(_ id: UUID, in worktree: UUID) -> TBDShared.Terminal {
        TBDShared.Terminal(id: id, worktreeID: worktree, tmuxWindowID: "@1", tmuxPaneID: "%1")
    }

    /// Resolver stub: "a" -> wtA, "b" -> wtB, anything else refuses.
    private func resolve(_ name: String) throws -> UUID {
        switch name {
        case "a": return wtA
        case "b": return wtB
        default: throw CLIError.invalidArgument("No worktree found with name or ID: \(name)")
        }
    }

    private func target(
        worktree: String? = nil,
        terminal: String? = nil,
        this: Bool = false,
        env: [String: String] = [:],
        terminals: [TBDShared.Terminal] = []
    ) throws -> (worktree: UUID, terminal: UUID?) {
        try LinkCommand.resolveTarget(
            worktreeArg: worktree, terminalArg: terminal, thisTerminal: this,
            environment: env, resolveWorktree: resolve, terminals: { terminals }
        )
    }

    private func refusal(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch let CLIError.invalidArgument(msg) { return msg } catch { return "\(error)" }
    }

    @Test func bareLinkUsesWorktreeEnv() throws {
        let t = try target(env: ["TBD_WORKTREE_ID": wtA.uuidString])
        #expect(t.worktree == wtA)
        #expect(t.terminal == nil)
    }

    @Test func bareLinkWithoutEnvRefuses() {
        let msg = refusal { _ = try target() }
        #expect(msg?.contains("not inside a TBD terminal") == true)
    }

    @Test func bareLinkIgnoresTerminalEnv() throws {
        let t = try target(env: ["TBD_WORKTREE_ID": wtA.uuidString, "TBD_TERMINAL_ID": termA.uuidString])
        #expect(t.terminal == nil)
    }

    @Test func worktreeArgIsResolved() throws {
        let t = try target(worktree: "b", env: ["TBD_WORKTREE_ID": wtA.uuidString])
        #expect(t.worktree == wtB)
        #expect(t.terminal == nil)
    }

    @Test func terminalResolvesWorktreeFromList() throws {
        let t = try target(terminal: termA.uuidString, terminals: [term(termA, in: wtB)])
        #expect(t.worktree == wtB)
        #expect(t.terminal == termA)
    }

    @Test func invalidTerminalUUIDRefuses() {
        let msg = refusal { _ = try target(terminal: "nope") }
        #expect(msg?.contains("Invalid terminal ID") == true)
    }

    @Test func unknownTerminalRefuses() {
        let msg = refusal { _ = try target(terminal: termA.uuidString, terminals: [term(UUID(), in: wtA)]) }
        #expect(msg == "No terminal found with ID: \(termA.uuidString)")
    }

    @Test func worktreeTerminalMismatchRefuses() {
        let msg = refusal {
            _ = try target(worktree: "a", terminal: termA.uuidString, terminals: [term(termA, in: wtB)])
        }
        #expect(msg?.contains(termA.uuidString) == true)
        #expect(msg?.contains(wtA.uuidString) == true)
        #expect(msg?.contains(wtB.uuidString) == true)
    }

    @Test func worktreeTerminalMatchWorks() throws {
        let t = try target(worktree: "b", terminal: termA.uuidString, terminals: [term(termA, in: wtB)])
        #expect(t.worktree == wtB)
        #expect(t.terminal == termA)
    }

    @Test func thisTerminalReadsEnv() throws {
        let t = try target(this: true, env: ["TBD_TERMINAL_ID": termA.uuidString], terminals: [term(termA, in: wtA)])
        #expect(t.worktree == wtA)
        #expect(t.terminal == termA)
    }

    @Test func thisTerminalWithoutEnvRefuses() {
        let msg = refusal { _ = try target(this: true, env: ["TBD_WORKTREE_ID": wtA.uuidString]) }
        #expect(msg?.contains("not inside a TBD terminal") == true)
    }

    @Test func terminalAndThisTerminalFailValidation() {
        #expect(throws: (any Error).self) {
            _ = try LinkCommand.parse(["--terminal", termA.uuidString, "--this-terminal"])
        }
    }

    @Test func terminalFlagParses() throws {
        let cmd = try LinkCommand.parse(["--terminal", termA.uuidString, "--https"])
        #expect(cmd.terminal == termA.uuidString)
        #expect(cmd.https)
        #expect(!cmd.thisTerminal)
    }

    @Test func httpsOutputUsesRedirectorAndCarriesTerminal() {
        let s = LinkCommand.render((worktree: wtA, terminal: termA), https: true)
        #expect(s.hasPrefix(DeepLink.redirectorBase))
        #expect(s.contains("terminal=\(termA.uuidString)"))
        #expect(s.contains("worktree=\(wtA.uuidString)"))
    }

    @Test func defaultOutputIsTbdSchemeAndOmitsTerminalWhenNil() {
        let s = LinkCommand.render((worktree: wtA, terminal: nil), https: false)
        #expect(s.hasPrefix("tbd://open?"))
        #expect(!s.contains("terminal="))
    }
}
