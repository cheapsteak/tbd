import Testing
import WebKit
@testable import TBDApp

@Suite("MarkdownWebViewConfiguration")
@MainActor
struct MarkdownWebViewConfigurationTests {

    @Test("JavaScript is disabled")
    func javaScriptDisabled() {
        let config = MarkdownWebViewConfiguration.make()
        #expect(config.defaultWebpagePreferences.allowsContentJavaScript == false)
    }

    @Test("data store is non-persistent")
    func nonPersistentStore() {
        let config = MarkdownWebViewConfiguration.make()
        #expect(config.websiteDataStore.isPersistent == false)
    }

    @Test("no URL scheme handler is registered for tbd-md")
    func noSchemeHandler() {
        let config = MarkdownWebViewConfiguration.make()
        #expect(config.urlSchemeHandler(forURLScheme: "tbd-md") == nil)
    }
}
