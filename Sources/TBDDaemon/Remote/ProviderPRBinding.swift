import TBDShared

/// Binds the PRs a remote session names in `meta.prs`. Installed by the
/// daemon after the RPC router exists; `ProviderPRBinder` conforms.
protocol ProviderPRBinding: Sendable {
    func bindNamedPRs(sessions: [RemoteSessionPayload], provider: String) async
}
