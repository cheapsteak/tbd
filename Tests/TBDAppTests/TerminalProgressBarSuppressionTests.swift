import AppKit
import Foundation
import SwiftTerm
import Testing

@testable import TBDApp

/// SwiftTerm draws OSC 9;4 progress reports as a bar across the top of the
/// view, and Claude Code emits those continuously while it responds. TBD
/// already reports working state in the sidebar and the tab indicators, and
/// the bar carries its own 15-second expiry that can disagree with them, so
/// every terminal pane turns it off at construction. There is deliberately no
/// preference to read: this pins the one place the decision lives.
@MainActor
@Suite("Terminal progress bar suppression")
struct TerminalProgressBarSuppressionTests {
    /// Isolated defaults: AppearanceSettings must never read or write the
    /// developer's real TBDApp.plist. Same idiom as TerminalLockedAccessTests.
    @Test("a freshly constructed terminal view suppresses the OSC 9;4 bar")
    func newViewHidesProgressBar() {
        let suiteName = "TBDAppTests.ProgressBar.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let view = TBDTerminalView(
            frame: CGRect(x: 0, y: 0, width: 600, height: 300),
            font: TBDTerminalView.defaultMonospaceFont,
            appearance: AppearanceSettings(defaults: defaults))

        #expect(view.showsProgressBar == false)
    }
}
