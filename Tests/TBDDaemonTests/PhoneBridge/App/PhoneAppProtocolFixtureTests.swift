import Foundation
import TBDShared
import Testing

@testable import TBDDaemonLib

/// The app protocol's fixtures in `phone/protocol/`, which the phone's
/// TypeScript tests read too. Each one decodes into the typed envelope its
/// name selects and encodes back to the same JSON, so the two sides cannot
/// drift. Tier 1: reads files in the repo and touches nothing else.
@Suite("Phone app protocol: fixtures")
struct PhoneAppProtocolFixtureTests {
    @Test func everyFixtureRoundTrips() throws {
        for name in try fixtureNames() {
            let original = try loadFixture(name)
            let reencoded = try reencode(name, original)
            let before = try JSONSerialization.jsonObject(with: original) as? NSDictionary
            let after = try JSONSerialization.jsonObject(with: reencoded) as? NSDictionary
            #expect(before != nil, "\(name) is not a JSON object")
            #expect(after == before, "\(name) does not survive a decode and encode")
        }
    }

    @Test func theFixtureSetIsExactlyTheProtocol() throws {
        let expected = Set(PhoneAppMethod.allCases.flatMap {
            ["\($0.rawValue).request.json", "\($0.rawValue).reply.json"]
        })
            .union(PhoneAppEventName.allCases.map { "\($0.rawValue).event.json" })
            .union(["error.reply.json"])
        let actual = try Set(fixtureNames())
        #expect(actual == expected)
        #expect(expected.count == 34)
    }

    /// No `null`, the envelope's `kind`, `method` and `event` match the file
    /// name, and every `requestID` is a UUID.
    @Test func fixturesFollowTheWireRules() throws {
        for name in try fixtureNames() {
            let object = try JSONSerialization.jsonObject(with: loadFixture(name))
            guard let envelope = object as? [String: Any] else {
                Issue.record("\(name) is not a JSON object")
                continue
            }
            let hasNull = containsNull(envelope)
            #expect(!hasNull, "\(name) holds a null")
            let kind = envelope["kind"] as? String
            let method = envelope["method"] as? String
            let event = envelope["event"] as? String
            if name.hasSuffix(".request.json") {
                let fileMethod = String(name.dropLast(".request.json".count))
                #expect(kind == "request", "\(name) kind")
                #expect(method == fileMethod, "\(name) method")
            } else if name.hasSuffix(".reply.json") {
                #expect(kind == "reply", "\(name) kind")
            } else {
                let fileEvent = String(name.dropLast(".event.json".count))
                #expect(kind == "event", "\(name) kind")
                #expect(event == fileEvent, "\(name) event")
            }
            if kind != "event" {
                let requestID = envelope["requestID"] as? String ?? ""
                #expect(UUID(uuidString: requestID) != nil, "\(name) requestID \(requestID) is not a UUID")
            }
        }
    }

    @Test func fixturesCoverEveryChipAndItemKind() throws {
        let subscribeReply = try decodeFixture(
            PhoneReplyEnvelope<SessionsSubscribeResult>.self, "sessions.subscribe.reply.json")
        let rows = try #require(subscribeReply.result.rows)
        let chips = Set(rows.flatMap { $0.sessions }.map { $0.status.chip })
        #expect(chips == Set(PhoneStatusChip.allCases))

        let layout = try #require(subscribeReply.result.layout)
        let groupKinds = Set(layout.filter { !$0.rows.isEmpty }.map { $0.kind })
        let expectedGroupKinds: Set<String> = ["scratch", "repo", "provider"]
        #expect(groupKinds == expectedGroupKinds)
        let placedRowIDs = Set(layout.flatMap { $0.rows }.map { $0.id })
        let rowIDs = Set(rows.map { $0.id })
        #expect(placedRowIDs == rowIDs)

        let appendEvent = try decodeFixture(
            PhoneEventEnvelope<TranscriptItemsData>.self, "transcript.append.event.json")
        let itemKinds = appendEvent.data.items.map { $0.kind }
        #expect(Set(itemKinds) == Set(PhoneItemKind.allCases))
        #expect(itemKinds.count == PhoneItemKind.allCases.count)
    }

    /// Rows carry `statusChangedAt`, the newest change among their sessions,
    /// with a different value on each row, so the phone's newest-first sort
    /// is exercised.
    @Test func rowsCarryDistinctStatusChangeTimes() throws {
        let subscribeReply = try decodeFixture(
            PhoneReplyEnvelope<SessionsSubscribeResult>.self, "sessions.subscribe.reply.json")
        let changed = try decodeFixture(
            PhoneEventEnvelope<SessionsChangedData>.self, "sessions.changed.event.json")
        let subscribeRows = try #require(subscribeReply.result.rows)
        for rows in [subscribeRows, changed.data.rows] {
            let times = rows.map { $0.statusChangedAt }
            #expect(rows.count >= 2)
            #expect(Set(times).count == rows.count)
            for row in rows {
                let newest = row.sessions.map { $0.status.changedAt }.max() ?? row.statusChangedAt
                #expect(newest == row.statusChangedAt, "row \(row.id)")
            }
        }
    }

