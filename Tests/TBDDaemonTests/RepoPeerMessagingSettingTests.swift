import Foundation
import os
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

/// `[remote_sessions] peer_messaging` in a repository's committed `tbd.toml` —
/// the per-repository switch for remote peer messaging
/// (`docs/specs/2026-08-29-remote-peer-messaging-design.md`, "The
/// per-repository switch").
///
/// Only `true` turns it on. Absent is off, and anything TBD cannot understand
/// is off **and** reported, because sharing sessions across machines must never
/// happen by accident.
///
/// Tier 1 for the pure parse and the stream decision; the file-reading cases
/// write into a temp directory, never a real checkout or `~/tbd`.
@Suite("Repo peer-messaging setting")
struct RepoPeerMessagingSettingTests {

    private static let path = "/opt/peertest/acme/tbd.toml"

    private static func parse(_ text: String) -> PeerMessagingSetting {
        PeerMessagingSetting.parse(text, path: path)
    }

    // MARK: - Parsing

    @Test func trueTurnsItOn() {
        let setting = Self.parse("[remote_sessions]\npeer_messaging = true\n")
        #expect(setting.enabled)
        #expect(setting.problems.isEmpty)
        #expect(setting.path == Self.path)
    }

    @Test func falseTurnsItOff() {
        let setting = Self.parse("[remote_sessions]\npeer_messaging = false\n")
        #expect(setting.enabled == false)
        #expect(setting.problems.isEmpty, "an explicit false is an answer, not a problem")
    }

    /// The dev-server half of the same file is no opinion about this one.
    @Test func anAbsentTableIsOffWithNoProblem() {
        let setting = Self.parse("[servers.web]\ncommand = \"npm run dev\"\n")
        #expect(setting.enabled == false)
        #expect(setting.problems.isEmpty)
    }

    @Test func anAbsentKeyIsOffWithNoProblem() {
        let setting = Self.parse("[remote_sessions]\nsomething_else = 1\n")
        #expect(setting.enabled == false)
        #expect(setting.problems.isEmpty)
    }

    @Test func anEmptyFileIsOffWithNoProblem() {
        let setting = Self.parse("")
        #expect(setting.enabled == false)
        #expect(setting.problems.isEmpty)
    }

    /// `"true"` is a string, not a boolean. Reading it as on would be the one
    /// lenient guess that shares sessions nobody agreed to share.
    @Test(arguments: ["\"true\"", "1", "\"yes\"", "[true]"])
    func aValueThatIsNotABooleanIsOffAndReported(value: String) {
        let setting = Self.parse("[remote_sessions]\npeer_messaging = \(value)\n")
        #expect(setting.enabled == false)
        #expect(setting.problems.count == 1)
        #expect(setting.problems.first?.contains("must be true or false") == true)
    }

    @Test func aRemoteSessionsThatIsNotATableIsOffAndReported() {
        let setting = Self.parse("remote_sessions = true\n")
        #expect(setting.enabled == false)
        #expect(setting.problems.count == 1)
        #expect(setting.problems.first?.contains("must be a table") == true)
    }

    @Test func aSyntaxErrorIsOffAndReported() {
        let setting = Self.parse("[remote_sessions\npeer_messaging = true\n")
        #expect(setting.enabled == false)
        #expect(setting.problems.count == 1)
        #expect(setting.problems.first?.contains("not valid TOML") == true)
    }

    // MARK: - Reading the file

    private static func makeCheckout() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("repo-toml-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func anAbsentFileIsOffWithNoProblem() throws {
        let checkout = try Self.makeCheckout()
        defer { try? FileManager.default.removeItem(at: checkout) }

        let setting = PeerMessagingSetting.read(checkoutPath: checkout.path)

        #expect(setting.enabled == false)
        #expect(setting.problems.isEmpty)
        #expect(setting.path == checkout.appendingPathComponent("tbd.toml").path)
    }

    @Test func theFileInTheCheckoutRootIsRead() throws {
        let checkout = try Self.makeCheckout()
        defer { try? FileManager.default.removeItem(at: checkout) }
        try "[remote_sessions]\npeer_messaging = true\n".write(
            to: checkout.appendingPathComponent("tbd.toml"), atomically: true, encoding: .utf8)

        #expect(PeerMessagingSetting.read(checkoutPath: checkout.path).enabled)
    }

    @Test func aFileThatIsNotUTF8IsOffAndReported() throws {
        let checkout = try Self.makeCheckout()
        defer { try? FileManager.default.removeItem(at: checkout) }
        try Data([0xFF, 0xFE, 0x00, 0xC3]).write(to: checkout.appendingPathComponent("tbd.toml"))

        let setting = PeerMessagingSetting.read(checkoutPath: checkout.path)

        #expect(setting.enabled == false)
        #expect(setting.problems.count == 1)
    }

    /// The dev-server parser and the switch read the same file.
    @Test func bothReadersNameTheSameFile() {
        #expect(DevServerDeclarationParser.repoTOMLFileName == RepoTOML.fileName)
        #expect(RepoTOML.fileName == "tbd.toml")
    }

