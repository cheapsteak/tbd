import Foundation
import TBDShared

/// Builds the environment a process run under a profile needs: the one
/// implementation behind `modelProfile.execEnvironment` (`tbd profile exec`)
/// and the Fable probe, so a probe runs on exactly the account an exec would.
///
/// Stricter than a spawn in two places, because a headless child has no pane
/// to show a problem in. A spawn on a token profile with no stored token opens
/// a pane that asks for a login; here that is a refusal naming the repair. And
/// a spawn whose config dir could not be prepared still opens; here the child
/// would fall back to the caller's own Claude config and run on whatever
/// account is signed in there, so that is a refusal too.
///
/// Repo-scope overrides do not apply: the child runs under a profile, not in a
/// repo.
enum ProfileExecEnvironmentBuilder {
    enum Outcome {
        case built(ModelProfileExecEnvironmentResult)
        /// Why no environment could be built; safe to show a person.
        case refused(String)
    }

    static func build(
        profileID: UUID,
        resolver: ModelProfileResolver,
        configDirManager: ClaudeProfileConfigDirManager,
        config configStore: ConfigStore,
        touchLastUsed: Bool = true
    ) async throws -> Outcome {
        guard let row = try await resolver.profiles.get(id: profileID) else {
            return .refused("Profile not found")
        }
        // Only an API-key profile with no stored key resolves to nil.
        guard let profile = try await resolver.loadByID(row.id, touchLastUsed: touchLastUsed) else {
            return .refused("Profile '\(row.name)' has no stored API key. "
                + "Add one in Settings → Model Profiles in the TBD app.")
        }
        if profile.kind == .oauthToken, profile.secret == nil {
            return .refused("Profile '\(row.name)' has no stored setup token. "
                + "Mint one with `claude setup-token` and paste it into Settings → Model Profiles → "
                + "\"Replace token…\" in the TBD app.")
        }
        let configDir = await configDirManager.resolveConfigDir(for: profile)
        if profile.kind != .bedrock, configDir == nil {
            return .refused("Could not prepare the config dir for profile '\(row.name)'; "
                + "the daemon log has the reason.")
        }
        let config = try await configStore.get()
        let environment = ClaudeSpawnCommandBuilder.execEnvironment(
            profileSecret: profile.secret,
            profileKind: profile.kind,
            profileBaseURL: profile.baseURL,
            profileModel: profile.model,
            profileAwsRegion: profile.awsRegion,
            profileAwsProfile: profile.awsProfile,
            profileConfigDir: configDir,
            envOverrides: EnvOverrideResolver.merge(
                global: config.envOverrides, repo: nil, profile: profile.envOverrides)
        )
        return .built(ModelProfileExecEnvironmentResult(
            profileID: profile.profileID,
            name: profile.name,
            kind: profile.kind,
            environment: environment
        ))
    }
}
