import Foundation
import Testing
@testable import TBDDaemonLib

/// The real, non-dryRun `paneSendProbe`/`paneOwnership` path when `runTmux`
/// cannot resolve a `tmux` binary at all.
///
/// `runTmux`'s synthetic status-127 "tmux executable is unavailable" failure
/// has the same shape as tmux itself exiting non-zero, and `paneSendProbe`'s
/// catch classifies a non-zero exit as `.absent` or `.unreachable`. A probe
/// that never ran must be neither: it throws, and `paneOwnership` reads that
/// as `.unverifiable`, so no teardown is permitted on it.
/// These exercise the REAL `runTmux` → `tmuxPath()` failure, not a `dryRun`
/// stand-in, via `TmuxManager.tmuxPathOverride`: an empty directory with no
/// saved fallback configured, so `tmuxPath()` fails resolution exactly the
/// way it does in production when the daemon's inherited PATH has no tmux.
@Suite("Pane send-target probe: tmux binary unavailable")
struct PaneSendTargetUnavailableExecutableTests {
    /// A directory guaranteed to contain no `tmux` executable, used as the
    /// `PATH` `runTmux` resolves against. No configuration file is written
    /// under it, so the saved-executable fallback misses too.
    private func pathWithNoTmux() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaneSendTargetUnavailableExecutableTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("paneSendProbe throws, rather than classifying a verdict, when tmux cannot be resolved")
    func paneSendProbeThrowsRatherThanClassifying() async throws {
        let directory = try pathWithNoTmux()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tmux = TmuxManager(dryRun: false, tmuxPathOverride: directory.path)

        await #expect(throws: TmuxError.self) {
            _ = try await tmux.paneSendTarget(server: "tbd-acme", paneID: "%7")
        }
    }

    @Test("the thrown failure really is runTmux's own status-127 synthetic error")
    func thrownFailureCarriesStatus127() async throws {
        let directory = try pathWithNoTmux()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tmux = TmuxManager(dryRun: false, tmuxPathOverride: directory.path)

        do {
            _ = try await tmux.paneSendTarget(server: "tbd-acme", paneID: "%7")
            Issue.record("expected paneSendTarget to throw when tmux cannot be resolved")
        } catch let TmuxError.commandFailed(_, status, output) {
            #expect(status == 127)
            #expect(output == "tmux executable is unavailable")
        } catch {
            Issue.record("expected TmuxError.commandFailed, got \(error)")
        }
    }

    @Test("paneOwnership reports .unverifiable, not .owned, when tmux cannot be resolved")
    func paneOwnershipIsUnverifiableWhenTmuxCannotBeResolved() async throws {
        let directory = try pathWithNoTmux()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tmux = TmuxManager(dryRun: false, tmuxPathOverride: directory.path)

        let ownership = await tmux.paneOwnership(
            terminalID: UUID(), server: "tbd-acme", paneID: "%7")

        guard case .unverifiable = ownership else {
            Issue.record("expected .unverifiable, got \(ownership) — a teardown would fail open")
            return
        }
        #expect(!ownership.permitsTeardown)
    }
}

/// How `paneOwnership` reads each `PaneSendTarget` verdict. Only positive
/// evidence permits a teardown: a pane that answers with this terminal's id,
/// no id, or a reachable server reporting it `.absent`. A server that could not
/// be reached (`.unreachable`) says nothing about who owns the pane.
@Suite("Pane ownership: verdict mapping")
struct PaneOwnershipVerdictTests {
    private func ownership(
        for target: PaneSendTarget, terminalID: UUID = UUID()
    ) async -> PaneOwnership {
        let tmux = TmuxManager(dryRun: true, dryRunPaneSendTarget: { _, _ in target })
        return await tmux.paneOwnership(terminalID: terminalID, server: "tbd-acme", paneID: "%7")
    }

    @Test("an unreachable server is .unverifiable and refuses the teardown")
    func unreachableIsUnverifiable() async {
        let result = await ownership(for: .unreachable)
        guard case .unverifiable = result else {
            Issue.record("expected .unverifiable, got \(result) — a teardown would fail open")
            return
        }
        #expect(!result.permitsTeardown)
    }

    @Test("an absent pane is .owned and permits the teardown")
    func absentIsOwned() async {
        #expect(await ownership(for: .absent) == .owned)
    }

    @Test("an unstamped live pane is .owned")
    func unstampedIsOwned() async {
        #expect(await ownership(for: .live(terminalID: nil)) == .owned)
    }

    @Test("a dead pane stamped by another terminal is .ownedByAnother")
    func strangerDeadPaneIsOwnedByAnother() async {
        let other = UUID().uuidString
        let result = await ownership(for: .dead(terminalID: other))
        #expect(result == .ownedByAnother(terminalID: other))
        #expect(!result.permitsTeardown)
    }
}
