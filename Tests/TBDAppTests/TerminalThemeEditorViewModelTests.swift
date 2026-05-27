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

    @Test("unsetSlot reverts only the named slot")
    func unsetSlotRevertsOne() {
        let vm = TerminalThemeEditorViewModel()
        vm.load(source: bundledSource(), kind: .bundled)
        vm.setHex(slot: .foreground, hex: "#111111")
        vm.setHex(slot: .background, hex: "#222222")
        #expect(vm.isSlotDirty(.foreground))
        #expect(vm.isSlotDirty(.background))

        vm.unsetSlot(.foreground)
        #expect(!vm.isSlotDirty(.foreground))
        #expect(vm.isSlotDirty(.background))
        #expect(vm.hex(slot: .foreground) == UserTerminalTheme.hex(from: bundledSource().foreground))
        #expect(vm.isDirty)  // background still dirty → whole editor still dirty

        vm.unsetSlot(.background)
        #expect(!vm.isDirty)  // last dirty slot cleared → editor clean again
    }

    @Test("unsetSlot clears a matching invalid-hex validation error")
    func unsetSlotClearsMatchingError() {
        let vm = TerminalThemeEditorViewModel()
        vm.load(source: bundledSource(), kind: .bundled)
        vm.setHex(slot: .foreground, hex: "not-a-color")
        #expect(vm.lastValidationError != nil)

        vm.unsetSlot(.foreground)
        #expect(vm.lastValidationError == nil)
    }

    @Test("unsetSlot keeps a validation error scoped to a DIFFERENT slot")
    func unsetSlotKeepsUnrelatedError() {
        let vm = TerminalThemeEditorViewModel()
        vm.load(source: bundledSource(), kind: .bundled)
        vm.setHex(slot: .background, hex: "garbage")  // error scoped to Background
        vm.setHex(slot: .foreground, hex: "#abcdef")   // valid; foreground draft entered
        #expect(vm.lastValidationError != nil)

        vm.unsetSlot(.foreground)
        #expect(vm.lastValidationError != nil) // background error still there
    }

    @Test("isSlotDirty returns false for clean slots")
    func isSlotDirtyFalseWhenClean() {
        let vm = TerminalThemeEditorViewModel()
        vm.load(source: bundledSource(), kind: .bundled)
        #expect(!vm.isSlotDirty(.foreground))
        #expect(!vm.isSlotDirty(.ansi(0)))
    }

    @Test("invalid hex uses human-readable field labels")
    func invalidHexFieldLabelsAreHuman() {
        let vm = TerminalThemeEditorViewModel()
        vm.load(source: bundledSource(), kind: .bundled)
        vm.setHex(slot: .ansi(3), hex: "garbage")
        if case .invalidHex(let field, _) = vm.lastValidationError {
            #expect(field == "ANSI 3")
        } else {
            Issue.record("expected invalidHex error")
        }
        vm.setHex(slot: .foreground, hex: "garbage")
        if case .invalidHex(let field, _) = vm.lastValidationError {
            #expect(field == "Foreground")
        } else {
            Issue.record("expected invalidHex error")
        }
    }
}
