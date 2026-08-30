import Testing
import Foundation
@testable import TBDShared

/// Record-shape and atomic-write tests for shadow peers
/// (docs/specs/2026-08-29-remote-peer-messaging-design.md § "Shadow peer
/// lifecycle").
///
/// The key-set assertions here are **whitelists on composed output**, not spot
/// checks for a few keys, and that is the point of them rather than a style
/// preference: a record carrying one key Claude Code does not define survives
/// on disk and is silently absent from every listing (measured). A test that
/// asserted only "the keys we need are present" would pass on the exact defect
/// that makes every shadow invisible.
///
/// Nothing here touches `~/.claude`: every store is constructed with an
/// explicit directory URL, and the `environment:` seam is exercised with a
/// dictionary rather than by mutating the process environment.
private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tbd-shadow-peer-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}

/// A record composed the way the helper composes one, with every value
/// distinguishable so an assertion can tell which field it landed in.
private func sampleRecord(
    pid: pid_t = 4242,
    status: String = "busy",
    version: String? = nil
) -> ShadowPeerRecord {
    ShadowPeerRecord(
        pid: pid,
        procStart: "Sat Aug 29 22:07:57 2026",
        messagingSocketPath: "/tmp/cc-socks-test/\(pid).sock",
        name: "acme:useful-swallow",
        status: status,
        peerProtocol: 1,
        cwd: "/tmp/tbd-shadow-cwd",
        sessionID: "4E12DD65-92B8-4D8E-9920-214C6553FC63",
        startedAt: Date(timeIntervalSince1970: 1_788_041_297.648),
        version: version)
}

private func encodedObject(_ record: ShadowPeerRecord) throws -> [String: Any] {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(record)
    let object = try JSONSerialization.jsonObject(with: data)
    return try #require(object as? [String: Any])
}

@Suite("Shadow peer record shape")
struct ShadowPeerRecordShapeTests {
    /// The complete key set, written out. Adding a key to the record without
    /// adding it here fails this test — which is the only cheap moment to catch
    /// a change that would otherwise present as "shadows stopped listing" with
    /// no error anywhere.
    private let expectedKeys: Set<String> = [
        "pid",
        "sessionId",
        "cwd",
        "startedAt",
        "procStart",
        "peerProtocol",
        "peerFeatures",
        "kind",
        "entrypoint",
        "pidDomain",
        "messagingSocketPath",
        "name",
        "nameSource",
        "status",
    ]

    @Test("a composed record carries exactly these keys and no others")
    func composedKeySetIsComplete() throws {
        let object = try encodedObject(sampleRecord())
        #expect(Set(object.keys) == expectedKeys)
    }

    @Test("every composed key is one Claude Code itself defines")
    func composedKeysAreASubsetOfTheDefinedShape() throws {
        let object = try encodedObject(sampleRecord())
        let undefined = Set(object.keys).subtracting(ShadowPeerRecord.claudeCodeDefinedKeys)
        #expect(undefined.isEmpty)
    }

    /// The one absence the design states as a MUST NOT. Remote tmux coordinates
    /// would collide with local pane ids and produce a row that looks joinable
    /// but joins to the wrong terminal.
    @Test("no tmux key, on any composed record")
    func noTmuxKey() throws {
        for status in ["idle", "busy", "waiting", "shell"] {
            let object = try encodedObject(sampleRecord(status: status, version: "2.1.251"))
            #expect(object["tmux"] == nil)
        }
    }

    /// A shadow has no session on Anthropic's hosted relay, so it claims none.
    @Test("no bridgeSessionId, even though Claude Code defines one")
    func noBridgeSessionID() throws {
        let object = try encodedObject(sampleRecord(version: "2.1.251"))
        #expect(object["bridgeSessionId"] == nil)
        #expect(ShadowPeerRecord.claudeCodeDefinedKeys.contains("bridgeSessionId"))
    }

