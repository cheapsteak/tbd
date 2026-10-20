import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "composer-draft")

/// What a Claude spawn made with at least one session-mod feature on carries:
/// the features it was spawned with, the incarnation its `spawn.json` names,
/// and the three environment variables that tell the mod both.
struct SessionModSpawnContext: Equatable, Sendable {
    let features: [SessionModFeature]
    let incarnationID: UUID
    let environment: [String: String]
}

/// Writes the daemon's half of the per-session directory for a spawn, and
/// composes the environment the spawned Claude reads it back through.
///
/// A spawn with every feature off does nothing here: no file, no variable. A
/// spawn whose `spawn.json` cannot be written launches without the mod rather
/// than with a mod that would read a record naming nothing — the session then
/// reads as legacy, which is the behavior every session had before the mod.
enum SessionModSpawn {
    static let sessionsDirVariable = "TBD_SESSIONS_DIR"
    static let featuresVariable = "TBD_MOD_FEATURES"
    static let incarnationVariable = "TBD_TERMINAL_INCARNATION_ID"

    /// The entry point every Claude spawn site calls: derives the features
    /// from `config`, mints a fresh spawn's incarnation, and hands both to
    /// `prepare(features:claudeSessionID:incarnationID:sessionsDir:now:)`.
    ///
    /// Nil, with nothing written and nothing minted, when every feature is
    /// off — the spawn then launches exactly as it did before the mod existed.
    ///
    /// - Parameters:
    ///   - config: the config read for this spawn, or nil when reading it
    ///     failed. A nil config spawns without the mod, logged at `.notice`.
    ///   - incarnationID: the incarnation the row already persists, for a
    ///     replacement spawn. Nil for a fresh spawn, whose row does not exist
    ///     yet: one is minted only when a feature is on, and the caller writes
    ///     the returned context's `incarnationID` into the row it creates, so
    ///     the incarnation the process reports back is the one its row holds.
    static func prepare(
        config: Config?,
        claudeSessionID: String?,
        incarnationID: UUID?,
        sessionsDir: URL,
        now: Date
    ) -> SessionModSpawnContext? {
        guard let config else {
            logger.notice("""
                session mod: spawning session \(claudeSessionID ?? "nil", privacy: .public) \
                without the mod — the config could not be read
                """)
            return nil
        }
        let features = SessionModFeature.enabled(in: config)
        guard !features.isEmpty else { return nil }
        return prepare(
            features: features,
            claudeSessionID: claudeSessionID,
            incarnationID: incarnationID ?? UUID(),
            sessionsDir: sessionsDir,
            now: now)
    }

    /// The features `prepare(config:…)` would give a spawn of `claudeSessionID`
    /// — the enabled ones, or none when `config` is nil or the session ID has
    /// no safe directory — without writing anything or minting an incarnation.
    ///
    /// For a replacement spawn that must resolve its overlay before its row
    /// mints the incarnation `prepare` needs. It is a plan, not the answer:
    /// writing the spawn record can still fail, so such a spawn settles its
    /// overlay against what `prepare` returns (`ReplacementSpawnOverlay`).
    static func plannedFeatures(config: Config?, claudeSessionID: String?) -> [SessionModFeature] {
        guard let config, let claudeSessionID,
              SessionModFiles.isSafeSessionID(claudeSessionID) else { return [] }
        return SessionModFeature.enabled(in: config)
    }

    /// Writes `<sessionsDir>/<claudeSessionID>/spawn.json` for a process about
    /// to launch under `incarnationID`, and returns the variables to export.
    ///
    /// Nil, with nothing written, when `features` is empty, when the session
    /// ID is nil or not safe to use as a path component, or when the write
    /// fails (logged). Features are listed in `SessionModFeature.allCases`
    /// order, both in the file and in `TBD_MOD_FEATURES`.
    static func prepare(
        features: [SessionModFeature],
        claudeSessionID: String?,
        incarnationID: UUID,
        sessionsDir: URL,
        now: Date
    ) -> SessionModSpawnContext? {
        let ordered = SessionModFeature.allCases.filter { features.contains($0) }
        guard !ordered.isEmpty else { return nil }
        guard let claudeSessionID, SessionModFiles.isSafeSessionID(claudeSessionID) else {
            logger.notice("""
                session mod: spawning without the mod — the session ID \
                \(claudeSessionID ?? "nil", privacy: .public) has no session directory
                """)
            return nil
        }
        let names = ordered.map(\.rawValue)
        let record = SessionModFiles.SpawnRecord(
            sessionId: claudeSessionID,
            incarnationId: incarnationID.uuidString,
            spawnedAtMs: epochMilliseconds(now),
            features: names)
        do {
            try SessionModFiles.writeSpawnRecord(record, sessionsDir: sessionsDir)
        } catch {
            logger.error("""
                session mod: spawning session \(claudeSessionID, privacy: .public) without \
                the mod — writing spawn.json failed: \(error.localizedDescription, privacy: .public)
                """)
            return nil
        }
        return SessionModSpawnContext(
            features: ordered,
            incarnationID: incarnationID,
            environment: [
                sessionsDirVariable: sessionsDir.path,
                featuresVariable: names.joined(separator: ","),
                incarnationVariable: incarnationID.uuidString,
            ])
    }

    /// Follows a live process to a new session ID — what `/clear` does — so
    /// the mod's writes under the new ID read as this process's, not legacy.
    ///
    /// Acts only when the old directory's `spawn.json` names `liveIncarnationID`:
    /// a record from an earlier process says nothing about this one. Writes the
    /// new ID's `spawn.json` with the same incarnation and features; touches
    /// nothing else in either directory. Failures are logged.
    static func carryForward(
        fromSessionID: String,
        toSessionID: String,
        liveIncarnationID: UUID?,
        sessionsDir: URL,
        now: Date
    ) {
        guard fromSessionID != toSessionID,
              let liveIncarnationID,
              SessionModFiles.isSafeSessionID(toSessionID),
              let fromDirectory = SessionModFiles.directory(
                sessionsDir: sessionsDir, claudeSessionID: fromSessionID) else { return }
        let read = SessionModFiles.read(
            SessionModFiles.SpawnRecord.self,
            at: fromDirectory.appendingPathComponent(SessionModFiles.spawnFileName))
        guard case .record(let previous) = read,
              UUID(uuidString: previous.incarnationId) == liveIncarnationID else { return }
        let record = SessionModFiles.SpawnRecord(
            sessionId: toSessionID,
            incarnationId: liveIncarnationID.uuidString,
            spawnedAtMs: epochMilliseconds(now),
            features: previous.features)
        do {
            try SessionModFiles.writeSpawnRecord(record, sessionsDir: sessionsDir)
            logger.info("""
                session mod: carried spawn.json from session \(fromSessionID, privacy: .public) \
                to \(toSessionID, privacy: .public)
                """)
        } catch {
            logger.error("""
                session mod: carrying spawn.json from session \(fromSessionID, privacy: .public) \
                to \(toSessionID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)
                """)
        }
    }

    private static func epochMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

extension Dictionary where Key == String, Value == String {
    /// This launch environment with the session mod's variables added, the
    /// mod's winning on a collision; unchanged when `context` is nil. The same
    /// precedence `ClaudeSpawnCommandBuilder` gives the variables it is handed,
    /// for the replacement spawns that compose their command before they know
    /// their incarnation.
    func addingSessionMod(_ context: SessionModSpawnContext?) -> [String: String] {
        guard let context else { return self }
        return merging(context.environment) { _, mod in mod }
    }
}
