import TBDShared

extension AppState {
    func loadCodexUsage() async {
        guard !isLoadingCodexUsage else { return }
        isLoadingCodexUsage = true
        defer { isLoadingCodexUsage = false }
        do {
            codexUsage = try await daemonClient.fetchCodexUsage()
        } catch {
            codexUsage = CodexUsageResult(unavailableReason: "Usage unavailable")
        }
    }
}