    /// `version` is the one optional key, and the difference it makes to the
    /// key set is exactly itself.
    @Test("version is omitted when absent and present when supplied")
    func versionIsTheOnlyOptionalKey() throws {
        let without = Set(try encodedObject(sampleRecord()).keys)
        let with = Set(try encodedObject(sampleRecord(version: "2.1.251")).keys)
        #expect(without == expectedKeys)
        #expect(with == expectedKeys.union(["version"]))
        #expect(try encodedObject(sampleRecord(version: "2.1.251"))["version"] as? String
            == "2.1.251")
    }

    /// v1's bridge forwards message frames and nothing else, so it advertises
    /// nothing. Present-and-empty, not absent: the key is one Claude Code
    /// defines and every live record carries it.
    @Test("peerFeatures is present and empty")
    func peerFeaturesIsEmpty() throws {
        #expect(ShadowPeerRecord.bridgedPeerFeatures.isEmpty)
        let object = try encodedObject(sampleRecord())
        let features = try #require(object["peerFeatures"] as? [String])
        #expect(features.isEmpty)
    }

    @Test("the values TBD stamps are the local ones")
    func stampedValues() throws {
        let object = try encodedObject(sampleRecord())
        #expect(object["pidDomain"] as? String == "darwin")
        #expect(object["kind"] as? String == "interactive")
        #expect(object["entrypoint"] as? String == "cli")
        #expect(object["nameSource"] as? String == "user")
    }

    @Test("the values the far side supplies land where they belong")
    func suppliedValues() throws {
        let object = try encodedObject(sampleRecord())
        #expect(object["pid"] as? Int == 4242)
        #expect(object["name"] as? String == "acme:useful-swallow")
        #expect(object["status"] as? String == "busy")
        #expect(object["peerProtocol"] as? Int == 1)
        #expect(object["procStart"] as? String == "Sat Aug 29 22:07:57 2026")
        #expect(object["sessionId"] as? String == "4E12DD65-92B8-4D8E-9920-214C6553FC63")
        #expect(object["cwd"] as? String == "/tmp/tbd-shadow-cwd")
        #expect(object["messagingSocketPath"] as? String == "/tmp/cc-socks-test/4242.sock")
    }

    /// `startedAt` is milliseconds since the epoch on every live record.
    @Test("startedAt is milliseconds since the epoch")
    func startedAtIsMilliseconds() throws {
        let object = try encodedObject(sampleRecord())
        #expect(object["startedAt"] as? Int == 1_788_041_297_648)
    }

    /// The helper rewrites its record on every status change, and a rewrite
    /// that changed anything else would republish the peer under a new
    /// identity each time the far side went from idle to busy.
    @Test("withStatus changes the status and nothing else")
    func withStatusChangesOnlyTheStatus() throws {
        let original = sampleRecord(status: "idle", version: "2.1.251")
        let updated = original.withStatus("busy")
        #expect(updated.status == "busy")
        #expect(updated == ShadowPeerRecord(
            pid: original.pid,
            procStart: original.procStart,
            messagingSocketPath: original.messagingSocketPath,
            name: original.name,
            status: "busy",
            peerProtocol: original.peerProtocol,
            cwd: original.cwd,
            sessionID: original.sessionID,
            startedAt: Date(timeIntervalSince1970:
                Double(original.startedAtMilliseconds) / 1000),
            version: original.version))
        #expect(try Set(encodedObject(updated).keys) == Set(encodedObject(original).keys))
    }

    @Test("a written record decodes back to the same value")
    func roundTrips() throws {
        let record = sampleRecord(version: "2.1.251")
        let data = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(ShadowPeerRecord.self, from: data) == record)
    }
}

@Suite("Shadow peer record store")
struct ShadowPeerRecordStoreTests {
    /// The loader parses the pid out of the filename and rejects one that does
    /// not round-trip as an integer, so the name is the bare pid.
    @Test("a record is filed under its own pid")
    func recordIsNamedForItsPID() throws {
        let store = ShadowPeerRecordStore(
            sessionsDirectory: URL(fileURLWithPath: "/tmp/does-not-matter"))
        #expect(store.recordURL(pid: 4242).lastPathComponent == "4242.json")
    }

    @Test("writing publishes the record where a reader will find it")
    func writePublishes() throws {
        try withTemporaryDirectory { directory in
            let store = ShadowPeerRecordStore(sessionsDirectory: directory)
            let record = sampleRecord()
            try store.write(record)

            let url = directory.appendingPathComponent("4242.json")
            #expect(FileManager.default.fileExists(atPath: url.path))
            let decoded = try JSONDecoder().decode(
                ShadowPeerRecord.self, from: Data(contentsOf: url))
            #expect(decoded == record)
            #expect(try store.read(pid: 4242) == record)
        }
    }

    /// The write is a rename over the target, and the temp it renames from must
    /// be gone afterwards — an accumulating temp in a directory every session on
    /// the machine reads is the leak shape this repo keeps finding.
    @Test("writing leaves no temporary behind, on a first write or a rewrite")
    func writeLeavesNoTemporary() throws {
        try withTemporaryDirectory { directory in
            let store = ShadowPeerRecordStore(sessionsDirectory: directory)
            try store.write(sampleRecord(status: "idle"))
            try store.write(sampleRecord(status: "busy"))
            try store.write(sampleRecord(status: "waiting"))

            let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(entries == ["4242.json"])
            #expect(try store.read(pid: 4242)?.status == "waiting")
        }
    }

