import Foundation
import TBDShared
import os

extension RPCRouter {
    private static let skillLogger = Logger(subsystem: "com.tbd.daemon", category: "skill")

    func handleSkillStatus(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(SkillStatusParams.self, from: paramsData)
        let installer = SkillInstaller()
        let status = installer.status(harness: params.harness)
        let result = SkillStatusResult(
            harness: params.harness,
            status: status,
            harnessPath: installer.targetPath(for: params.harness),
            daemonHash: TBDSkillContent.bodyHash()
        )
        return try RPCResponse(result: result)
    }

    func handleSkillInstall(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(SkillInstallParams.self, from: paramsData)
        let installer = SkillInstaller()
        do {
            let result = try installer.install(harness: params.harness)
            Self.skillLogger.info("Skill install action=\(result.action.rawValue, privacy: .public) path=\(result.path, privacy: .public)")
            return try RPCResponse(result: SkillInstallResultRPC(action: result.action, path: result.path))
        } catch SkillInstallerError.harnessNotDetected(let harness) {
            return RPCResponse(error: "Harness not detected: \(harness.rawValue)")
        }
    }
}
