import Foundation
import Testing
@testable import TBDShared

/// Tier 1. The contract's error-model classification
/// (`docs/remote-provider-contract.md` § Error model), which both the daemon
/// (verb exits, with an error object) and the app (attach exits, without
/// one) key off — so every branch of the union rule is pinned here rather
/// than in either consumer.
@Suite("ProviderFailureClass")
struct ProviderFailureClassTests {
    private func error(_ code: String) -> ProviderErrorObject {
        ProviderErrorObject(code: code, message: "m", retryable: false, remediation: nil)
    }

    // MARK: - Exit class alone

    @Test func exitZeroIsNotAFailure() {
        #expect(ProviderFailureClass.classify(exitCode: 0, error: nil) == nil)
    }

    /// Exit 0 is success by contract, so nothing decoded from stdout can
    /// turn it into a failure — a `list` response that happened to contain
    /// an `error` key must not put the provider into an auth state.
    @Test func exitZeroStaysSuccessEvenWithAnAuthCode() {
        #expect(ProviderFailureClass.classify(exitCode: 0, error: error("auth_expired")) == nil)
    }

    @Test func exitFourWithNoErrorObjectIsAuthNeeded() {
        #expect(ProviderFailureClass.classify(exitCode: 4, error: nil) == .authNeeded)
    }

    /// The union, from the exit-class side: exit 4 is the contract's
    /// classification of record, so an unrecognized `code` alongside it
    /// adds nothing and takes nothing away.
    @Test func exitFourWithAnUnrecognizedCodeIsStillAuthNeeded() {
        #expect(ProviderFailureClass.classify(exitCode: 4, error: error("teapot_unavailable")) == .authNeeded)
    }

    /// The union is a union, not a preference: a RECOGNIZED non-auth code
    /// alongside exit 4 must not demote it. Exit class is the contract's
    /// classification of record and stands on its own.
    @Test func exitFourWithARecognizedNonAuthCodeIsStillAuthNeeded() {
        #expect(ProviderFailureClass.classify(exitCode: 4, error: error("not_found")) == .authNeeded)
        #expect(ProviderFailureClass.classify(exitCode: 4, error: error("credential_unresolvable")) == .authNeeded)
    }

    @Test func exitThreeIsTransient() {
        #expect(ProviderFailureClass.classify(exitCode: 3, error: nil) == .transient)
    }

    @Test func exitTwoIsAContractBug() {
        #expect(ProviderFailureClass.classify(exitCode: 2, error: nil) == .contractBug)
    }

    @Test func exitOneIsPermanent() {
        #expect(ProviderFailureClass.classify(exitCode: 1, error: nil) == .permanent)
    }

    @Test func undeclaredExitCodesArePermanent() {
        #expect(ProviderFailureClass.classify(exitCode: 137, error: nil) == .permanent)
    }

    // MARK: - Error code adding precision

    /// The union, from the code side: a provider that names an auth code
    /// while exiting 1 lands in `.authNeeded` anyway, so its remediation
    /// reaches the user instead of a dead-end "permanent error".
    @Test func authExpiredOnExitOneIsAuthNeeded() {
        #expect(ProviderFailureClass.classify(exitCode: 1, error: error("auth_expired")) == .authNeeded)
    }

    @Test func authMissingOnExitOneIsAuthNeeded() {
        #expect(ProviderFailureClass.classify(exitCode: 1, error: error("auth_missing")) == .authNeeded)
    }

    @Test func authCodeOnATransientExitIsAuthNeeded() {
        #expect(ProviderFailureClass.classify(exitCode: 3, error: error("auth_missing")) == .authNeeded)
    }

    @Test func nonAuthCodeOnExitOneStaysPermanent() {
        #expect(ProviderFailureClass.classify(exitCode: 1, error: error("not_found")) == .permanent)
    }

    /// `credential_unresolvable` is deliberately NOT an auth code: per the
    /// contract its remedy is provisioning on the provider side, not a human
    /// re-authenticating, and it is a distinct code with its own meaning.
    @Test func credentialUnresolvableIsNotAuthNeeded() {
        #expect(ProviderFailureClass.classify(exitCode: 1, error: error("credential_unresolvable")) == .permanent)
        #expect(!ProviderFailureClass.authErrorCodes.contains("credential_unresolvable"))
    }

    /// An unrecognized code never downgrades the exit class it arrived with.
    @Test func unrecognizedCodeLeavesTheExitClassIntact() {
        #expect(ProviderFailureClass.classify(exitCode: 3, error: error("who_knows")) == .transient)
        #expect(ProviderFailureClass.classify(exitCode: 2, error: error("who_knows")) == .contractBug)
    }
}
