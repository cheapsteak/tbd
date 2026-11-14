import Darwin
import Foundation
import GRDB
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

/// Which emulator a holder-backed session's reader gets, from the
/// `ghostty_daemon_emulator_enabled` flag to the emulator built.
///
/// Each branch of the flag has a test: off gives the SwiftTerm emulator, on
/// gives the libghostty one, and unset or unreadable follows the shipped
/// default. The
/// resolver is the one the daemon hands its registry, read against a real
/// in-memory database. Design: `docs/specs/2026-11-13-swiftterm-retirement-design.md`
/// ("The flag", "Testing").
@Suite struct HolderEmulatorKindTests {

    // MARK: - The flag picks the kind

    @Test func theFlagOffPicksSwiftTerm() {
        #expect(HolderEmulatorKind(ghosttyDaemonEmulatorEnabled: false) == .swiftTerm)
    }

    @Test func theFlagOnPicksLibghostty() {
        #expect(HolderEmulatorKind(ghosttyDaemonEmulatorEnabled: true) == .ghostty)
    }

    /// Nobody has chosen, so the column is NULL and the kind is the one the
    /// shipped default picks. Pinned against the constant rather than a kind,
    /// so the flip changes this test's answer without changing the test.
    @Test func anUnsetFlagFollowsTheShippedDefault() async throws {
        let db = try TBDDatabase(inMemory: true)
        #expect(
            await HolderEmulatorKind.configured(by: db.config)
                == HolderEmulatorKind(ghosttyDaemonEmulatorEnabled: Config.ghosttyDaemonEmulatorDefault))
    }

    /// An explicit choice in either direction reaches the registry, in the
    /// order it was made.
    @Test func anExplicitChoiceIsTheKindTheDaemonReads() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGhosttyDaemonEmulator(true)
        #expect(await HolderEmulatorKind.configured(by: db.config) == .ghostty)
        try await db.config.setGhosttyDaemonEmulator(false)
        #expect(await HolderEmulatorKind.configured(by: db.config) == .swiftTerm)
    }

    /// A read that fails costs the flag, never the reader: the kind is the
    /// one the shipped default picks. The table goes after a choice against
    /// the default was stored, so a stored value that somehow survived would
    /// give the other kind.
    @Test func anUnreadableFlagTakesTheShippedDefault() async throws {
        let db = try TBDDatabase(inMemory: true)
        let chosen = !Config.ghosttyDaemonEmulatorDefault
        try await db.config.setGhosttyDaemonEmulator(chosen)
        #expect(
            await HolderEmulatorKind.configured(by: db.config)
                == HolderEmulatorKind(ghosttyDaemonEmulatorEnabled: chosen),
            "the choice never reached the resolver, so the fallback below proves nothing")

        try await db.writerForTests.write { try $0.execute(sql: "DROP TABLE config") }
        await #expect(throws: (any Error).self, "the config read still works") {
            try await db.config.get()
        }

        #expect(
            await HolderEmulatorKind.configured(by: db.config)
                == HolderEmulatorKind(ghosttyDaemonEmulatorEnabled: Config.ghosttyDaemonEmulatorDefault))
    }

    // MARK: - The kind builds its emulator

    /// Each kind builds the emulator it names, and that emulator parses: the
    /// SwiftTerm one waits for a sequence boundary before a snapshot, and the
    /// libghostty one, at ground, does not.
    @Test(arguments: HolderEmulatorKind.allCases)
    func eachKindBuildsItsOwnEmulator(kind: HolderEmulatorKind) {
        let emulator = Self.build(kind)
        #expect(emulator.kind == kind)
        #expect(emulator.snapshotNeedsSequenceBoundary == (kind == .swiftTerm))
        emulator.feed(Array("hello".utf8)[...])
        #expect(emulator.renderScreen() == "hello")
    }

    /// libghostty that cannot make a terminal still leaves the session an
    /// emulator: the SwiftTerm one, which says so through its `kind`.
    @Test func libghosttyThatCannotMakeATerminalFallsBackToSwiftTerm() {
        let emulator = Self.build(.ghostty, ghosttyTerminalFails: true)
        #expect(emulator.kind == .swiftTerm)
        #expect(emulator.snapshotNeedsSequenceBoundary)
        emulator.feed(Array("hello".utf8)[...])
        #expect(emulator.renderScreen() == "hello")
    }

    /// The reader reports the kind it was built with, without a hop onto its
    /// actor.
    @Test(arguments: HolderEmulatorKind.allCases)
    func theReaderReportsItsEmulatorKind(kind: HolderEmulatorKind) throws {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[1]) }
        // The reader owns `pair[0]` and its `deinit` closes it, which is safe
        // because the reader is never started.
        let reader = HolderReader(
            sessionID: UUID(), ptyFD: pair[0], columns: 40, rows: 8,
            emulator: kind, observedChildFromStart: true)
        #expect(reader.emulatorKind == kind)
    }

    // MARK: - Support

    private struct FactoryFailure: Error {}

    /// Builds `kind`'s emulator, through the production factory or, with
    /// `ghosttyTerminalFails`, through one that throws.
    private static func build(_ kind: HolderEmulatorKind, ghosttyTerminalFails: Bool = false) -> any HolderEmulator {
        guard ghosttyTerminalFails else {
            return kind.makeEmulator(
                sessionID: UUID(), columns: 40, rows: 8, scrollback: 100,
                observedChildFromStart: true, monotonicNow: { ContinuousClock.now },
                programStatus: nil, reply: { _ in })
        }
        return kind.makeEmulator(
            sessionID: UUID(), columns: 40, rows: 8, scrollback: 100,
            observedChildFromStart: true, monotonicNow: { ContinuousClock.now },
            programStatus: nil, reply: { _ in },
            makeGhosttyTerminal: { _, _, _, _ in throw FactoryFailure() })
    }
}
