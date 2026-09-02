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
    loginIdentity: String? = nil,
    usageSnapshot: ProfileUsageSnapshot? = nil,
    tokenTail: String? = nil
) -> ModelProfileWithUsage {
    ModelProfileWithUsage(
        profile: ModelProfile(
            id: UUID(), name: "Work", kind: kind,
            baseURL: baseURL, model: model, awsRegion: awsRegion
        ),
        usage: nil,
        loginIdentity: loginIdentity,
        usageSnapshot: usageSnapshot,
        tokenTail: tokenTail
    )
}

private func probeSnapshot(_ statusKind: ProfileUsageStatusKind) -> ProfileUsageSnapshot {
    ProfileUsageSnapshot(buckets: [], fetchedAt: nil, lastAttemptAt: Date(),
                         status: "fixture", statusKind: statusKind)
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

// MARK: - Token profiles

@Test func needsLogin_oauthToken_isFalseWhateverTheIdentity() {
    // A token profile authenticates by its stored setup-token. A /login run
    // inside its config dir would be shadowed by the injected
    // CLAUDE_CODE_OAUTH_TOKEN, so the affordance must never be offered — that
    // skipped step is the entire friction this kind removes.
    #expect(!ProfileLoginPresentation.needsLogin(kind: .oauthToken, loginIdentity: nil))
    #expect(!ProfileLoginPresentation.needsLogin(kind: .oauthToken, loginIdentity: ""))
    #expect(!ProfileLoginPresentation.needsLogin(kind: .oauthToken, loginIdentity: "a@acme.com"))
}

@Test func menuTitleSuffix_oauthToken_isBare() {
    // No identity is readable for a setup token (the profile endpoint 403s),
    // so the menu row must not claim one — nor demand a /login.
    #expect(ProfileLoginPresentation.menuTitleSuffix(kind: .oauthToken, loginIdentity: nil) == "")
    #expect(ProfileLoginPresentation.menuTitleSuffix(kind: .oauthToken,
                                                    loginIdentity: "a@acme.com") == "")
}

@Test func maskedTokenCaption_rendersTailAndNilsWhenAbsent() {
    #expect(ProfileLoginPresentation.maskedTokenCaption(tokenTail: "4f2a") == "Token •••• 4f2a")
    // No tail from the daemon (older daemon, or the secret file is gone):
    // invent nothing.
    #expect(ProfileLoginPresentation.maskedTokenCaption(tokenTail: nil) == nil)
    #expect(ProfileLoginPresentation.maskedTokenCaption(tokenTail: "  ") == nil)
}

@Test func settingsCaption_oauthToken_showsMaskedTail() {
    let entry = makeEntry(kind: .oauthToken, tokenTail: "4f2a")
    #expect(ProfileLoginPresentation.settingsCaption(for: entry) == "Token •••• 4f2a")
}

@Test func settingsCaption_oauthToken_keepsEndpointDetails() {
    let entry = makeEntry(kind: .oauthToken, baseURL: "http://127.0.0.1:8080",
                          model: "opus", tokenTail: "4f2a")
    #expect(ProfileLoginPresentation.settingsCaption(for: entry)
            == "Token •••• 4f2a · via http://127.0.0.1:8080 · opus")
}

@Test func settingsCaption_oauthToken_neverAdvertisesLogin() {
    // The .oauth branch's "No login detected — run /login once" copy must not
    // leak onto a token profile through a grouped switch case.
    let entry = makeEntry(kind: .oauthToken, model: "opus")
    let caption = ProfileLoginPresentation.settingsCaption(for: entry)
    #expect(caption == "opus")
    #expect(caption?.contains("/login") != true)
}

@Test func settingsCaption_oauthToken_withNothingToSay_isNil() {
    #expect(ProfileLoginPresentation.settingsCaption(for: makeEntry(kind: .oauthToken)) == nil)
}

@Test func tokenRejected_onlyForTokenProfilesWithARejectedProbe() {
    // On-branch: a token profile whose probe came back 401/403.
    #expect(ProfileLoginPresentation.tokenRejected(
        for: makeEntry(kind: .oauthToken, usageSnapshot: probeSnapshot(.needsLogin))))

    // Off-branches. An oauth profile in the same snapshot state needs /login,
    // not a new token — a different repair with a different affordance.
    #expect(!ProfileLoginPresentation.tokenRejected(
        for: makeEntry(kind: .oauth, usageSnapshot: probeSnapshot(.needsLogin))))
    #expect(!ProfileLoginPresentation.tokenRejected(
        for: makeEntry(kind: .oauthToken, usageSnapshot: probeSnapshot(.ok))))
    #expect(!ProfileLoginPresentation.tokenRejected(
        for: makeEntry(kind: .oauthToken, usageSnapshot: probeSnapshot(.rateLimited))))
    // Never probed yet: not a rejection.
    #expect(!ProfileLoginPresentation.tokenRejected(for: makeEntry(kind: .oauthToken)))
}
