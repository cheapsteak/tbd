import Foundation
import Testing
@testable import TBDApp

@Test("badge hides when terminal matches default")
func hideWhenMatches() {
    let id = UUID()
    #expect(shouldShowProfileBadge(terminalProfileID: id, resolvedDefaultID: id) == false)
}

@Test("badge shows when terminal differs from default")
func showWhenDiffers() {
    let a = UUID()
    let b = UUID()
    #expect(shouldShowProfileBadge(terminalProfileID: a, resolvedDefaultID: b) == true)
}

@Test("badge hides for legacy terminals with nil profileID")
func hideWhenNil() {
    let a = UUID()
    #expect(shouldShowProfileBadge(terminalProfileID: nil, resolvedDefaultID: a) == false)
}

@Test("badge hides when both terminal and default are nil")
func hideWhenBothNil() {
    #expect(shouldShowProfileBadge(terminalProfileID: nil, resolvedDefaultID: nil) == false)
}