    /// A reader never sees a torn record: the bytes are complete under the
    /// final name from the instant the name exists. What this can assert
    /// without racing a reader is the mechanism — the temp is a sibling in the
    /// same directory (so `rename(2)` is atomic rather than a cross-volume
    /// copy), and its name is one the registry loader will not read as a
    /// record.
    @Test("the write-temp is a same-directory sibling the loader ignores")
    func temporaryIsASiblingTheLoaderIgnores() throws {
        try withTemporaryDirectory { directory in
            let store = ShadowPeerRecordStore(sessionsDirectory: directory)
            let destination = store.recordURL(pid: 4242)
            let temporary = store.temporaryURL(for: destination)

            #expect(temporary.deletingLastPathComponent().path == directory.path)
            #expect(temporary.lastPathComponent.hasPrefix("."))
            #expect(temporary.pathExtension == "tmp")
            // The loader parses `<stem>.json`; this stem is not an integer and
            // the extension is not `json`, so a temp caught mid-write lists
            // nothing.
            #expect(Int(temporary.deletingPathExtension().lastPathComponent) == nil)
        }
    }

    /// **The creating side and the reclaiming side must recognise the same
    /// files.** `write` composes the temp's name; `ShadowPeerReconciler`
    /// reclaims the ones a death mid-write stranded, and it finds them through
    /// `temporaryFiles(forRecordAt:)`. If the two ever drifted apart the temps
    /// would go uncollected in silence — the leading dot keeps them out of
    /// every glob, and the registry loader reads `<int>.json` and nothing else.
    /// So the round trip is asserted rather than assumed.
    @Test("a write-temp is recognisable as one, for its own record only")
    func aWriteTempIsRecognisedByTheReclaimingSide() throws {
        try withTemporaryDirectory { directory in
            let store = ShadowPeerRecordStore(sessionsDirectory: directory)
            let destination = store.recordURL(pid: 4242)
            let temporary = store.temporaryURL(for: destination)

            #expect(ShadowPeerRecordStore.isTemporaryFileName(
                temporary.lastPathComponent, forRecordNamed: "4242.json"))
            // A neighbour's temp, the record itself, and a bare `.tmp` are all
            // somebody else's business.
            #expect(!ShadowPeerRecordStore.isTemporaryFileName(
                temporary.lastPathComponent, forRecordNamed: "4243.json"))
            #expect(!ShadowPeerRecordStore.isTemporaryFileName(
                "4242.json", forRecordNamed: "4242.json"))
            #expect(!ShadowPeerRecordStore.isTemporaryFileName(
                ".4242.json.tmp", forRecordNamed: "4242.json"))
        }
    }

    /// The listing the reclaimer walks: every temp for one record, and nothing
    /// else in a directory shared with every session on the machine.
    @Test("stranded write-temps are listed for their own record and no other")
    func strandedTemporariesAreListedPerRecord() throws {
        try withTemporaryDirectory { directory in
            let store = ShadowPeerRecordStore(sessionsDirectory: directory)
            let destination = store.recordURL(pid: 4242)
            let mine = [store.temporaryURL(for: destination),
                        store.temporaryURL(for: destination)]
            let neighbour = store.temporaryURL(for: store.recordURL(pid: 4243))
            for url in mine + [neighbour, destination] {
                #expect(FileManager.default.createFile(atPath: url.path, contents: Data()))
            }

            let found = ShadowPeerRecordStore.temporaryFiles(forRecordAt: destination.path)

            #expect(Set(found.map(\.lastPathComponent))
                == Set(mine.map(\.lastPathComponent)))
            #expect(found == found.sorted { $0.path < $1.path }, "a stable order, so a log reads the same way twice")
        }
    }

    /// A directory with nothing in it, and one that is not there at all, both
    /// list nothing rather than throwing: a sweep must not die on a registry
    /// directory that has yet to be created.
    @Test("listing write-temps tolerates an absent directory")
    func listingTemporariesToleratesAnAbsentDirectory() {
        #expect(ShadowPeerRecordStore.temporaryFiles(
            forRecordAt: "/tmp/tbd-no-such-directory-\(UUID().uuidString)/4242.json").isEmpty)
    }

    @Test("two writes to the same pid produce different temporaries")
    func temporariesAreUnique() throws {
        let store = ShadowPeerRecordStore(
            sessionsDirectory: URL(fileURLWithPath: "/tmp/does-not-matter"))
        let destination = store.recordURL(pid: 4242)
        #expect(store.temporaryURL(for: destination) != store.temporaryURL(for: destination))
    }

    @Test("writing creates the registry directory when it is absent")
    func writeCreatesTheDirectory() throws {
        try withTemporaryDirectory { directory in
            let sessions = directory.appendingPathComponent("sessions", isDirectory: true)
            let store = ShadowPeerRecordStore(sessionsDirectory: sessions)
            try store.write(sampleRecord())

            #expect(FileManager.default.fileExists(atPath: sessions.path))
            let attributes = try FileManager.default.attributesOfItem(atPath: sessions.path)
            #expect(attributes[.posixPermissions] as? Int
                == ShadowPeerRecordStore.directoryPermissions)
        }
    }

    @Test("removing unlinks the record, and removing an absent one is not an error")
    func removeUnlinks() throws {
        try withTemporaryDirectory { directory in
            let store = ShadowPeerRecordStore(sessionsDirectory: directory)
            try store.write(sampleRecord())
            try store.remove(pid: 4242)
            #expect(!FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("4242.json").path))
            #expect(try store.read(pid: 4242) == nil)
            try store.remove(pid: 4242)  // idempotent
        }
    }

    @Test("reading an absent record is nil, and a malformed one throws")
    func readReportsMalformedRecords() throws {
        try withTemporaryDirectory { directory in
            let store = ShadowPeerRecordStore(sessionsDirectory: directory)
            #expect(try store.read(pid: 4242) == nil)

            try Data("not json".utf8).write(
                to: directory.appendingPathComponent("4242.json"))
            #expect(throws: ShadowPeerRecordStoreError.self) {
                _ = try store.read(pid: 4242)
            }
        }
    }

    /// The injected seam, and the environment override behind it. Neither
    /// branch touches a real store: both are path computations.
    @Test("the registry directory follows TBD_CLAUDE_HOST_HOME")
    func registryDirectoryFollowsTheHostHomeOverride() throws {
        let overridden = ShadowPeerRecordStore(
            environment: ["TBD_CLAUDE_HOST_HOME": "/tmp/tbd-fake-claude"])
        #expect(overridden.sessionsDirectory.path == "/tmp/tbd-fake-claude/sessions")

        let production = ShadowPeerRecordStore(environment: [:])
        #expect(production.sessionsDirectory.path
            == FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/sessions").path)
    }
}

