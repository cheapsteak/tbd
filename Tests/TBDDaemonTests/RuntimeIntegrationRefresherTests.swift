import Foundation
import Testing
@testable import TBDDaemonLib

@Suite("RuntimeIntegrationRefresher")
struct RuntimeIntegrationRefresherTests {

    @Test("refresh installs Codex hooks alongside the other runtime assets")
    func refreshInvokesAllInstallers() {
        var calls: [String] = []
        let refresher = RuntimeIntegrationRefresher(
            writeFallbackSkill: { calls.append("skill") },
            writeClaudePlugin: { calls.append("claude-plugin") },
            ensureCodexProfilePlugin: { calls.append("codex-plugin") },
            writeClaudeHookOverlay: { calls.append("claude-hooks") }
        )

        refresher.refresh()

        #expect(calls == ["skill", "claude-plugin", "codex-plugin", "claude-hooks"])
    }

    @Test("refresh keeps going when Codex plugin install fails")
    func refreshContinuesPastCodexFailure() {
        var calls: [String] = []
        let refresher = RuntimeIntegrationRefresher(
            writeFallbackSkill: { calls.append("skill") },
            writeClaudePlugin: { calls.append("claude-plugin") },
            ensureCodexProfilePlugin: {
                calls.append("codex-plugin")
                struct Failure: Error {}
                throw Failure()
            },
            writeClaudeHookOverlay: { calls.append("claude-hooks") }
        )

        refresher.refresh()

        #expect(calls == ["skill", "claude-plugin", "codex-plugin", "claude-hooks"])
    }
}
