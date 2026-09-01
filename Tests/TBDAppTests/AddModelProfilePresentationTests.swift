import Foundation
import Testing
@testable import TBDApp
import TBDShared

// The Add sheet's Claude segment gained a second, visible picker: sign in, or
// paste a `claude setup-token`. Each of the four rules below has an off-branch
// that is wrong in a way no compiler catches — a token silently sent on the
// sign-in path, or the login follow-up appearing after the one flow that
// exists to skip it — so both branches of each are pinned here.

// MARK: - addKind

@Test func addKind_tokenMode_namesTheKindExplicitly() {
    // `claudeDirect` carrying a token is the legacy path that stores nothing
    // and warns, so the token mode must say what it means outright.
    #expect(AddModelProfilePresentation.addKind(preset: .claudeDirect, authMode: .token)
            == .claudeToken)
}

@Test func addKind_signInMode_letsTheDaemonInfer() {
    #expect(AddModelProfilePresentation.addKind(preset: .claudeDirect, authMode: .signIn) == nil)
}

@Test func addKind_nonClaudePresets_ignoreTheAuthMode() {
    // The sub-picker lives inside the Claude segment; its stale value must not
    // leak into a proxy or bedrock save.
    #expect(AddModelProfilePresentation.addKind(preset: .proxy, authMode: .token) == nil)
    #expect(AddModelProfilePresentation.addKind(preset: .bedrock, authMode: .token) == nil)
}

// MARK: - tokenToSend

@Test func tokenToSend_signInMode_sendsNothingEvenWithAStrayValue() {
    // Switching to "Paste a token", typing, then switching back must not ship
    // a credential the user decided against.
    #expect(AddModelProfilePresentation.tokenToSend(preset: .claudeDirect,
                                                    authMode: .signIn,
                                                    token: "sk-ant-oat01-STRAY") == nil)
}

@Test func tokenToSend_tokenMode_sendsTheTypedValue() {
    #expect(AddModelProfilePresentation.tokenToSend(preset: .claudeDirect,
                                                    authMode: .token,
                                                    token: "sk-ant-oat01-AAA")
            == "sk-ant-oat01-AAA")
}

@Test func tokenToSend_proxyPreset_alwaysSendsTheTypedValue() {
    // The proxy path's own token field is unrelated to the Claude sub-picker
    // and must keep working whatever that picker last showed.
    #expect(AddModelProfilePresentation.tokenToSend(preset: .proxy,
                                                    authMode: .signIn,
                                                    token: "proxy-secret") == "proxy-secret")
    #expect(AddModelProfilePresentation.tokenToSend(preset: .proxy,
                                                    authMode: .token,
                                                    token: "proxy-secret") == "proxy-secret")
}

// MARK: - canSaveClaude

@Test func canSaveClaude_signInMode_needsNoToken() {
    #expect(AddModelProfilePresentation.canSaveClaude(authMode: .signIn, token: ""))
}

@Test func canSaveClaude_tokenMode_requiresANonBlankToken() {
    #expect(!AddModelProfilePresentation.canSaveClaude(authMode: .token, token: ""))
    // Whitespace is not a credential: the daemon trims before storing, so a
    // blank-looking value would be rejected after the sheet had closed.
    #expect(!AddModelProfilePresentation.canSaveClaude(authMode: .token, token: "   \n"))
    #expect(AddModelProfilePresentation.canSaveClaude(authMode: .token,
                                                      token: "sk-ant-oat01-AAA"))
}

// MARK: - showsLoginFollowUp

@Test func showsLoginFollowUp_signInMode_keepsTheExistingStep() {
    #expect(AddModelProfilePresentation.showsLoginFollowUp(preset: .claudeDirect,
                                                           authMode: .signIn))
}

@Test func showsLoginFollowUp_tokenMode_isSkipped() {
    // The whole point of the credential kind: the profile is usable the moment
    // the sheet closes, so "Profile Created → Open login session" would offer a
    // step that does nothing.
    #expect(!AddModelProfilePresentation.showsLoginFollowUp(preset: .claudeDirect,
                                                            authMode: .token))
}

@Test func showsLoginFollowUp_nonClaudePresets_neverShowIt() {
    #expect(!AddModelProfilePresentation.showsLoginFollowUp(preset: .proxy, authMode: .signIn))
    #expect(!AddModelProfilePresentation.showsLoginFollowUp(preset: .bedrock, authMode: .signIn))
}
