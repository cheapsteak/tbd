import Testing
import Foundation
@testable import TBDDaemonLib

@Suite("RetiredLaunchAgent")
struct RetiredLaunchAgentTests {

    private static let userID: uid_t = 501
    private static let bootout = ["bootout", "gui/501/com.nightwatch-tick"]

    /// A scratch root holding a `LaunchAgents` folder. The real
    /// `~/Library/LaunchAgents` is never touched.
    private static func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-retired-launch-agent-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("LaunchAgents"), withIntermediateDirectories: true)
        return root
    }

    private static func agentsDir(_ root: URL) -> URL {
        root.appendingPathComponent("LaunchAgents")
    }

    /// Where the plugin's copy of the scheduler's script was. Nothing is
    /// written there, so it is absent the way it is once the plugin writer has
    /// removed the skill.
    private static func pluginScript(_ root: URL) -> String {
        root.appendingPathComponent(
            "Application Support/TBD/plugin/skills/nightwatch/scripts/tick-cron.sh").path
    }

    /// The plist `scheduler.sh enable` wrote, as its heredoc spelled it.
    private static func schedulerPlist(
        label: String = RetiredLaunchAgent.label, script: String, interval: Int = 900
    ) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key><array>
            <string>/bin/bash</string><string>\(script)</string>
          </array>
          <key>StartInterval</key><integer>\(interval)</integer>
          <key>RunAtLoad</key><true/>
          <key>StandardErrorPath</key><string>/tmp/nightwatch-tick.err</string>
        </dict></plist>

        """
    }

    private static func write(_ text: String, to url: URL) throws {
        try write(Data(text.utf8), to: url)
    }

    private static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private static func plistURL(_ root: URL) -> URL {
        agentsDir(root).appendingPathComponent(RetiredLaunchAgent.plistName)
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private static func agent(_ root: URL, _ launchctl: RecordingLaunchctl) -> RetiredLaunchAgent {
        RetiredLaunchAgent(launchAgentsDirectory: agentsDir(root), userID: userID, launchctl: launchctl)
    }

    @Test func theSchedulersJobIsBootedOutAndItsPlistRemoved() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plist = Self.plistURL(root)
        let script = Self.pluginScript(root)
        try Self.write(Self.schedulerPlist(script: script), to: plist)
        #expect(RetiredLaunchAgent.retiredScriptPath(inPlist: try Data(contentsOf: plist)) == script)
        let launchctl = RecordingLaunchctl()

        #expect(await Self.agent(root, launchctl).removeIfPresent() == .removed(.unloaded))

        #expect(launchctl.calls == [Self.bootout])
        #expect(!Self.exists(plist))

        // Idempotent: a second start finds nothing and runs nothing.
        #expect(await Self.agent(root, launchctl).removeIfPresent() == .absent)
        #expect(launchctl.calls == [Self.bootout])
    }

    /// The scheduler wrote the directory it was run from, so a copy of the
    /// skill outside the plugin folder matches on the suffix just the same.
    @Test func theScriptIsMatchedBySuffixWhateverItsBase() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plist = Self.plistURL(root)
        let script = root.appendingPathComponent("acme home/.agents/skills/nightwatch/scripts/tick-cron.sh").path
        try Self.write(Self.schedulerPlist(script: script, interval: 300), to: plist)
        let launchctl = RecordingLaunchctl()

        #expect(await Self.agent(root, launchctl).removeIfPresent() == .removed(.unloaded))

        #expect(launchctl.calls == [Self.bootout])
        #expect(!Self.exists(plist))
    }

    @Test func aPlistThatIsNotTheRetiredJobIsLeftAlone() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = Self.pluginScript(root)
        let skills = root.appendingPathComponent("Application Support/TBD/plugin/skills").path
        let notTheJob = [
            Self.schedulerPlist(label: "com.acme.tick", script: script),
            Self.schedulerPlist(label: "com.nightwatch-tick.2", script: script),
            Self.schedulerPlist(label: "com.Nightwatch-Tick", script: script),
            Self.schedulerPlist(script: skills + "/nightwatch/scripts/tick.py"),
            Self.schedulerPlist(script: skills + "/daywatch/scripts/tick-cron.sh"),
            Self.schedulerPlist(script: skills + "/nightwatch/scripts/tick-cron.sh.bak"),
            Self.schedulerPlist(script: skills + "/acme-nightwatch/scripts/tick-cron.sh"),
            Self.schedulerPlist(script: "tick-cron.sh"),
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
              <key>Label</key><string>com.nightwatch-tick</string>
              <key>Program</key><string>\(script)</string>
            </dict></plist>
            """,
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
              <key>ProgramArguments</key><array>
                <string>/bin/bash</string><string>\(script)</string>
              </array>
            </dict></plist>
            """,
        ]
        for contents in notTheJob {
            let plist = Self.plistURL(root)
            try Self.write(contents, to: plist)
            let launchctl = RecordingLaunchctl()

            #expect(await Self.agent(root, launchctl).removeIfPresent() == .leftAlone, "\(contents)")

            #expect(launchctl.calls.isEmpty, "\(contents)")
            #expect(try String(contentsOf: plist, encoding: .utf8) == contents)
        }
    }

    /// Bytes that are not a property list, or a property list that is not a
    /// dictionary.
    @Test func aFileThatIsNotAPlistDictionaryIsLeftAlone() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let notADictionary: [Data] = [
            Data(),
            Data("not a property list".utf8),
            Data(Self.schedulerPlist(script: Self.pluginScript(root)).prefix(120).utf8),
            Data([0xFF, 0x00, 0x13, 0x37]),
            Data("""
                <?xml version="1.0" encoding="UTF-8"?>
                <plist version="1.0"><array><string>com.nightwatch-tick</string></array></plist>
                """.utf8),
        ]
        for data in notADictionary {
            let plist = Self.plistURL(root)
            try Self.write(data, to: plist)
            let launchctl = RecordingLaunchctl()

            #expect(await Self.agent(root, launchctl).removeIfPresent() == .leftAlone)

            #expect(launchctl.calls.isEmpty)
            #expect(try Data(contentsOf: plist) == data)
        }
    }

    /// A job whose script is still on disk runs rather than fails, so it is
    /// somebody's own copy of the skill and stays.
    @Test func aJobWhoseScriptStillExistsIsLeftAlone() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plist = Self.plistURL(root)
        let script = Self.pluginScript(root)
        try Self.write("#!/bin/bash\n", to: URL(fileURLWithPath: script))
        try Self.write(Self.schedulerPlist(script: script), to: plist)
        let launchctl = RecordingLaunchctl()

        #expect(await Self.agent(root, launchctl).removeIfPresent() == .leftAlone)

        #expect(launchctl.calls.isEmpty)
        #expect(Self.exists(plist))
    }

    @Test func aSymlinkAtThePlistPathIsLeftAlone() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("elsewhere/\(RetiredLaunchAgent.plistName)")
        try Self.write(Self.schedulerPlist(script: Self.pluginScript(root)), to: target)
        let plist = Self.plistURL(root)
        try FileManager.default.createSymbolicLink(at: plist, withDestinationURL: target)
        let launchctl = RecordingLaunchctl()

        #expect(await Self.agent(root, launchctl).removeIfPresent() == .leftAlone)

        #expect(launchctl.calls.isEmpty)
        let linkType = try FileManager.default.attributesOfItem(atPath: plist.path)[.type] as? FileAttributeType
        #expect(linkType == .typeSymbolicLink)
        #expect(Self.exists(target))
    }

    @Test func noPlistRunsNothing() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let launchctl = RecordingLaunchctl()

        #expect(await Self.agent(root, launchctl).removeIfPresent() == .absent)

        #expect(launchctl.calls.isEmpty)
    }

    @Test func aMissingLaunchAgentsDirectoryIsANoOpAndIsNotCreated() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("Library/LaunchAgents")
        let launchctl = RecordingLaunchctl()
        let agent = RetiredLaunchAgent(launchAgentsDirectory: dir, userID: Self.userID, launchctl: launchctl)

        #expect(await agent.removeIfPresent() == .absent)

        #expect(launchctl.calls.isEmpty)
        #expect(!Self.exists(dir))
    }

    /// The plist goes whatever `launchctl` reports: launchd would load it again
    /// at the next login. A job that was not loaded is not a failure.
    @Test func thePlistIsRemovedWhateverLaunchctlReports() async throws {
        let cases: [(LaunchctlOutcome, RetiredLaunchAgent.Unload)] = [
            (.exited(status: 0, stderr: ""), .unloaded),
            (.exited(status: 3, stderr: "Boot-out failed: 3: No such process"), .notLoaded),
            (.exited(status: 113, stderr: "Could not find specified service"), .notLoaded),
            (.exited(status: 5, stderr: "Boot-out failed: 5: Input/output error"), .failed),
            (.exited(status: 1, stderr: ""), .failed),
            (.timedOut, .failed),
            (.failedToLaunch("launchctl is missing"), .failed),
        ]
        for (reported, unload) in cases {
            let root = try Self.makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let plist = Self.plistURL(root)
            try Self.write(Self.schedulerPlist(script: Self.pluginScript(root)), to: plist)
            let launchctl = RecordingLaunchctl(outcome: reported)

            #expect(await Self.agent(root, launchctl).removeIfPresent() == .removed(unload), "\(reported)")

            #expect(launchctl.calls == [Self.bootout])
            #expect(!Self.exists(plist), "\(reported)")
        }
    }

    @Test func otherFilesInTheDirectoryAreUntouched() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = Self.agentsDir(root)
        let retired = Self.schedulerPlist(script: Self.pluginScript(root))
        // Same contents under other names, and an unrelated agent.
        let others: [String: String] = [
            "com.nightwatch-tick.plist.bak": retired,
            "nightwatch-tick.plist": retired,
            "com.acme.agent.plist": Self.schedulerPlist(label: "com.acme.agent", script: "/opt/acme/run.sh"),
        ]
        for (name, contents) in others {
            try Self.write(contents, to: dir.appendingPathComponent(name))
        }
        try Self.write(retired, to: Self.plistURL(root))
        let launchctl = RecordingLaunchctl()

        #expect(await Self.agent(root, launchctl).removeIfPresent() == .removed(.unloaded))

        #expect(launchctl.calls == [Self.bootout])
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(Set(remaining) == Set(others.keys))
        for (name, contents) in others {
            #expect(try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) == contents)
        }
    }

    /// A plist that cannot be removed — here because its folder is read-only —
    /// is logged and reported, and the call returns normally.
    @Test func aRemovalThatFailsIsReported() async throws {
        let root = try Self.makeRoot()
        let dir = Self.agentsDir(root)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: root)
        }
        let plist = Self.plistURL(root)
        try Self.write(Self.schedulerPlist(script: Self.pluginScript(root)), to: plist)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        let launchctl = RecordingLaunchctl()

        #expect(await Self.agent(root, launchctl).removeIfPresent() == .removalFailed(.unloaded))

        #expect(launchctl.calls == [Self.bootout])
        #expect(Self.exists(plist))
    }

    @Test func theDefaultDirectoryIsTheUsersLaunchAgents() {
        #expect(RetiredLaunchAgent.defaultLaunchAgentsDirectory().path.hasSuffix("/Library/LaunchAgents"))
    }
}

/// Records each `launchctl` invocation and answers every one with `outcome`.
private final class RecordingLaunchctl: LaunchctlRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private let outcome: LaunchctlOutcome

    init(outcome: LaunchctlOutcome = .exited(status: 0, stderr: "")) {
        self.outcome = outcome
    }

    var calls: [[String]] { lock.withLock { recorded } }

    func run(_ arguments: [String]) async -> LaunchctlOutcome {
        // `withLock`, not `lock()`: NSLock.lock() is unavailable from async contexts.
        lock.withLock { recorded.append(arguments) }
        return outcome
    }
}
