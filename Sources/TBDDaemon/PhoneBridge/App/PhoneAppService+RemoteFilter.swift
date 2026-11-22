import Foundation
import TBDShared

/// `repo.setRemoteFilter` (docs/specs/2026-11-22-phone-remote-session-filter-design.md,
/// "Setting it"): the phone's chip turns a repo's registry-provider filter on
/// or off.
///
/// **One setting, shared with the laptop.** The request goes through
/// `phoneSetRegistryRemoteHidden`, the core the socket RPC
/// `repo.setRegistryRemoteHidden` runs, so a tap on the phone writes the
/// column the laptop sidebar reads, and the delta it broadcasts wakes the
/// sessions publisher: the phone's next layout carries the new
/// `remoteFilterOn`.
///
/// **Only a repo the phone can see.** A repo that is gone, or hidden, which
/// the sessions list never shows, is `not_found`, as the creates read it
/// (`visibleRepo(_:)`). A repo removed after that check and before the
/// core's write is `not_found` too: the core refuses it, and the request
/// reads the repo again before it answers. Any other refusal from the core is
/// `refused` with its reason.
///
/// The request is in the request memory (`remembersReplies(of:)`), so a
/// resend after a lost reply writes nothing a later tap has changed since.
/// Its record names the repo.
extension PhoneAppService {
    nonisolated func repoSetRemoteFilter(
        _ params: PhoneRepoSetRemoteFilterParams, _ context: DeviceContext
    ) async throws -> PhoneEmpty {
        _ = try await visibleRepo(params.repoID)
        try Task.checkCancellation()
        let response = try await actions.phoneSetRegistryRemoteHidden(
            RepoSetRegistryRemoteHiddenParams(repoID: params.repoID, hidden: params.hidden))
        guard response.success else {
            _ = try await visibleRepo(params.repoID)
            throw Self.refusal(response.error)
        }
        return PhoneEmpty()
    }
}
