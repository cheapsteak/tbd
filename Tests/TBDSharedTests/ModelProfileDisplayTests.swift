import Foundation
import Testing
@testable import TBDShared

@Suite("ModelProfile display")
struct ModelProfileDisplayTests {

    @Test("kindLabel: oauth → OAuth")
    func kindLabelOAuth() {
        let p = ModelProfile(name: "x", kind: .oauth)
        #expect(p.kindLabel == "OAuth")
    }

    @Test("kindLabel: apiKey without baseURL → API key")
    func kindLabelApiKeyDirect() {
        let p = ModelProfile(name: "x", kind: .apiKey)
        #expect(p.kindLabel == "API key")
    }

    @Test("kindLabel: apiKey with baseURL → Proxy")
    func kindLabelProxy() {
        let p = ModelProfile(name: "x", kind: .apiKey, baseURL: "http://localhost:3456")
        #expect(p.kindLabel == "Proxy")
    }

    @Test("kindLabel: bedrock → Bedrock")
    func kindLabelBedrock() {
        let p = ModelProfile(name: "x", kind: .bedrock, model: "anthropic.claude-sonnet-4-5", awsRegion: "us-west-2")
        #expect(p.kindLabel == "Bedrock")
    }

    @Test("detailCaption: oauth → nil")
    func detailOAuthNil() {
        let p = ModelProfile(name: "x", kind: .oauth)
        #expect(p.detailCaption == nil)
    }

    @Test("detailCaption: direct apiKey → nil")
    func detailDirectApiKeyNil() {
        let p = ModelProfile(name: "x", kind: .apiKey)
        #expect(p.detailCaption == nil)
    }

    @Test("detailCaption: proxy with model → via URL · model")
    func detailProxyWithModel() {
        let p = ModelProfile(name: "x", kind: .apiKey, baseURL: "http://h:1", model: "gpt-5")
        #expect(p.detailCaption == "via http://h:1 · gpt-5")
    }

    @Test("detailCaption: proxy without model → via URL")
    func detailProxyNoModel() {
        let p = ModelProfile(name: "x", kind: .apiKey, baseURL: "http://h:1", model: nil)
        #expect(p.detailCaption == "via http://h:1")
    }

    @Test("detailCaption: bedrock with model → region · model")
    func detailBedrockWithModel() {
        let p = ModelProfile(name: "x", kind: .bedrock,
                             model: "anthropic.claude-sonnet-4-5",
                             awsRegion: "us-west-2")
        #expect(p.detailCaption == "us-west-2 · anthropic.claude-sonnet-4-5")
    }

    @Test("detailCaption: bedrock without model → region only")
    func detailBedrockNoModel() {
        let p = ModelProfile(name: "x", kind: .bedrock, model: nil, awsRegion: "us-west-2")
        #expect(p.detailCaption == "us-west-2")
    }

    @Test("detailCaption: bedrock missing region → ? · model")
    func detailBedrockNoRegion() {
        let p = ModelProfile(name: "x", kind: .bedrock,
                             model: "anthropic.claude-sonnet-4-5",
                             awsRegion: nil)
        #expect(p.detailCaption == "? · anthropic.claude-sonnet-4-5")
    }

    @Test("detailCaption: direct apiKey with model set → nil (model not shown without proxy)")
    func detailDirectApiKeyWithModelNil() {
        let p = ModelProfile(name: "x", kind: .apiKey, model: "claude-opus-4")
        #expect(p.detailCaption == nil)
    }

    @Test("detailCaption: bedrock with both region and model nil → bare \"?\"")
    func detailBedrockBothNil() {
        let p = ModelProfile(name: "x", kind: .bedrock, model: nil, awsRegion: nil)
        #expect(p.detailCaption == "?")
    }

    @Test("tabDisplayName returns name verbatim")
    func tabDisplayName() {
        let p = ModelProfile(name: "Bedrock prod", kind: .bedrock,
                             model: "anthropic.claude-sonnet-4-5",
                             awsRegion: "us-west-2")
        #expect(p.tabDisplayName == "Bedrock prod")
    }
}
