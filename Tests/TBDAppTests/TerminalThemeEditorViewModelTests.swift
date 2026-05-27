import Foundation
import Testing
@testable import TBDApp

@MainActor
@Suite("TerminalThemeEditorViewModel")
struct TerminalThemeEditorViewModelTests {

    private func bundledSource() -> TerminalColorScheme { ColorSchemes.scheme(forID: "gruvbox-dark") }

    @Test("starts not-dirty for a freshly loaded source")
    func notDirtyAtStart() {
        let vm = TerminalThemeEditorViewModel()
        vm.load(source: bundledSource(), kind: .bundled)
        #expect(!vm.isDirty)
        #expect(vm.canSave == false)
        #expect(vm.canSaveAs == true)
        #expect(vm.canReset == false)
    }

    @Test("editing a color enters dirty/draft state")
    func editEntersDraft() {
        let vm = TerminalThemeEditorViewModel()
        vm.load(source: bundledSource(), kind: .bundled)
        vm.setHex(slot: .foreground, hex: "#123456")
        #expect(vm.isDirty)
        #expect(vm.canReset == true)
        #expect(vm.canSaveAs == true)
        #expect(vm.canSave == false)
    }

    @Test("editing a user-source theme enables Save")
    func userSourceEnablesSave() {
        let vm = TerminalThemeEditorViewModel()
        vm.load(source: bundledSource(), kind: .user)
        vm.setHex(slot: .background, hex: "#abcdef")
        #expect(vm.canSave)
    }

    @Test("reset clears the draft and snaps back to source")
    func resetClears() {
        let vm = TerminalThemeEditorViewModel()
        vm.load(source: bundledSource(), kind: .bundled)
        vm.setHex(slot: .foreground, hex: "#123456")
        vm.reset()
        #expect(!vm.isDirty)
        #expect(vm.hex(slot: .foreground) == UserTerminalTheme.hex(from: bundledSource().foreground))
    }

    @Test("invalid hex is rejected without entering draft state")
    func invalidHexRejected() {
        let vm = TerminalThemeEditorViewModel()
        vm.load(source: bundledSource(), kind: .bundled)
        vm.setHex(slot: .foreground, hex: "not-a-color")
        #expect(!vm.isDirty)
        #expect(vm.lastValidationError != nil)
    }
}