    // MARK: - Logging problems

    /// A malformed file is read on every poll, scope tick and resolver call,
    /// so its problems are logged when they change and once when they clear —
    /// never on every read.
    @Test func problemsAreLoggedOnlyWhenTheyChange() {
        let log = PeerMessagingProblemLog()
        let broken = PeerMessagingSetting(path: Self.path, enabled: false, problems: ["bad"])
        let worse = PeerMessagingSetting(path: Self.path, enabled: false, problems: ["worse"])
        let clean = PeerMessagingSetting(path: Self.path, enabled: true, problems: [])

        #expect(log.report(clean) == false, "a clean file is never logged")
        #expect(log.report(broken))
        #expect(log.report(broken) == false, "the same problem is not logged again")
        #expect(log.report(worse), "a changed problem is logged")
        #expect(log.report(clean), "clearing is logged once")
        #expect(log.report(clean) == false)
        #expect(log.report(PeerMessagingSetting(
            path: "/opt/peertest/other/tbd.toml", enabled: false, problems: ["bad"])),
            "each file is tracked on its own")
    }

    /// Deduplicating the log never hides a problem from the reader: every read
    /// still returns it, which is what `tbd peer list` prints.
    @Test func everyReadStillReturnsTheProblems() {
        let switches = RepoPeerMessagingSwitches(
            repo: { _ in nil },
            read: { PeerMessagingSetting(path: $0, enabled: false, problems: ["bad"]) })

        #expect(switches.setting(checkoutPath: "/opt/peertest/acme").problems == ["bad"])
        #expect(switches.setting(checkoutPath: "/opt/peertest/acme").problems == ["bad"])
    }

    // MARK: - Which checkout counts

    /// The switch is read from the repository's registered main checkout — the
    /// repo row's path — and from nothing else.
    @Test func theRepositoryRowsPathIsTheCheckoutRead() async throws {
        let repo = Repo(path: "/opt/peertest/acme", displayName: "acme")
        let asked = OSAllocatedUnfairLock(initialState: [String]())
        let switches = RepoPeerMessagingSwitches(
            repo: { $0 == repo.id ? repo : nil },
            read: { path in
                asked.withLock { $0.append(path) }
                return PeerMessagingSetting(path: path + "/tbd.toml", enabled: true, problems: [])
            })

        #expect(try await switches.isOn(repoID: repo.id))
        #expect(asked.withLock { $0 } == ["/opt/peertest/acme"])
        #expect(try await switches.isOn(repoID: UUID()) == false,
                "a repository TBD has no row for is off")
    }

    // MARK: - When the messages stream opens

    private static func lane(repoID: UUID?, provider: String?) -> Worktree {
        let location: WorktreeLocation = provider.map {
            .remote(provider: $0, sessionID: UUID().uuidString)
        } ?? .local
        let name = "lane-\(UUID().uuidString.prefix(6))"
        return Worktree(
            repoID: repoID, name: name, displayName: name, branch: "tbd/\(name)",
            path: location.storagePath ?? "/opt/peertest/\(name)",
            tmuxServer: "tbd-gate-fixture", location: location)
    }

    @Test func aProviderWithNoReposOpensNoStream() async {
        let open = await PeerMessagingStreamGate.shouldOpenStream(
            provider: "cloud", worktrees: [], repoIsOn: { _ in true })
        #expect(open == false)
    }

    @Test func aProviderWhoseReposAreAllOffOpensNoStream() async {
        let rows = [Self.lane(repoID: UUID(), provider: "cloud"),
                    Self.lane(repoID: UUID(), provider: "cloud")]
        let open = await PeerMessagingStreamGate.shouldOpenStream(
            provider: "cloud", worktrees: rows, repoIsOn: { _ in false })
        #expect(open == false)
    }

    @Test func oneSwitchedOnRepoOpensTheStream() async {
        let on = UUID()
        let rows = [Self.lane(repoID: UUID(), provider: "cloud"),
                    Self.lane(repoID: on, provider: "cloud")]
        let open = await PeerMessagingStreamGate.shouldOpenStream(
            provider: "cloud", worktrees: rows, repoIsOn: { $0 == on })
        #expect(open)
    }

    /// Another provider's switched-on repository — and a purely local worktree
    /// in it — open nothing for this one.
    @Test func anotherProvidersSwitchedOnRepoOpensNoStreamForThisOne() async {
        let mine = UUID()
        let theirs = UUID()
        let rows = [Self.lane(repoID: mine, provider: "cloud"),
                    Self.lane(repoID: theirs, provider: "other"),
                    Self.lane(repoID: theirs, provider: nil)]
        let isOn: @Sendable (UUID) -> Bool = { $0 == theirs }

        #expect(await PeerMessagingStreamGate.shouldOpenStream(
            provider: "cloud", worktrees: rows, repoIsOn: isOn) == false)
        #expect(await PeerMessagingStreamGate.shouldOpenStream(
            provider: "other", worktrees: rows, repoIsOn: isOn))
    }
}
