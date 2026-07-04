import AppKit
import Darwin
import Foundation
import Testing
@testable import TBDApp
import TBDShared

// MARK: - Helpers

private func makeProfile(
    name: String,
    kind: CredentialKind = .oauth,
    loginIdentity: String? = nil,
    usageSnapshot: ProfileUsageSnapshot? = nil
) -> ModelProfileWithUsage {
    ModelProfileWithUsage(
        profile: ModelProfile(id: UUID(), name: name, kind: kind),
        usage: nil,
        loginIdentity: loginIdentity,
        usageSnapshot: usageSnapshot
    )
}

private func makeCoordinator(
    onClaudeProfile: @escaping (UUID) -> Void = { _ in },
    onChooseAccount: @escaping () -> Void = {}
) -> MenuCoordinator {
    MenuCoordinator(
        onShell: {},
        onClaude: {},
        onClaudeProfile: onClaudeProfile,
        onChooseAccount: onChooseAccount,
        onCodex: {},
        onNote: {}
    )
}

/// Index of the menu item titled "Claude".
private func claudeIndex(_ menu: NSMenu) -> Int {
    menu.items.firstIndex { $0.title == "Claude" }!
}

private func makeExecutable(named name: String, in directory: URL) throws {
    let url = directory.appendingPathComponent(name)
    FileManager.default.createFile(atPath: url.path, contents: Data("#!/bin/sh\nexit 0\n".utf8))
    try #require(chmod(url.path, S_IRWXU) == 0)
}

// MARK: - AddTabMenu.build

@Test func agentExecutableAvailability_detectsExecutablesOnProvidedPath() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tbd-agent-path-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try makeExecutable(named: "claude", in: directory)

    let availability = AgentExecutableAvailability.detect(path: directory.path, homeDir: "/not-a-real-home")

    #expect(availability.claude)
}

@Test func agentExecutableAvailability_detectsHomeLocalBinFallback() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("tbd-agent-home-\(UUID().uuidString)", isDirectory: true)
    let localBin = home.appendingPathComponent(".local/bin", isDirectory: true)
    try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    try makeExecutable(named: "codex", in: localBin)

    let availability = AgentExecutableAvailability.detect(path: nil, homeDir: home.path)

    #expect(availability.claude == false)
    #expect(availability.codex)
}

@MainActor
@Test func addTabMenu_withNoProfiles_insertsNoProfileItems() {
    let menu = AddTabMenu.build(profiles: [], coordinator: makeCoordinator())

    let idx = claudeIndex(menu)
    // "Choose account…" always follows the (empty) profile block.
    #expect(menu.items[idx + 1].title == "Choose account…")
    #expect(menu.items[idx + 2].title == "Codex")
    #expect(menu.items.allSatisfy { $0.indentationLevel == 0 })
}

@MainActor
@Test func addTabMenu_whenClaudeUnavailable_omitsClaudeAndProfiles() {
    let work = makeProfile(name: "Work")
    let menu = AddTabMenu.build(
        profiles: [work],
        availability: AgentExecutableAvailability(claude: false, codex: true),
        coordinator: makeCoordinator()
    )

    #expect(menu.items.contains { $0.title == "Shell" })
    #expect(menu.items.contains { $0.title == "Claude" } == false)
    #expect(menu.items.contains { $0.title.hasPrefix("Work") } == false)
    #expect(menu.items.contains { $0.title == "Codex" })
    #expect(menu.items.contains { $0.title == "Note" })
}

@MainActor
@Test func addTabMenu_whenCodexUnavailable_omitsOnlyCodex() {
    let work = makeProfile(name: "Work")
    let menu = AddTabMenu.build(
        profiles: [work],
        availability: AgentExecutableAvailability(claude: true, codex: false),
        coordinator: makeCoordinator()
    )

    #expect(menu.items.contains { $0.title == "Shell" })
    #expect(menu.items.contains { $0.title == "Claude" })
    #expect(menu.items.contains { $0.title.hasPrefix("Work") })
    #expect(menu.items.contains { $0.title == "Codex" } == false)
    #expect(menu.items.contains { $0.title == "Note" })
}

@MainActor
@Test func addTabMenu_withProfiles_insertsIndentedItemsAfterClaude() {
    // One logged-in oauth profile, one not — the titles carry the identity suffix.
    let work = makeProfile(name: "Work", loginIdentity: "zadam@longeye.co")
    let personal = makeProfile(name: "Personal")
    let menu = AddTabMenu.build(profiles: [work, personal], coordinator: makeCoordinator())

    let idx = claudeIndex(menu)
    let first = menu.items[idx + 1]
    let second = menu.items[idx + 2]

    #expect(first.title == "Work — zadam@longeye.co")
    #expect(first.indentationLevel == 0)
    #expect(first.image != nil)
    #expect(first.representedObject as? UUID == work.profile.id)

    #expect(second.title == "Personal — needs /login")
    #expect(second.indentationLevel == 0)
    #expect(second.image != nil)
    #expect(second.representedObject as? UUID == personal.profile.id)

    #expect(menu.items[idx + 3].title == "Choose account…")
    #expect(menu.items[idx + 4].title == "Codex")
}

