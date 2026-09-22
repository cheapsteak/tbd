import Foundation
import Testing
import TBDShared
@testable import TBDApp

@Suite("Provider identity presentation")
struct RemoteProviderIdentityPresentationTests {
    private func status(
        registryName: String,
        kind: String? = nil,
        exec: String = "/opt/agentbox/bin/agentbox",
        args: [String]? = nil,
        identity: [String: String]? = nil,
        providerVersion: String? = nil,
        contractVersion: Int? = nil
    ) -> RemoteProviderStatus {
        RemoteProviderStatus(
            config: RemoteProviderConfig(name: registryName, exec: exec, args: args),
            describe: kind.map {
                ProviderDescribe(
                    name: $0, providerVersion: providerVersion,
                    capabilities: ["attach"],
                    identity: identity.map(ProviderIdentity.init(pairs:)))
            },
            health: .ok, errorMessage: nil, remediationLabel: nil, remediationCommand: nil,
            contractVersion: contractVersion)
    }

    // MARK: - The headline

    @Test("the headline is the registry key, never the provider kind")
    func headlineIsTheRegistryKey() {
        // The reproduced failure: two registrations of the same binary both
        // rendered as "agentbox", so a user inspected one believing it was
        // the other.
        let management = status(registryName: "agentbox", kind: "agentbox")
        let staging = status(registryName: "agentbox-staging", kind: "agentbox")

        #expect(RemoteProviderIdentityPresentation.headline(management) == "agentbox")
        #expect(RemoteProviderIdentityPresentation.headline(staging) == "agentbox-staging")
        #expect(RemoteProviderIdentityPresentation.headline(management)
            != RemoteProviderIdentityPresentation.headline(staging))
    }

    @Test("the headline survives a provider whose describe has never succeeded")
    func headlineWithoutDescribe() {
        #expect(RemoteProviderIdentityPresentation.headline(status(registryName: "agentbox-staging"))
            == "agentbox-staging")
    }

    @Test("the kind is shown only when it adds something")
    func kindSubtitleOnlyWhenDistinct() {
        #expect(RemoteProviderIdentityPresentation.kindSubtitle(
            status(registryName: "agentbox", kind: "agentbox")) == nil)
        #expect(RemoteProviderIdentityPresentation.kindSubtitle(
            status(registryName: "agentbox-staging", kind: "agentbox")) == "reports as agentbox")
        #expect(RemoteProviderIdentityPresentation.kindSubtitle(
            status(registryName: "agentbox-staging")) == nil)
    }

    // MARK: - Identity rows

    @Test("identity pairs lead the block, well-known keys first")
    func identityRowsLeadTheBlock() {
        let provider = status(
            registryName: "agentbox-staging", kind: "agentbox",
            identity: ["environment": "staging", "account": "acme-1234", "tenant_slug": "acme"],
            providerVersion: "0.4.2", contractVersion: 2)

        let rows = RemoteProviderIdentityPresentation.rows(provider, homeDirectory: "/Users/me")

        #expect(rows.map(\.label) == ["Account", "Environment", "Tenant slug", "Command", "Version"])
        #expect(rows[0].value == "acme-1234")
        #expect(rows[1].value == "staging")
        #expect(rows.last?.value == "0.4.2 · contract v2")
    }

    @Test("without an identity block the command line is what distinguishes two registrations")
    func commandCarriesTheDistinctionWithoutIdentity() {
        let management = status(
            registryName: "agentbox", kind: "agentbox", args: ["--control-plane", "management"])
        let staging = status(
            registryName: "agentbox-staging", kind: "agentbox", args: ["--control-plane", "staging"])

        let managementRows = RemoteProviderIdentityPresentation.rows(management, homeDirectory: "/Users/me")
        let stagingRows = RemoteProviderIdentityPresentation.rows(staging, homeDirectory: "/Users/me")

        #expect(managementRows.map(\.label) == ["Command", "Version"])
        #expect(managementRows[0].value == "/opt/agentbox/bin/agentbox --control-plane management")
        #expect(stagingRows[0].value == "/opt/agentbox/bin/agentbox --control-plane staging")
        // Emphasised only while nothing better exists to tell them apart.
        #expect(managementRows[0].isDistinguishing == true)
    }

    @Test("the command line is tilde-abbreviated against an injected home")
    func abbreviatesHome() {
        let provider = status(registryName: "agentbox", exec: "/Users/me/bin/agentbox")

        #expect(RemoteProviderIdentityPresentation.commandLine(
            provider.config, homeDirectory: "/Users/me") == "~/bin/agentbox")
        // A different user's home never gets abbreviated away.
        #expect(RemoteProviderIdentityPresentation.commandLine(
            provider.config, homeDirectory: "/Users/acme") == "/Users/me/bin/agentbox")
    }

    @Test("a secret-looking registry argument never reaches the screen")
    func redactsRegistryArguments() {
        let provider = status(
            registryName: "agentbox", exec: "/opt/agentbox/bin/agentbox",
            args: ["--token=sk-live-1", "--profile", "acme"])

        let command = RemoteProviderIdentityPresentation.commandLine(
            provider.config, homeDirectory: "/Users/me")

        #expect(command.contains("sk-live-1") == false)
        #expect(command.contains(ProviderIdentityRedaction.redactedPlaceholder))
        #expect(command.hasSuffix("--profile acme"))
    }

    @Test("a credential-named identity pair is dropped rather than rendered")
    func redactsIdentityPairs() {
        let provider = status(
            registryName: "agentbox", kind: "agentbox",
            identity: ["account": "acme-1234", "session_token": "AQoDYXdz"])

        let rows = RemoteProviderIdentityPresentation.rows(provider, homeDirectory: "/Users/me")

        #expect(rows.contains { $0.value.contains("AQoDYXdz") } == false)
        #expect(rows.first?.label == "Account")
    }

    @Test("version is omitted entirely before describe has ever succeeded")
    func noVersionWithoutDescribe() {
        let rows = RemoteProviderIdentityPresentation.rows(
            status(registryName: "agentbox"), homeDirectory: "/Users/me")

        #expect(rows.map(\.label) == ["Command"])
    }

    @Test("a daemon that sends no negotiated version still reports the contract major")
    func versionFallsBackToMajorOne() {
        let provider = status(registryName: "agentbox", kind: "agentbox", providerVersion: nil)

        #expect(RemoteProviderIdentityPresentation.versionLine(provider) == "contract v1")
    }

    @Test("keys are humanized without inventing names for the ones TBD recognizes")
    func humanizesKeys() {
        #expect(RemoteProviderIdentityPresentation.humanizedKey("account") == "Account")
        #expect(RemoteProviderIdentityPresentation.humanizedKey("aws_region") == "Aws region")
        #expect(RemoteProviderIdentityPresentation.humanizedKey("control-plane") == "Control plane")
        #expect(RemoteProviderIdentityPresentation.humanizedKey("") == "")
    }

    @Test("the compact summary leads with the registry key and adds the first identity pair")
    func compactSummaryNamesTheRegistration() {
        let provider = status(
            registryName: "agentbox-staging", kind: "agentbox",
            identity: ["environment": "staging"])

        #expect(RemoteProviderIdentityPresentation.compactSummary(provider)
            == "agentbox-staging, reports as agentbox, Environment staging")
    }
}
