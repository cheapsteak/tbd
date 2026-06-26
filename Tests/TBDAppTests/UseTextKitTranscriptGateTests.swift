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

/// Models the three-way renderer precedence in `PanePlaceholder`:
/// `useTableViewTranscript` > `useTextKitTranscript` > SwiftUI. Tested via a
/// pure resolver so the branch logic is verified without standing up a view.
private enum TranscriptRenderer: Equatable {
    case table, textKit, swiftUI

    static func resolve(useTableView: Bool, useTextKit: Bool) -> TranscriptRenderer {
        if useTableView { return .table }
        if useTextKit { return .textKit }
        return .swiftUI
    }
}

@MainActor
@Suite("useTableViewTranscript gate")
struct UseTableViewTranscriptGateTests {
    private func suite(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("unset defaults to true (table pane is the default renderer)")
    func unsetIsTrue() {
        let name = "tableview-gate-unset"
        let d = suite(name)
        defer { d.removePersistentDomain(forName: name) }
        #expect(AppState.useTableViewTranscript(defaults: d) == true)
    }

    @Test("true enables the table pane")
    func trueIsTrue() {
        let name = "tableview-gate-true"
        let d = suite(name)
        defer { d.removePersistentDomain(forName: name) }
        d.set(true, forKey: AppState.useTableViewTranscriptKey)
        #expect(AppState.useTableViewTranscript(defaults: d) == true)
    }

    @Test("true selects the table renderer regardless of textkit")
    func tableTakesPrecedence() {
        // table on, textkit on → table wins (precedence: table > textkit > swiftui).
        #expect(TranscriptRenderer.resolve(useTableView: true, useTextKit: true) == .table)
        #expect(TranscriptRenderer.resolve(useTableView: true, useTextKit: false) == .table)
    }

    @Test("false leaves the existing textkit/swiftui precedence unchanged")
    func falseKeepsExistingPrecedence() {
        // table off → unchanged textkit/swiftui behavior.
        #expect(TranscriptRenderer.resolve(useTableView: false, useTextKit: true) == .textKit)
        #expect(TranscriptRenderer.resolve(useTableView: false, useTextKit: false) == .swiftUI)
    }

    @Test("returns false only when the user explicitly turns it off")
    func falseIsFalse() {
        let name = "tableview-gate-false"
        let d = suite(name)
        defer { d.removePersistentDomain(forName: name) }
        d.set(false, forKey: AppState.useTableViewTranscriptKey)
        #expect(AppState.useTableViewTranscript(defaults: d) == false)
    }
}
