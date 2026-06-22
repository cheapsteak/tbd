import Foundation
import Testing
@testable import TBDApp

@MainActor
@Suite("useTextKitTranscript gate")
struct UseTextKitTranscriptGateTests {
    private func suite(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("unset defaults to false (fail closed)")
    func unsetIsFalse() {
        let d = suite("textkit-gate-unset")
        defer { d.removePersistentDomain(forName: "textkit-gate-unset") }
        #expect(AppState.useTextKitTranscript(defaults: d) == false)
    }

    @Test("true enables the TextKit pane")
    func trueIsTrue() {
        let name = "textkit-gate-true"
        let d = suite(name)
        defer { d.removePersistentDomain(forName: name) }
        d.set(true, forKey: AppState.useTextKitTranscriptKey)
        #expect(AppState.useTextKitTranscript(defaults: d) == true)
    }

    @Test("false keeps the SwiftUI pane")
    func falseIsFalse() {
        let name = "textkit-gate-false"
        let d = suite(name)
        defer { d.removePersistentDomain(forName: name) }
        d.set(false, forKey: AppState.useTextKitTranscriptKey)
        #expect(AppState.useTextKitTranscript(defaults: d) == false)
    }
}
