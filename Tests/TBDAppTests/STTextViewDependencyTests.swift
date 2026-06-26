import STTextView
import AppKit
import Testing
@testable import TBDApp

@MainActor
@Suite("STTextView dependency smoke test")
struct STTextViewDependencyTests {
    @Test("scrollableTextView() vends an STTextView document view")
    func factoryVendsTextView() {
        let scrollView = STTextView.scrollableTextView()
        #expect(scrollView.documentView is STTextView)
    }
}
