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
        onCodex: {}
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

@Test func agentExecutableAvailability_detectsVoltaBinFallback() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("tbd-agent-home-\(UUID().uuidString)", isDirectory: true)
    let voltaBin = home.appendingPathComponent(".volta/bin", isDirectory: true)
    try FileManager.default.createDirectory(at: voltaBin, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    try makeExecutable(named: "codex", in: voltaBin)

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
}

/// A note is made as a worktree panel — from the side strip's + menu, or by
/// the Notes button in a worktree with no note — never from the workspace tab
/// bar's + menu, which offers terminals alone, whatever is installed.
@MainActor
@Test func workspacePlusMenuHasNoNoteItem() {
    let availabilities: [AgentExecutableAvailability] = [
        .allAvailable,
        AgentExecutableAvailability(claude: false, codex: false),
    ]
    for availability in availabilities {
        let menu = AddTabMenu.build(
            profiles: [makeProfile(name: "Work")],
            availability: availability,
            coordinator: makeCoordinator()
        )
        #expect(menu.items.contains { $0.title.contains("Note") } == false, "\(availability)")
        #expect(menu.items.contains { $0.isSeparatorItem } == false,
                "no separator is left over at the end of the menu: \(availability)")
        #expect(menu.items.first?.title == "Shell")
    }
}

@MainActor
@Test func addTabMenu_withProfiles_insertsIndentedItemsAfterClaude() {
    // One logged-in oauth profile, one not — each title is the name alone.
    let work = makeProfile(name: "Work", loginIdentity: "dev@acme.example")
    let personal = makeProfile(name: "Personal")
    let menu = AddTabMenu.build(profiles: [work, personal], coordinator: makeCoordinator())

    let idx = claudeIndex(menu)
    let first = menu.items[idx + 1]
    let second = menu.items[idx + 2]

    #expect(first.title == "Work")
    #expect(first.indentationLevel == 0)
    #expect(first.image != nil)
    #expect(first.representedObject as? UUID == work.profile.id)

    #expect(second.title == "Personal")
    #expect(second.indentationLevel == 0)
    #expect(second.image != nil)
    #expect(second.representedObject as? UUID == personal.profile.id)

    #expect(menu.items[idx + 3].title == "Choose account…")
    #expect(menu.items[idx + 4].title == "Codex")
}

@MainActor
@Test func addTabMenu_profileItemTitles_areTheNameAloneForEveryKind() {
    // oauth + email, oauth + nil and a non-oauth kind with a stray identity:
    // each plain title is the bare name. The email and the login hint live
    // elsewhere (the tooltip and the note column).
    let loggedIn = makeProfile(name: "Work", loginIdentity: "a@acme.example")
    let needsLogin = makeProfile(name: "Spare")
    let proxy = makeProfile(name: "Router", kind: .apiKey, loginIdentity: "x@acme.example")
    let menu = AddTabMenu.build(
        profiles: [loggedIn, needsLogin, proxy],
        coordinator: makeCoordinator()
    )

    let idx = claudeIndex(menu)
    #expect(menu.items[idx + 1].title == "Work")
    #expect(menu.items[idx + 2].title == "Spare")
    #expect(menu.items[idx + 3].title == "Router")
    #expect(menu.items[idx + 1].toolTip == "a@acme.example")
    #expect(menu.items[idx + 3].toolTip == nil)
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
}

@MainActor
@Test func addTabMenu_profileItems_useAddClaudeProfileSelector() {
    let work = makeProfile(name: "Work")
    let menu = AddTabMenu.build(profiles: [work], coordinator: makeCoordinator())

    let item = menu.items[claudeIndex(menu) + 1]
    #expect(item.action == #selector(MenuCoordinator.addClaudeProfile(_:)))
}

/// A healthy, just-fetched snapshot with both windows. No reset times, so
/// nothing depends on the time zone.
private func healthySnapshot() -> ProfileUsageSnapshot {
    ProfileUsageSnapshot(
        buckets: [
            ClaudeUsageLimitBucket(kind: "session", percent: 40, severity: "normal"),
            ClaudeUsageLimitBucket(kind: "weekly_all", percent: 16, severity: "normal"),
        ],
        fetchedAt: Date(), lastAttemptAt: Date(), status: "ok"
    )
}

/// Every attachment in a title, in order. Each takes one character.
private func attachments(_ title: NSAttributedString?) -> [NSTextAttachment] {
    guard let title else { return [] }
    var found: [NSTextAttachment] = []
    for index in 0..<title.length {
        if let attachment = title.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment {
            found.append(attachment)
        }
    }
    return found
}