@MainActor
@Test func addTabMenu_profileItemTitles_reflectLoginIdentityPerKind() {
    // oauth + email → suffixed with the email; oauth + nil → "needs /login";
    // non-oauth kinds → bare name regardless of any stray identity.
    let loggedIn = makeProfile(name: "Work", loginIdentity: "a@b.co")
    let needsLogin = makeProfile(name: "Spare")
    let proxy = makeProfile(name: "Router", kind: .apiKey)
    let menu = AddTabMenu.build(
        profiles: [loggedIn, needsLogin, proxy],
        coordinator: makeCoordinator()
    )

    let idx = claudeIndex(menu)
    #expect(menu.items[idx + 1].title == "Work — a@b.co")
    #expect(menu.items[idx + 2].title == "Spare — needs /login")
    #expect(menu.items[idx + 3].title == "Router")
}

@MainActor
@Test func addTabMenu_nonProfileItems_keepCorrectWiring() {
    // Hold a strong reference: NSMenuItem.target is weak.
    let coordinator = makeCoordinator()
    let menu = AddTabMenu.build(profiles: [], coordinator: coordinator)

    func item(_ title: String) -> NSMenuItem {
        menu.items.first { $0.title == title }!
    }

    let shell = item("Shell")
    #expect(shell.action == #selector(MenuCoordinator.addShell))
    #expect(shell.target as? MenuCoordinator === coordinator)

    #expect(item("Claude").action == #selector(MenuCoordinator.addClaude))
    #expect(item("Codex").action == #selector(MenuCoordinator.addCodex))
    #expect(item("Note").action == #selector(MenuCoordinator.addNote))
}

@MainActor
@Test func addTabMenu_profileItems_useAddClaudeProfileSelector() {
    let work = makeProfile(name: "Work")
    let menu = AddTabMenu.build(profiles: [work], coordinator: makeCoordinator())

    let item = menu.items[claudeIndex(menu) + 1]
    #expect(item.action == #selector(MenuCoordinator.addClaudeProfile(_:)))
}

@MainActor
@Test func addTabMenu_profileItemTitles_carryCompactUsageSuffix() {
    // A profile with a usage snapshot gets the compact suffix; one without
    // keeps its plain identity title. (No resetsAt in the fixture so the
    // expected string is timezone-independent.)
    let snapshot = ProfileUsageSnapshot(
        buckets: [
            ClaudeUsageLimitBucket(kind: "session", percent: 0, severity: "normal"),
            ClaudeUsageLimitBucket(kind: "weekly_all", percent: 76, severity: "warning"),
            ClaudeUsageLimitBucket(kind: "weekly_scoped", percent: 100,
                                   severity: "critical", modelDisplayName: "Fable"),
        ],
        fetchedAt: Date(), lastAttemptAt: Date(), status: "ok"
    )
    let gmail = makeProfile(name: "Gmail", loginIdentity: "g@x.co", usageSnapshot: snapshot)
    let bare = makeProfile(name: "Work", loginIdentity: "a@b.co")
    let menu = AddTabMenu.build(profiles: [gmail, bare], coordinator: makeCoordinator())

    let idx = claudeIndex(menu)
    #expect(menu.items[idx + 1].title == "Gmail — g@x.co · 5h 0% · wk 76% · F 100%")
    #expect(menu.items[idx + 2].title == "Work — a@b.co")
}

@MainActor
@Test func addTabMenu_whenClaudeUnavailable_omitsChooseAccount() {
    let menu = AddTabMenu.build(
        profiles: [makeProfile(name: "Work")],
        availability: AgentExecutableAvailability(claude: false, codex: true),
        coordinator: makeCoordinator()
    )
    #expect(menu.items.contains { $0.title == "Choose account…" } == false)
}

@MainActor
@Test func addTabMenu_chooseAccountItem_isWiredToCoordinator() {
    let coordinator = makeCoordinator()
    let menu = AddTabMenu.build(profiles: [], coordinator: coordinator)

    let item = menu.items.first { $0.title == "Choose account…" }!
    #expect(item.action == #selector(MenuCoordinator.chooseAccount))
    #expect(item.target as? MenuCoordinator === coordinator)
    #expect(item.image != nil)   // blank icon keeps title-column alignment
}

@MainActor
@Test func menuCoordinator_chooseAccount_forwardsToClosure() {
    var called = false
    let coordinator = makeCoordinator(onChooseAccount: { called = true })
    coordinator.chooseAccount()
    #expect(called)
}

// MARK: - MenuCoordinator.addClaudeProfile

@MainActor
@Test func menuCoordinator_addClaudeProfile_forwardsRepresentedObjectUUID() {
    var received: UUID?
    let coordinator = makeCoordinator { received = $0 }

    let profileID = UUID()
    let item = NSMenuItem()
    item.representedObject = profileID
    coordinator.addClaudeProfile(item)

    #expect(received == profileID)
}

@MainActor
@Test func menuCoordinator_addClaudeProfile_withNilRepresentedObject_isNoOp() {
    var called = false
    let coordinator = makeCoordinator { _ in called = true }

    coordinator.addClaudeProfile(NSMenuItem())

    #expect(called == false)
}