    @Test func promptFixturesCoverBothKindsAndBothAnswerers() throws {
        let event = try decodeFixture(
            PhoneEventEnvelope<PromptChangedData>.self, "prompt.changed.event.json")
        let promptKinds = event.data.prompts.map { $0.kind }.sorted()
        #expect(promptKinds == ["permission", "question"])

        let resolved = try #require(event.data.resolved)
        let answerers = Set(resolved.map { $0.answeredBy })
        let expectedAnswerers: Set<PhoneAnsweredBy> = [.phone, .laptop]
        #expect(answerers == expectedAnswerers)
        let withDevice = resolved.filter { $0.deviceID != nil }.map { $0.answeredBy }
        let phoneOnly: [PhoneAnsweredBy] = [.phone]
        #expect(withDevice == phoneOnly)

        let answer = try decodeFixture(
            PhoneRequestEnvelope<PhonePromptAnswerParams>.self, "prompt.answer.request.json")
        guard case .permission(decision: .deny, message: let message?) = answer.params.answer else {
            Issue.record("prompt.answer.request.json does not deny with a message")
            return
        }
        #expect(!message.isEmpty)
    }

    @Test func errorReplyFixtureIsARefusal() throws {
        let reply = try decodeFixture(PhoneErrorEnvelope.self, "error.reply.json")
        #expect(reply.error.code == .refused)
    }

    @Test func errorCodesAreTheClosedList() {
        let codes = PhoneAppErrorCode.allCases.map { $0.rawValue }
        #expect(codes == ["phone_control_off", "bad_request", "unknown_method", "not_found",
                          "unsupported", "refused", "not_open", "stale_cursor", "unavailable",
                          "internal"])
    }

    @Test(arguments: [
        "plain", "quote\"back\\slash", "\u{1}\u{1F}", "line\nbreak\ttab", "é漢😀", "a/b",
        "\u{8}\u{C}", "\u{7F}\u{2028}", "\u{2029}\r\u{0}",
    ])
    func escapedLengthMatchesTheEncoder(_ s: String) throws {
        let encoded = try PhoneAppCoding.makeEncoder().encode(s)
        let length = PhoneFrameBudget.escapedLength(s.unicodeScalars[...])
        #expect(length + 2 == encoded.count)
    }

    @Test func framedSizeCountsTheLoaderWrapper() {
        let body = Data(#"{"kind":"event"}"#.utf8)
        let framed = Data(#"{"type":"app","body":{"kind":"event"}}"#.utf8)
        #expect(PhoneAppCoding.framedSize(body) == framed.count)
        #expect(PhoneFrameBudget.maxPlaintext == 65_519)
    }

    @Test func codingHelpersWriteTheirEnvelopes() throws {
        let event = try PhoneAppCoding.event(.transcriptUpdate, seq: 7, data: PhoneEmpty())
        let eventText = String(decoding: event, as: UTF8.self)
        #expect(eventText == #"{"data":{},"event":"transcript.update","kind":"event","seq":7}"#)

        let reply = try PhoneAppCoding.reply(requestID: "R1", result: ActionOutcomeResult(outcome: "sent"))
        let replyText = String(decoding: reply, as: UTF8.self)
        #expect(replyText == #"{"kind":"reply","requestID":"R1","result":{"outcome":"sent"}}"#)

        let appError = PhoneAppError(code: .notOpen, message: "No transcript is open.")
        let errorReply = PhoneAppCoding.errorReply(requestID: "R2", appError)
        let decoded = try JSONDecoder().decode(PhoneErrorEnvelope.self, from: errorReply)
        #expect(decoded == PhoneErrorEnvelope(requestID: "R2", error: appError))
    }

    @Test func paramsReadsTheRequestsParams() throws {
        let body = try loadFixture("transcript.page.request.json")
        let params = try PhoneAppCoding.params(TranscriptPageParams.self, from: body)
        let envelope = try JSONDecoder().decode(
            PhoneRequestEnvelope<TranscriptPageParams>.self, from: body)
        #expect(params == envelope.params)
    }

    @Test func sessionRefRejectsAnUnknownKind() {
        let body = Data(#"{"kind":"cloud","provider":"acme-cloud","sessionID":"rs-1"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PhoneSessionRef.self, from: body)
        }
    }

    @Test func sessionRefDescribesItsTarget() throws {
        let terminalID = try #require(UUID(uuidString: "0B4E1C2D-3A5F-4E6B-8C7D-9E0F1A2B3C4D"))
        let local = PhoneSessionRef.local(terminalID: terminalID)
        let remote = PhoneSessionRef.remote(provider: "acme-cloud", sessionID: "rs-1")
        #expect(local.targetDescription == "local:0B4E1C2D-3A5F-4E6B-8C7D-9E0F1A2B3C4D")
        #expect(remote.targetDescription == "remote:acme-cloud/rs-1")
    }
}

// MARK: - Fixture access

private enum FixtureError: Error, CustomStringConvertible {
    case noPackageRoot(String)
    case unknownFixture(String)

    var description: String {
        switch self {
        case .noPackageRoot(let path): "no directory above \(path) holds Package.swift"
        case .unknownFixture(let name): "\(name) names no method or event of the app protocol"
        }
    }
}

/// `phone/protocol`, found by walking up from this file to the directory that
/// holds `Package.swift`.
private func protocolDirectory() throws -> URL {
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while directory.pathComponents.count > 1 {
        let manifest = directory.appendingPathComponent("Package.swift").path
        if FileManager.default.fileExists(atPath: manifest) {
            return directory.appendingPathComponent("phone/protocol")
        }
        directory = directory.deletingLastPathComponent()
    }
    throw FixtureError.noPackageRoot(#filePath)
}

private func fixtureNames() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: protocolDirectory().path).sorted()
}

