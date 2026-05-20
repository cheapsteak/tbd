import AppKit
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

// MARK: - AddTabMenu.build

@MainActor
@Test func addTabMenu_withNoProfiles_hasNoIndentedItems() {
    let menu = AddTabMenu.build(profiles: [], coordinator: makeCoordinator())

    let idx = claudeIndex(menu)
    #expect(menu.items[idx + 1].title == "Codex")
    #expect(menu.items.allSatisfy { $0.indentationLevel == 0 })
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
    #expect(first.indentationLevel == 1)
    #expect(first.representedObject as? UUID == work.profile.id)

    #expect(second.title == "Personal")
    #expect(second.indentationLevel == 1)
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