@MainActor
@Test func profileRowsAreOneLineWithBars() {
    // A profile with usage draws its bars after the name, on the same line.
    // The plain title is the name alone; the login email is not on the row.
    let gmail = makeProfile(name: "Gmail", loginIdentity: "g@acme.example", usageSnapshot: healthySnapshot())
    let bare = makeProfile(name: "Work", loginIdentity: "a@acme.example")
    let menu = AddTabMenu.build(profiles: [gmail, bare], coordinator: makeCoordinator())

    let idx = claudeIndex(menu)
    let gmailItem = menu.items[idx + 1]
    #expect(gmailItem.title == "Gmail")
    let flattened = gmailItem.attributedTitle?.string ?? ""
    #expect(flattened.hasPrefix("Gmail"))
    #expect(flattened.contains("—") == false)
    #expect(flattened.contains("acme.example") == false)
    #expect(flattened.contains("\n") == false)
    let barsSizes = attachments(gmailItem.attributedTitle).compactMap { $0.image?.size }
    #expect(barsSizes.contains(NSSize(width: 200, height: 13)))

    // A profile with no usage keeps its plain title and no attributed one.
    let bareItem = menu.items[idx + 2]
    #expect(bareItem.title == "Work")
    #expect(bareItem.attributedTitle == nil)
}

@MainActor
@Test func profileRowToolTipLeadsWithTheLoginEmail() throws {
    let gmail = makeProfile(name: "Gmail", loginIdentity: "g@acme.example", usageSnapshot: healthySnapshot())
    let bare = makeProfile(name: "Work", loginIdentity: " a@acme.example ")
    let menu = AddTabMenu.build(profiles: [gmail, bare], coordinator: makeCoordinator())

    let idx = claudeIndex(menu)
    // With bars: the email on the first line, the usage on the next.
    let gmailToolTip = try #require(menu.items[idx + 1].toolTip)
    let lines = gmailToolTip.components(separatedBy: "\n")
    #expect(lines.count == 2)
    #expect(lines.first == "g@acme.example")
    #expect(lines.last?.hasPrefix("5-hour: 40% used") == true)

    // With no usage: the trimmed email alone.
    #expect(menu.items[idx + 2].toolTip == "a@acme.example")
}

@MainActor
@Test func notLoggedInOAuthRowShowsTheNeedsLoginNote() throws {
    // No login and no usage: the name alone, then "needs /login" in the
    // column where the bars go. No email, so no tooltip.
    let spare = makeProfile(name: "Spare")
    let menu = AddTabMenu.build(profiles: [spare], coordinator: makeCoordinator())

    let item = menu.items[claudeIndex(menu) + 1]
    #expect(item.title == "Spare")
    let drawn = try #require(item.attributedTitle)
    #expect(drawn.string.hasPrefix("Spare"))
    #expect(drawn.string.hasSuffix("needs /login"))
    #expect(drawn.string.contains("—") == false)
    #expect(item.toolTip == nil)
}

@MainActor
@Test func notLoggedInOAuthRowWithUsageKeepsTheBarsAndTheNeedsLoginNote() throws {
    // No login, but a healthy snapshot from before the login went away is
    // still cached: the bars stay, and "needs /login" is the grey note after
    // them.
    let spare = makeProfile(name: "Spare", usageSnapshot: healthySnapshot())
    let menu = AddTabMenu.build(profiles: [spare], coordinator: makeCoordinator())

    let item = menu.items[claudeIndex(menu) + 1]
    #expect(item.title == "Spare")
    let drawn = try #require(item.attributedTitle)
    #expect(drawn.string.hasPrefix("Spare"))
    #expect(drawn.string.hasSuffix("needs /login"))
    let barsSizes = attachments(drawn).compactMap { $0.image?.size }
    #expect(barsSizes.contains(NSSize(width: 200, height: 13)))
    // No email, so the tooltip is the reset times alone.
    #expect(item.toolTip?.hasPrefix("5-hour: 40% used") == true)
}

@MainActor
@Test func nonOAuthRowToolTipHasNoIdentityLine() throws {
    // A stray identity on a key profile never reaches the menu.
    let key = makeProfile(name: "Key", kind: .apiKey, loginIdentity: "x@acme.example",
                          usageSnapshot: healthySnapshot())
    let menu = AddTabMenu.build(profiles: [key], coordinator: makeCoordinator())

    let item = menu.items[claudeIndex(menu) + 1]
    #expect(item.title == "Key")
    let toolTip = try #require(item.toolTip)
    #expect(toolTip.contains("\n") == false)
    #expect(toolTip.contains("acme.example") == false)
    #expect(toolTip.hasPrefix("5-hour: 40% used"))
}

@MainActor
@Test func profileRowsKeepTheBlankIndentIcon() throws {
    // The blank icon, the Claude asterisk's size, is what indents the account
    // rows under "Claude", with usage or without.
    let gmail = makeProfile(name: "Gmail", loginIdentity: "g@x.co", usageSnapshot: healthySnapshot())
    let bare = makeProfile(name: "Work", loginIdentity: "a@b.co")
    let menu = AddTabMenu.build(profiles: [gmail, bare], coordinator: makeCoordinator())

    let idx = claudeIndex(menu)
    let claudeIconSize = try #require(menu.items[idx].image?.size)
    for item in menu.items[(idx + 1)...(idx + 2)] {
        #expect(item.image?.size == claudeIconSize, "\(item.title)")
    }
    #expect(menu.items[idx + 3].title == "Choose account…")
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
