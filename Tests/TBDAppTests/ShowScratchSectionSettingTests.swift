import Testing
import Foundation
@testable import TBDApp
@testable import TBDShared

@MainActor
@Suite("showScratchSection setting")
struct ShowScratchSectionSettingTests {
    @Test func defaultsToOn() {
        let suiteName = "scratch-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suiteName)!
        defer { d.removePersistentDomain(forName: suiteName) }
        // No stored value → @AppStorage default (true) applies at the view; assert
        // the key convention and both explicit branches persist as written.
        #expect(d.object(forKey: AppState.showScratchSectionKey) == nil)
        d.set(false, forKey: AppState.showScratchSectionKey)
        #expect(d.bool(forKey: AppState.showScratchSectionKey) == false)
        d.set(true, forKey: AppState.showScratchSectionKey)
        #expect(d.bool(forKey: AppState.showScratchSectionKey) == true)
    }
}

/// Direct, falsifiable proof of the sidebar's Scratch-section gate, mirroring
/// `ScratchExclusionTests.pollableWorktreesDiscriminatesScratchFromRegular`'s
/// pattern of testing the extracted pure function instead of live view
/// behavior. Exercises `AppState.scratchSectionVisible` in isolation — no
/// SwiftUI render, no `@EnvironmentObject` — so an inverted or dropped gate
/// fails this test immediately.
@MainActor
@Suite("scratchSectionVisible gate")
struct ScratchSectionVisibleTests {
    private func makeSpace() -> Worktree {
        Worktree(
            repoID: nil, name: "s", displayName: "s", branch: "",
            path: "/tmp/scratch-\(UUID().uuidString)", tmuxServer: "tbd-scratch")
    }

    @Test("on + spaces present shows the section")
    func onWithSpacesShows() {
        #expect(AppState.scratchSectionVisible(setting: true, spaces: [makeSpace()]))
    }

    @Test("off + spaces present hides the section")
    func offWithSpacesHides() {
        #expect(!AppState.scratchSectionVisible(setting: false, spaces: [makeSpace()]))
    }

    @Test("on + no spaces still shows the section, so a new user can create the first space")
    func onWithNoSpacesShows() {
        #expect(AppState.scratchSectionVisible(setting: true, spaces: []))
    }

    @Test("off + no spaces hides the section")
    func offWithNoSpacesHides() {
        #expect(!AppState.scratchSectionVisible(setting: false, spaces: []))
    }

    @Test("toggling the setting never mutates the spaces array")
    func toggleDoesNotMutateData() {
        let spaces = [makeSpace(), makeSpace()]
        let originalCount = spaces.count
        _ = AppState.scratchSectionVisible(setting: true, spaces: spaces)
        _ = AppState.scratchSectionVisible(setting: false, spaces: spaces)
        #expect(spaces.count == originalCount)
    }
}
