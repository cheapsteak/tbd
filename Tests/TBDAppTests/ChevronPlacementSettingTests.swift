import Foundation
import Testing
@testable import TBDApp

/// The chevron-placement setting's storage contract: unset means "never
/// chose", and both explicit values persist as written. Mirrors
/// `ShowScratchSectionSettingTests`, and pins that the shipped default is
/// off — the chevron leads the project name unless a user asks otherwise.
@MainActor
@Suite("chevronAfterProjectName setting")
struct ChevronPlacementSettingTests {
    @Test func defaultsToOff() {
        #expect(AppState.chevronAfterProjectNameDefault == false)
    }

    @Test func storesBothBranches() {
        let suiteName = "chevron-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(defaults.object(forKey: AppState.chevronAfterProjectNameKey) == nil)
        defaults.set(true, forKey: AppState.chevronAfterProjectNameKey)
        #expect(defaults.bool(forKey: AppState.chevronAfterProjectNameKey) == true)
        defaults.set(false, forKey: AppState.chevronAfterProjectNameKey)
        #expect(defaults.bool(forKey: AppState.chevronAfterProjectNameKey) == false)
    }
}

/// Direct proof of the one behavior the two chevron placements disagree
/// about — whether the button is mounted when nothing is hovered. Tests the
/// extracted pure function rather than a live view, the same way
/// `ScratchSectionVisibleTests` does, so an inverted or dropped gate fails
/// here instead of only in the running app.
@MainActor
@Suite("chevronMounted gate")
struct ChevronMountedTests {
    @Test("leading the name: mounted with no pointer in the section")
    func leadingUnhoveredMounted() {
        #expect(RepoSectionView.chevronMounted(afterName: false, hovered: false, menuOpen: false))
    }

    @Test("leading the name: still mounted while hovered")
    func leadingHoveredMounted() {
        #expect(RepoSectionView.chevronMounted(afterName: false, hovered: true, menuOpen: false))
    }

    @Test("trailing the name: hidden with no pointer in the section")
    func trailingUnhoveredHidden() {
        #expect(!RepoSectionView.chevronMounted(afterName: true, hovered: false, menuOpen: false))
    }

    @Test("trailing the name: revealed on hover")
    func trailingHoveredMounted() {
        #expect(RepoSectionView.chevronMounted(afterName: true, hovered: true, menuOpen: false))
    }

    @Test("trailing the name: stays mounted while the + menu is open off-hover")
    func trailingMenuOpenMounted() {
        #expect(RepoSectionView.chevronMounted(afterName: true, hovered: false, menuOpen: true))
    }
}
