import Foundation
import TBDShared

/// One line of the `events` NDJSON stream (docs/remote-provider-contract.md
/// `events` section). `session` events carry the full object (idempotent
/// upsert); `removed` is explicit and authoritative — distinct from the
/// two-absence rule `RemoteSessionStore.applySnapshot` applies to *inferred*
/// absence from `list`/`snapshot` polls.
enum RemoteEvent: Equatable, Sendable {
    case hello(contractVersion: Int)
    /// `complete` carries the contract's snapshot-completeness claim, with
    /// exactly the meaning it has on `list`: an incomplete snapshot retires
    /// nothing and refreshes no freshness. Absent reads as `true`.
    case snapshot([RemoteSessionPayload], complete: Bool)
    case session(RemoteSessionPayload)
    case removed(id: String)
    case ping
}

/// Parses one NDJSON line into a `RemoteEvent`. Unknown event types and
/// unparseable lines return `nil` (contract: ignore what you don't know) so
/// a newer provider can add event types without breaking an older TBD, and
/// blank keepalive lines are silently skipped rather than treated as
/// malformed input.
enum RemoteEventParser {
    private struct Envelope: Decodable {
        let event: String
        let contractVersion: Int?
        /// Element-wise, like `list`'s envelope: a `snapshot` line is a whole
        /// inventory, so one malformed session in it must not cost the fleet.
        let sessions: LenientSessionArray?
        let session: RemoteSessionPayload?
        let id: String?
        let complete: Bool?
        enum CodingKeys: String, CodingKey {
            case event, sessions, session, id, complete
            case contractVersion = "contract_version"
        }
    }

    /// `provider` names whose stream this line came from, for the contract
    /// diagnostics the session types emit while decoding; it has no effect on
    /// what parses.
    static func parse(line: String, provider: String? = nil) -> RemoteEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let envelope = try? JSONDecoder.forRemoteProvider(provider)
                  .decode(Envelope.self, from: data) else { return nil }
        switch envelope.event {
        case "hello": return .hello(contractVersion: envelope.contractVersion ?? 1)
        case "snapshot":
            return .snapshot(envelope.sessions?.sessions ?? [], complete: envelope.complete ?? true)
        case "session": return envelope.session.map { .session($0) }
        case "removed": return envelope.id.map { .removed(id: $0) }
        case "ping": return .ping
        default: return nil
        }
    }
}
