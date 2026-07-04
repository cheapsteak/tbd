import Foundation
import Testing
@testable import TBDApp
import TBDShared

// Pure string-composition rules for the login-identity badges (Phase 2a):
// Settings row captions, and the " — email" / " — needs /login" menu suffix
// used by both the "+" new-tab menu and the menu-bar profile switcher.

private func makeEntry(
    kind: CredentialKind = .oauth,
    baseURL: String? = nil,
    model: String? = nil,
    awsRegion: String? = nil,
    loginIdentity: String? = nil
) -> ModelProfileWithUsage {
    ModelProfileWithUsage(
        profile: ModelProfile(
            id: UUID(), name: "Work", kind: kind,
            baseURL: baseURL, model: model, awsRegion: awsRegion
        ),
        usage: nil,
        loginIdentity: loginIdentity
    )
}

// MARK: - needsLogin

@Test func needsLogin_oauthWithoutIdentity_isTrue() {
    #expect(ProfileLoginPresentation.needsLogin(kind: .oauth, loginIdentity: nil))
    #expect(ProfileLoginPresentation.needsLogin(kind: .oauth, loginIdentity: ""))
    #expect(ProfileLoginPresentation.needsLogin(kind: .oauth, loginIdentity: "  \n"))
}

@Test func needsLogin_oauthWithIdentity_isFalse() {
    #expect(!ProfileLoginPresentation.needsLogin(kind: .oauth, loginIdentity: "a@b.co"))
}

@Test func needsLogin_nonOAuthKinds_areNeverNeedsLogin() {
    #expect(!ProfileLoginPresentation.needsLogin(kind: .apiKey, loginIdentity: nil))
    #expect(!ProfileLoginPresentation.needsLogin(kind: .bedrock, loginIdentity: nil))
}

// MARK: - menuTitleSuffix / menuItemTitle

@Test func menuTitleSuffix_oauthLoggedIn_showsEmail() {
    #expect(ProfileLoginPresentation.menuTitleSuffix(kind: .oauth, loginIdentity: "a@b.co")
            == " — a@b.co")
}

@Test func menuTitleSuffix_oauthNotLoggedIn_showsNeedsLogin() {
    #expect(ProfileLoginPresentation.menuTitleSuffix(kind: .oauth, loginIdentity: nil)
            == " — needs /login")
    #expect(ProfileLoginPresentation.menuTitleSuffix(kind: .oauth, loginIdentity: "  ")
            == " — needs /login")
}

@Test func menuTitleSuffix_nonOAuth_isEmptyEvenWithStrayIdentity() {
    // loginIdentity should never be set for non-oauth kinds, but even if a
    // future daemon sends one, menus stay bare for those kinds.
    #expect(ProfileLoginPresentation.menuTitleSuffix(kind: .apiKey, loginIdentity: "x@y.z") == "")
    #expect(ProfileLoginPresentation.menuTitleSuffix(kind: .bedrock, loginIdentity: nil) == "")
}

@Test func menuItemTitle_composesDisplayNameAndSuffix() {
    let loggedIn = makeEntry(loginIdentity: "zadam@longeye.co")
    #expect(ProfileLoginPresentation.menuItemTitle(for: loggedIn) == "Work — zadam@longeye.co")

    let needsLogin = makeEntry()
    #expect(ProfileLoginPresentation.menuItemTitle(for: needsLogin) == "Work — needs /login")

    let bedrock = makeEntry(kind: .bedrock, awsRegion: "us-east-1")
    #expect(ProfileLoginPresentation.menuItemTitle(for: bedrock) == "Work")
}

// MARK: - settingsCaption

@Test func settingsCaption_oauthLoggedIn_leadsWithIdentity() {
    let entry = makeEntry(loginIdentity: "a@b.co")
    #expect(ProfileLoginPresentation.settingsCaption(for: entry) == "Logged in as a@b.co")
}

@Test func settingsCaption_oauthLoggedIn_keepsEndpointDetails() {
    let entry = makeEntry(baseURL: "http://127.0.0.1:8080", model: "opus",
                          loginIdentity: "a@b.co")
    #expect(ProfileLoginPresentation.settingsCaption(for: entry)
            == "Logged in as a@b.co · via http://127.0.0.1:8080 · opus")
}

@Test func settingsCaption_oauthNotLoggedIn_showsGentleHint() {
    // nil also covers an older daemon that doesn't send the field, so the
    // copy is an observation ("no login detected"), not a hard claim.
    let entry = makeEntry(model: "opus")
    #expect(ProfileLoginPresentation.settingsCaption(for: entry)
            == "No login detected — run /login once · opus")
}

@Test func settingsCaption_nonOAuth_matchesSharedDetailCaption() {
    let proxy = makeEntry(kind: .apiKey, baseURL: "http://127.0.0.1:3456", model: "gpt-5-codex")
    #expect(ProfileLoginPresentation.settingsCaption(for: proxy) == proxy.profile.detailCaption)
    #expect(ProfileLoginPresentation.settingsCaption(for: proxy)
            == "via http://127.0.0.1:3456 · gpt-5-codex")

    let bedrock = makeEntry(kind: .bedrock, model: "us.anthropic.claude-sonnet-4-5",
                            awsRegion: "us-west-2")
    #expect(ProfileLoginPresentation.settingsCaption(for: bedrock)
            == bedrock.profile.detailCaption)

    // Plain api-key profile with nothing to show stays nil, exactly like
    // detailCaption — the row simply renders no caption line.
    let bare = makeEntry(kind: .apiKey)
    #expect(ProfileLoginPresentation.settingsCaption(for: bare) == nil)
}