private func loadFixture(_ name: String) throws -> Data {
    try Data(contentsOf: protocolDirectory().appendingPathComponent(name))
}

private func decodeFixture<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
    try JSONDecoder().decode(T.self, from: loadFixture(name))
}

private func containsNull(_ value: Any) -> Bool {
    if value is NSNull { return true }
    if let object = value as? [String: Any] { return object.values.contains { containsNull($0) } }
    if let array = value as? [Any] { return array.contains { containsNull($0) } }
    return false
}

// MARK: - Typed round trips

private func roundTrip<T: Codable>(_ type: T.Type, _ data: Data) throws -> Data {
    try PhoneAppCoding.makeEncoder().encode(JSONDecoder().decode(T.self, from: data))
}

/// Decodes `data` as the envelope the fixture's name selects, and encodes it
/// again with the protocol's encoder.
private func reencode(_ name: String, _ data: Data) throws -> Data {
    if name == "error.reply.json" {
        return try roundTrip(PhoneErrorEnvelope.self, data)
    }
    for method in PhoneAppMethod.allCases {
        let codecs = MethodCodecs(method)
        if name == "\(method.rawValue).request.json" { return try codecs.request(data) }
        if name == "\(method.rawValue).reply.json" { return try codecs.reply(data) }
    }
    for event in PhoneAppEventName.allCases where name == "\(event.rawValue).event.json" {
        return try reencodeEvent(event, data)
    }
    throw FixtureError.unknownFixture(name)
}

/// Each method's params and result types. The switch is exhaustive, so a new
/// method does not compile until it names its types here.
private struct MethodCodecs {
    let request: (Data) throws -> Data
    let reply: (Data) throws -> Data

    init<P: Codable, R: Codable>(_ params: P.Type, _ result: R.Type) {
        request = { try roundTrip(PhoneRequestEnvelope<P>.self, $0) }
        reply = { try roundTrip(PhoneReplyEnvelope<R>.self, $0) }
    }

    init(_ method: PhoneAppMethod) {
        switch method {
        case .sessionsSubscribe: self.init(SessionsSubscribeParams.self, SessionsSubscribeResult.self)
        case .transcriptOpen: self.init(TranscriptOpenParams.self, TranscriptOpenResult.self)
        case .transcriptPage: self.init(TranscriptPageParams.self, TranscriptPage.self)
        case .transcriptDetail: self.init(TranscriptDetailParams.self, TranscriptDetailResult.self)
        case .transcriptClose: self.init(PhoneEmpty.self, PhoneEmpty.self)
        case .messageSend: self.init(MessageSendParams.self, ActionOutcomeResult.self)
        case .promptAnswer: self.init(PhonePromptAnswerParams.self, PromptAnswerResult.self)
        case .profilesList: self.init(PhoneEmpty.self, ProfilesListResult.self)
        case .sessionSwitchProfile: self.init(SessionSwitchProfileParams.self, SessionSwitchProfileResult.self)
        case .sessionFork: self.init(SessionForkParams.self, SessionRefResult.self)
        case .sessionSetModel: self.init(SessionSetModelParams.self, ActionOutcomeResult.self)
        case .worktreeCreate: self.init(PhoneWorktreeCreateParams.self, PhoneWorktreeCreateResult.self)
        case .remoteProviders: self.init(PhoneRemoteProvidersParams.self, PhoneRemoteProvidersResult.self)
        case .remoteCreate: self.init(PhoneRemoteCreateParams.self, SessionRefResult.self)
        }
    }
}

/// Each event's data type, exhaustive like `MethodCodecs`.
private func reencodeEvent(_ event: PhoneAppEventName, _ data: Data) throws -> Data {
    switch event {
    case .sessionsChanged: return try roundTrip(PhoneEventEnvelope<SessionsChangedData>.self, data)
    case .transcriptAppend: return try roundTrip(PhoneEventEnvelope<TranscriptItemsData>.self, data)
    case .transcriptUpdate: return try roundTrip(PhoneEventEnvelope<TranscriptItemsData>.self, data)
    case .transcriptReset: return try roundTrip(PhoneEventEnvelope<TranscriptResetData>.self, data)
    case .promptChanged: return try roundTrip(PhoneEventEnvelope<PromptChangedData>.self, data)
    }
}
