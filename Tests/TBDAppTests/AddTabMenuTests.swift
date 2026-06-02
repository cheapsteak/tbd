import AppKit
import Darwin
import Foundation
import Testing
@testable import TBDApp
import TBDShared

// MARK: - Helpers

private func makeProfile(name: String) -> ModelProfileWithUsage {
    ModelProfileWithUsage(
        profile: ModelProfile(id: UUID(), name: name, kind: .oauth),
        usage: nil
    )
}

private func makeCoordinator(
    onClaudeProfile: @escaping (UUID) -> Void = { _ in }
) -> MenuCoordinator {
    MenuCoordinator(
        onShell: {},
        onClaude: {},
        onClaudeProfile: onClaudeProfile,
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
    #expect(menu.items[idx + 1].title == "Codex")
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
    #expect(menu.items.contains { $0.title == "Work" } == false)
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
    #expect(menu.items.contains { $0.title == "Work" })
    #expect(menu.items.contains { $0.title == "Codex" } == false)
    #expect(menu.items.contains { $0.title == "Note" })
}

@MainActor
@Test func addTabMenu_withProfiles_insertsIndentedItemsAfterClaude() {
    let work = makeProfile(name: "Work")
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

    #expect(menu.items[idx + 3].title == "Codex")
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
