import Foundation
import Testing
import TBDShared

@testable import TBDCLI

@Suite("--profile on the create commands")
struct CreateProfileOptionTests {
    let worktreeID = UUID()
    let terminalID = UUID()

    private var tabEnvironment: [String: String] {
        ["TBD_WORKTREE_ID": worktreeID.uuidString, "TBD_TERMINAL_ID": terminalID.uuidString]
    }

    private func entry(name: String, id: UUID = UUID()) -> ModelProfileWithUsage {
        ModelProfileWithUsage(profile: ModelProfile(id: id, name: name, kind: .oauth))
    }

    private func callerRow(profileID: UUID?, kind: TerminalKind = .claude) -> TBDShared.Terminal {
        TBDShared.Terminal(
            id: terminalID, worktreeID: worktreeID, tmuxWindowID: "@1", tmuxPaneID: "%1",
            profileID: profileID, kind: kind)
    }

    /// Resolves `reference` with the caller's row answered only for this tab's
    /// own worktree and terminal IDs, so a lookup under the wrong IDs reads as
    /// a missing row.
    private func resolve(
        _ reference: String,
        profiles: [ModelProfileWithUsage],
        environment: [String: String],
        row: TBDShared.Terminal?
    ) throws -> CreateProfileChoice {
        try CreateProfileOption.resolve(
            reference,
            profiles: profiles,
            environment: environment,
            callerTerminal: { askedWorktree, askedTerminal in
                askedWorktree == worktreeID && askedTerminal == terminalID ? row : nil
            })
    }

    /// The `CLIError.invalidArgument` text `body` threw, or nil when it did not
    /// throw one.
    private func refusal(_ body: () throws -> CreateProfileChoice) -> String? {
        do {
            _ = try body()
            return nil
        } catch CLIError.invalidArgument(let message) {
            return message
        } catch {
            return "unexpected error: \(error)"
        }
    }

    // MARK: - caller

    @Test func callerResolvesToCallerProfile() throws {
        let workID = UUID()
        let profiles = [entry(name: "acme-work", id: workID), entry(name: "acme-personal")]
        let choice = try resolve(
            "caller", profiles: profiles, environment: tabEnvironment,
            row: callerRow(profileID: workID))
        #expect(choice == CreateProfileChoice(id: workID, name: "acme-work"))
    }

    @Test(arguments: ["caller", "Caller", "CALLER"])
    func callerKeywordIsCaseInsensitive(reference: String) throws {
        let workID = UUID()
        let choice = try resolve(
            reference, profiles: [entry(name: "acme-work", id: workID)],
            environment: tabEnvironment, row: callerRow(profileID: workID))
        #expect(choice.id == workID)
    }

    /// Either variable missing, or not a UUID, means the CLI is not running in
    /// a TBD tab; the caller's row is never asked for.
    @Test(arguments: [
        [String: String](),
        ["TBD_WORKTREE_ID": "2D5B06CC-4930-445D-B562-7BF7C1706418"],
        ["TBD_TERMINAL_ID": "2D5B06CC-4930-445D-B562-7BF7C1706418"],
        ["TBD_WORKTREE_ID": "not-a-uuid", "TBD_TERMINAL_ID": "2D5B06CC-4930-445D-B562-7BF7C1706418"],
    ])
    func callerOutsideTabRefused(environment: [String: String]) {
        let message = refusal {
            try CreateProfileOption.resolve(
                "caller", profiles: [entry(name: "acme-work")], environment: environment,
                callerTerminal: { _, _ in
                    Issue.record("the caller's row was read outside a TBD tab")
                    return nil
                })
        }
        #expect(message == "--profile caller works only inside a TBD tab. "
            + "Name a profile, or leave out --profile.")
    }

    @Test func callerTabWithoutProfileRefused() {
        let message = refusal {
            try resolve(
                "caller", profiles: [entry(name: "acme-work")], environment: tabEnvironment,
                row: callerRow(profileID: nil))
        }
        #expect(message == "This tab runs on the machine's own login, not a TBD profile, "
            + "so --profile caller has nothing to copy. Name a profile, or leave out --profile.")
    }

    /// The worktree has no tab with the caller's ID: the same refusal as a tab
    /// with no profile.
    @Test func callerRowMissingRefused() {
        let message = refusal {
            try resolve(
                "caller", profiles: [entry(name: "acme-work")], environment: tabEnvironment,
                row: nil)
        }
        #expect(message == CreateProfileOption.callerWithoutProfileMessage)
    }

    @Test func callerCodexTabRefused() {
        let message = refusal {
            try resolve(
                "caller", profiles: [entry(name: "acme-work")], environment: tabEnvironment,
                row: callerRow(profileID: nil, kind: .codex))
        }
        #expect(message == "This tab runs Codex, which has no profile, so --profile caller "
            + "has nothing to copy. Name a profile, or leave out --profile.")
    }

    /// A Codex tab is refused by its kind, even when its row carries a profile.
    @Test func callerCodexTabWithAProfileRefused() {
        let workID = UUID()
        let message = refusal {
            try resolve(
                "caller", profiles: [entry(name: "acme-work", id: workID)],
                environment: tabEnvironment, row: callerRow(profileID: workID, kind: .codex))
        }
        #expect(message == CreateProfileOption.callerRunsCodexMessage)
    }

    /// A caller profile deleted since the tab started is sent by ID, for the
    /// daemon to refuse as missing.
    @Test func callerProfileMissingFromListPassesItsID() throws {
        let goneID = UUID()
        let choice = try resolve(
            "caller", profiles: [entry(name: "acme-work")], environment: tabEnvironment,
            row: callerRow(profileID: goneID))
        #expect(choice == CreateProfileChoice(id: goneID, name: goneID.uuidString))
    }

    // MARK: - Names

    /// The keyword comes before any name, so a profile named `caller` is
    /// reachable by its UUID only.
    @Test func profileNamedCallerReachableByUUID() throws {
        let namedCallerID = UUID()
        let profiles = [entry(name: "caller", id: namedCallerID), entry(name: "acme-work")]

        let byID = try resolve(
            namedCallerID.uuidString, profiles: profiles, environment: [:], row: nil)
        #expect(byID == CreateProfileChoice(id: namedCallerID, name: "caller"))

        let byName = refusal {
            try resolve("caller", profiles: profiles, environment: [:], row: nil)
        }
        #expect(byName == CreateProfileOption.callerOutsideTabMessage)
    }

    @Test func nameGoesThroughTheSharedLookup() throws {
        let workID = UUID()
        let profiles = [entry(name: "acme\u{200D}work", id: workID), entry(name: "acme-personal")]
        let choice = try resolve("ACMEWORK", profiles: profiles, environment: [:], row: nil)
        #expect(choice == CreateProfileChoice(id: workID, name: "acme\u{200D}work"))
    }

    @Test func unknownNameRefusedWithTheNames() {
        let message = refusal {
            try resolve(
                "acme-other", profiles: [entry(name: "acme-work"), entry(name: "acme-personal")],
                environment: tabEnvironment, row: nil)
        }
        #expect(message == "No profile named 'acme-other'. Available: acme-personal, acme-work")
    }
}
