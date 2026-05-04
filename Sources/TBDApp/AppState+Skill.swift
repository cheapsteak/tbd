import Foundation
import TBDShared
import os

extension AppState {
    private static let skillLogger = Logger(subsystem: "com.tbd.app", category: "skill")

    /// Refresh the cached skill status. Called on app activation and after install.
    @MainActor
    func refreshSkillStatus() async {
        do {
            let result = try await daemonClient.skillStatus()
            self.skillStatus = result
        } catch {
            Self.skillLogger.error("refreshSkillStatus error: \(String(describing: error), privacy: .public)")
        }
    }

    /// Install or update the skill, then refresh status so the menu reflects the new state.
    @MainActor
    func installSkill() async {
        do {
            _ = try await daemonClient.installSkill()
        } catch {
            Self.skillLogger.error("installSkill error: \(String(describing: error), privacy: .public)")
        }
        await refreshSkillStatus()
    }
}
