import Foundation
import Testing
@testable import TBDApp

@Suite("BedrockModels parser")
struct BedrockModelsTests {

    @Test("parseProfileIDs: valid JSON array of strings")
    func parseValid() {
        let json = """
        ["us.anthropic.claude-sonnet-4-5", "us.anthropic.claude-opus-4-7"]
        """
        let ids = BedrockModels.parseProfileIDs(json)
        #expect(ids == ["us.anthropic.claude-opus-4-7", "us.anthropic.claude-sonnet-4-5"])
    }

    @Test("parseProfileIDs: empty array")
    func parseEmpty() {
        #expect(BedrockModels.parseProfileIDs("[]") == [])
    }

    @Test("parseProfileIDs: dedupes")
    func parseDedupes() {
        let json = """
        ["us.x", "us.x", "us.y"]
        """
        #expect(BedrockModels.parseProfileIDs(json) == ["us.x", "us.y"])
    }

    @Test("parseProfileIDs: malformed JSON returns empty")
    func parseMalformed() {
        #expect(BedrockModels.parseProfileIDs("not json") == [])
        #expect(BedrockModels.parseProfileIDs("{}") == [])
        #expect(BedrockModels.parseProfileIDs("") == [])
    }

    @Test("discover: empty region returns success with empty models")
    func discoverEmptyRegion() async {
        let r1 = await BedrockModels.discover(region: "", awsProfile: nil)
        #expect(r1 == .success(models: []))
        let r2 = await BedrockModels.discover(region: "   ", awsProfile: nil)
        #expect(r2 == .success(models: []))
    }

    @Test("classifyAsAuth: SSO expired")
    func classifySSOExpired() {
        #expect(BedrockModels.classifyAsAuth("Error when retrieving token from sso: Token has expired and refresh failed"))
    }

    @Test("classifyAsAuth: missing credentials")
    func classifyMissingCreds() {
        #expect(BedrockModels.classifyAsAuth("Unable to locate credentials. You can configure credentials by running 'aws configure'"))
    }

    @Test("classifyAsAuth: profile typo")
    func classifyProfileTypo() {
        #expect(BedrockModels.classifyAsAuth("The config profile (xyz) could not be found"))
    }

    @Test("classifyAsAuth: SSO session expired variant")
    func classifySSOSessionExpired() {
        #expect(BedrockModels.classifyAsAuth("Your SSO session has expired. Please re-authenticate."))
    }

    @Test("classifyAsAuth: non-auth error does not match")
    func classifyNonAuth() {
        #expect(!BedrockModels.classifyAsAuth("AccessDeniedException: User is not authorized to perform: bedrock:ListInferenceProfiles"))
        #expect(!BedrockModels.classifyAsAuth("ServiceUnavailableException"))
        #expect(!BedrockModels.classifyAsAuth(""))
    }

    @Test("classify: aws-cli not installed (env says no such file)")
    func classifyAwsCliMissingFromEnv() {
        let r = BedrockModels.classify(stderr: "env: aws: No such file or directory\n")
        #expect(r == .awsCliMissing)
    }

    @Test("classify: aws-cli not installed (command not found variant)")
    func classifyAwsCliMissingFromShell() {
        let r = BedrockModels.classify(stderr: "bash: aws: command not found")
        #expect(r == .awsCliMissing)
    }

    @Test("classify: AccessDeniedException → accessDenied")
    func classifyAccessDenied() {
        let r = BedrockModels.classify(stderr: "An error occurred (AccessDeniedException) when calling the ListInferenceProfiles operation: User is not authorized to perform: bedrock:ListInferenceProfiles")
        if case .accessDenied = r { /* ok */ } else { #expect(Bool(false), "expected .accessDenied, got \(r)") }
    }

    @Test("classify: SCP explicit deny → accessDenied")
    func classifySCPDeny() {
        let r = BedrockModels.classify(stderr: "with an explicit deny in a service control policy: arn:aws:organizations::123:policy/p-foo")
        if case .accessDenied = r { /* ok */ } else { #expect(Bool(false), "expected .accessDenied") }
    }

    @Test("classify: endpoint not available → endpointUnavailable")
    func classifyEndpointNotAvailable() {
        let r = BedrockModels.classify(stderr: "Could not connect to the endpoint URL: \"https://bedrock.foo-region.amazonaws.com/inference-profiles\"")
        if case .endpointUnavailable = r { /* ok */ } else { #expect(Bool(false), "expected .endpointUnavailable") }
    }

    @Test("classify: service not available variant → endpointUnavailable")
    func classifyServiceNotAvailable() {
        let r = BedrockModels.classify(stderr: "Bedrock service is not available in this region.")
        if case .endpointUnavailable = r { /* ok */ } else { #expect(Bool(false), "expected .endpointUnavailable") }
    }

    @Test("classify: unrecognized stderr → otherError")
    func classifyOther() {
        let r = BedrockModels.classify(stderr: "ServiceUnavailableException: Internal server error")
        if case .otherError = r { /* ok */ } else { #expect(Bool(false), "expected .otherError") }
    }
}