@Suite("Process start time")
struct ProcessStartTimeTests {
    /// `procStart`'s shape is `ctime(3)`'s: exactly 24 characters, with the day
    /// of month space-padded. A `DateFormatter` cannot express that padding, so
    /// this pins the property a formatter-based rewrite would silently lose.
    @Test("the formatted value is ctime's 24-character shape")
    func formatIsCtimeShaped() throws {
        let formatted = try #require(
            ProcessStartTime.format(Date(timeIntervalSince1970: 1_788_041_297)))
        #expect(formatted.count == 24)
        #expect(formatted.range(
            of: #"^[A-Za-z]{3} [A-Za-z]{3} [ 0-9][0-9] [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4}$"#,
            options: .regularExpression) != nil)
    }

    /// The calendar is pinned to GMT rather than `Calendar.current`, because
    /// the formatter renders in UTC: building "the 5th at noon" in the local
    /// zone and then reading the day back out of a UTC rendering disagrees
    /// wherever the offset exceeds 12 hours. `ProcessStartTimeFormatTests`
    /// covers the padding byte-exactly over fixed epochs.
    @Test("a single-digit day of month is space-padded, not zero-padded")
    func singleDigitDayIsSpacePadded() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: Date())
        components.day = 5
        components.hour = 12
        components.minute = 0
        components.second = 0
        let fifth = try #require(calendar.date(from: components))

        let formatted = try #require(ProcessStartTime.format(fifth))
        let day = String(formatted.dropFirst(8).prefix(2))
        #expect(day == " 5")
    }

    /// The value must describe a process that genuinely exists. These are the
    /// two ends of that: our own pid resolves, and a pid that cannot name a
    /// process resolves to nothing rather than to "now".
    @Test("our own process has a start time in the past")
    func ownStartTimeResolves() throws {
        let started = try #require(ProcessStartTime.startTime(pid: getpid()))
        #expect(started <= Date())
        #expect(started > Date(timeIntervalSince1970: 0))
        #expect(ProcessStartTime.procStart(pid: getpid()) == ProcessStartTime.format(started))
    }

    @Test("a pid that names no process resolves to nothing")
    func invalidPIDsResolveToNil() {
        #expect(ProcessStartTime.startTime(pid: 0) == nil)
        #expect(ProcessStartTime.startTime(pid: -1) == nil)
        #expect(ProcessStartTime.procStart(pid: -1) == nil)
    }
}
