import Foundation
import Testing
@testable import TBDDaemonLib

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func conductorJsonSetupHook() throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let resolver = HookResolver(globalHooksDir: tempDir.appendingPathComponent("global-hooks").path)

    // Create conductor.json
    let conductorJSON = """
    {"scripts":{"setup":"scripts/setup.sh","archive":"scripts/archive.sh"}}
    """
    try conductorJSON.write(
        toFile: tempDir.appendingPathComponent("conductor.json").path,
        atomically: true, encoding: .utf8
    )

    // Create the script file
    let scriptsDir = tempDir.appendingPathComponent("scripts")
    try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
    try "#!/bin/bash\necho setup".write(
        toFile: scriptsDir.appendingPathComponent("setup.sh").path,
        atomically: true, encoding: .utf8
    )

    let hook = resolver.resolve(event: .setup, repoPath: tempDir.path, appHookPath: nil)
    #expect(hook != nil)
    #expect(hook!.contains("scripts/setup.sh"))
}

@Test func conductorJsonArchiveHook() throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let resolver = HookResolver(globalHooksDir: tempDir.appendingPathComponent("global-hooks").path)

    let conductorJSON = """
    {"scripts":{"setup":"scripts/setup.sh","archive":"scripts/archive.sh"}}
    """
    try conductorJSON.write(
        toFile: tempDir.appendingPathComponent("conductor.json").path,
        atomically: true, encoding: .utf8
    )

    let scriptsDir = tempDir.appendingPathComponent("scripts")
    try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
    try "#!/bin/bash\necho archive".write(
        toFile: scriptsDir.appendingPathComponent("archive.sh").path,
        atomically: true, encoding: .utf8
    )

    let hook = resolver.resolve(event: .archive, repoPath: tempDir.path, appHookPath: nil)
    #expect(hook != nil)
    #expect(hook!.contains("scripts/archive.sh"))
}

@Test func dmuxHookFallback() throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let resolver = HookResolver(globalHooksDir: tempDir.appendingPathComponent("global-hooks").path)

    // No conductor.json, but .dmux-hooks/worktree_created exists
    let dmuxDir = tempDir.appendingPathComponent(".dmux-hooks")
    try FileManager.default.createDirectory(at: dmuxDir, withIntermediateDirectories: true)
    let hookPath = dmuxDir.appendingPathComponent("worktree_created").path
    try "#!/bin/bash\necho dmux".write(toFile: hookPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookPath)

    let hook = resolver.resolve(event: .setup, repoPath: tempDir.path, appHookPath: nil)
    #expect(hook != nil)
    #expect(hook!.contains(".dmux-hooks/worktree_created"))
}

@Test func dmuxArchiveHookFallback() throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let resolver = HookResolver(globalHooksDir: tempDir.appendingPathComponent("global-hooks").path)

    let dmuxDir = tempDir.appendingPathComponent(".dmux-hooks")
    try FileManager.default.createDirectory(at: dmuxDir, withIntermediateDirectories: true)
    let hookPath = dmuxDir.appendingPathComponent("before_worktree_remove").path
    try "#!/bin/bash\necho dmux-archive".write(toFile: hookPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookPath)

    let hook = resolver.resolve(event: .archive, repoPath: tempDir.path, appHookPath: nil)
    #expect(hook != nil)
    #expect(hook!.contains(".dmux-hooks/before_worktree_remove"))
}

@Test func appConfigTrumpsAll() throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let resolver = HookResolver(globalHooksDir: tempDir.appendingPathComponent("global-hooks").path)

    // Both conductor.json and app config exist — app config wins
    let conductorJSON = """
    {"scripts":{"setup":"scripts/setup.sh"}}
    """
    try conductorJSON.write(
        toFile: tempDir.appendingPathComponent("conductor.json").path,
        atomically: true, encoding: .utf8
    )

    let scriptsDir = tempDir.appendingPathComponent("scripts")
    try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
    try "#!/bin/bash\necho setup".write(
        toFile: scriptsDir.appendingPathComponent("setup.sh").path,
        atomically: true, encoding: .utf8
    )

    let appHookPath = tempDir.appendingPathComponent("app-hook.sh").path
    try "#!/bin/bash\necho app".write(toFile: appHookPath, atomically: true, encoding: .utf8)

    let hook = resolver.resolve(event: .setup, repoPath: tempDir.path, appHookPath: appHookPath)
    #expect(hook == appHookPath)
}

@Test func globalDefaultFallback() throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let globalDir = tempDir.appendingPathComponent("global-hooks")
    try FileManager.default.createDirectory(at: globalDir, withIntermediateDirectories: true)

    let globalHookPath = globalDir.appendingPathComponent("setup").path
    try "#!/bin/bash\necho global".write(toFile: globalHookPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: globalHookPath)

    let resolver = HookResolver(globalHooksDir: globalDir.path)

    // No conductor.json, no .dmux-hooks, no app config — global default should be used
    let hook = resolver.resolve(event: .setup, repoPath: tempDir.path, appHookPath: nil)
    #expect(hook == globalHookPath)
}

@Test func noHooksReturnsNil() throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let resolver = HookResolver(globalHooksDir: tempDir.appendingPathComponent("global-hooks").path)

    let hook = resolver.resolve(event: .setup, repoPath: tempDir.path, appHookPath: nil)
    #expect(hook == nil)
}

@Test func executeHookSuccess() async throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let resolver = HookResolver(globalHooksDir: tempDir.appendingPathComponent("global-hooks").path)

    let hookPath = tempDir.appendingPathComponent("test-hook.sh").path
    try "#!/bin/bash\necho hello".write(toFile: hookPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookPath)

    let (success, output) = try await resolver.execute(
        hookPath: hookPath, cwd: tempDir.path, env: [:]
    )
    #expect(success)
    #expect(output.contains("hello"))
}

@Test func executeHookFailure() async throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let resolver = HookResolver(globalHooksDir: tempDir.appendingPathComponent("global-hooks").path)

    let hookPath = tempDir.appendingPathComponent("fail-hook.sh").path
    try "#!/bin/bash\nexit 1".write(toFile: hookPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookPath)

    let (success, _) = try await resolver.execute(
        hookPath: hookPath, cwd: tempDir.path, env: [:]
    )
    #expect(!success)
}

@Test func executeHookReceivesEnv() async throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let resolver = HookResolver(globalHooksDir: tempDir.appendingPathComponent("global-hooks").path)

    let hookPath = tempDir.appendingPathComponent("env-hook.sh").path
    try "#!/bin/bash\necho $MY_VAR".write(toFile: hookPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookPath)

    let (success, output) = try await resolver.execute(
        hookPath: hookPath, cwd: tempDir.path, env: ["MY_VAR": "test_value"]
    )
    #expect(success)
    #expect(output.contains("test_value"))
}
