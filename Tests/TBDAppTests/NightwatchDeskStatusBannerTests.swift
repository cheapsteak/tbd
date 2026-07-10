import Foundation
import Testing
import SwiftUI
@testable import TBDApp
@testable import TBDShared

@Suite("NightwatchDeskStatusBanner")
struct NightwatchDeskStatusBannerTests {
    @Test("nightwatchBannerContent for .off mode returns nil")
    func bannerContentOffMode() {
        let content = nightwatchBannerContent(for: .off)
        #expect(content == nil)
    }

    @Test("nightwatchBannerContent for .daywatch mode returns daywatch content")
    func bannerContentDaywatch() {
        let content = nightwatchBannerContent(for: .daywatch)
        #expect(content != nil)
        if let content = content {
            #expect(content.glyph == "◐")
            #expect(content.text == "Daywatch — desk session active")
        }
    }

    @Test("nightwatchBannerContent for .nightwatch mode returns nightwatch content")
    func bannerContentNightwatch() {
        let content = nightwatchBannerContent(for: .nightwatch)
        #expect(content != nil)
        if let content = content {
            #expect(content.glyph == "🌙")
            #expect(content.text == "Nightwatch — desk session active")
        }
    }

    @Test("nightwatchBannerContent is deterministic for each mode")
    func bannerContentDeterministic() {
        let offContent1 = nightwatchBannerContent(for: .off)
        let offContent2 = nightwatchBannerContent(for: .off)
        #expect(offContent1 == offContent2)

        let daywatchContent1 = nightwatchBannerContent(for: .daywatch)
        let daywatchContent2 = nightwatchBannerContent(for: .daywatch)
        #expect(daywatchContent1 == daywatchContent2)

        let nightwatchContent1 = nightwatchBannerContent(for: .nightwatch)
        let nightwatchContent2 = nightwatchBannerContent(for: .nightwatch)
        #expect(nightwatchContent1 == nightwatchContent2)
    }

    @Test("nightwatchBannerContent returns different content for daywatch vs nightwatch")
    func bannerContentDifferentPerMode() {
        let daywatchContent = nightwatchBannerContent(for: .daywatch)
        let nightwatchContent = nightwatchBannerContent(for: .nightwatch)
        #expect(daywatchContent != nightwatchContent)

        // Verify glyphs are different
        if let daywatch = daywatchContent, let nightwatch = nightwatchContent {
            #expect(daywatch.glyph != nightwatch.glyph)
        }
    }
}
