import Foundation
import Testing
import SwiftUI
@testable import TBDApp
@testable import TBDShared

@Suite("NightwatchDeskStatusLabel")
struct NightwatchDeskStatusLabelTests {
    @Test("nightwatchDeskStatusContent for .off mode returns nil")
    func deskStatusContentOffMode() {
        let content = nightwatchDeskStatusContent(for: .off)
        #expect(content == nil)
    }

    @Test("nightwatchDeskStatusContent for .daywatch mode returns daywatch content")
    func deskStatusContentDaywatch() {
        let content = nightwatchDeskStatusContent(for: .daywatch)
        #expect(content != nil)
        if let content = content {
            #expect(content.glyph == "◐")
            #expect(content.text == "Daywatch desk")
        }
    }

    @Test("nightwatchDeskStatusContent for .nightwatch mode returns nightwatch content")
    func deskStatusContentNightwatch() {
        let content = nightwatchDeskStatusContent(for: .nightwatch)
        #expect(content != nil)
        if let content = content {
            #expect(content.glyph == "🌙")
            #expect(content.text == "Nightwatch desk")
        }
    }

    @Test("nightwatchDeskStatusContent is deterministic for each mode")
    func deskStatusContentDeterministic() {
        let offContent1 = nightwatchDeskStatusContent(for: .off)
        let offContent2 = nightwatchDeskStatusContent(for: .off)
        #expect(offContent1 == offContent2)

        let daywatchContent1 = nightwatchDeskStatusContent(for: .daywatch)
        let daywatchContent2 = nightwatchDeskStatusContent(for: .daywatch)
        #expect(daywatchContent1 == daywatchContent2)

        let nightwatchContent1 = nightwatchDeskStatusContent(for: .nightwatch)
        let nightwatchContent2 = nightwatchDeskStatusContent(for: .nightwatch)
        #expect(nightwatchContent1 == nightwatchContent2)
    }

    @Test("nightwatchDeskStatusContent returns different content for daywatch vs nightwatch")
    func deskStatusContentDifferentPerMode() {
        let daywatchContent = nightwatchDeskStatusContent(for: .daywatch)
        let nightwatchContent = nightwatchDeskStatusContent(for: .nightwatch)
        #expect(daywatchContent != nightwatchContent)

        // Verify glyphs are different
        if let daywatch = daywatchContent, let nightwatch = nightwatchContent {
            #expect(daywatch.glyph != nightwatch.glyph)
        }
    }
}
