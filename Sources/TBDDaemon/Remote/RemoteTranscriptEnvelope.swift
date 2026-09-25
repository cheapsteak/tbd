import Foundation
import os

private let envelopeLogger = Logger(subsystem: "com.tbd.daemon", category: "remote-transcript")

/// What one `transcript read` call said about itself, read from the JSON
/// envelope it wrote on stderr (`docs/remote-provider-contract.md` §
/// `transcript read <id> [--since <cursor>]`):
///
/// ```json
/// {"cursor": "opaque-provider-string", "reset": true, "more": true}
/// ```
///
/// Already resolved against the contract's rules, so a caller acts on the
/// three fields without re-deriving any of them:
///
/// - **No envelope** is a provider without incremental support: the output is
///   the whole conversation, so it is a reset, there is no cursor, and the
///   caller is caught up.
/// - **A call made without `--since` is a reset** whether or not the flag is
///   set, because the provider answered from the beginning.
/// - **`more` without a cursor is read as though `more` were absent** — there
///   is nothing to continue from.
/// - **A malformed envelope reads as no envelope**, plus a log line. Treating
///   the output as a whole-conversation reset is the reading that cannot
///   duplicate or splice records; the cost is one full rewrite.
///
/// Pure: no IO beyond the log line.
struct RemoteTranscriptEnvelope: Equatable, Sendable {
    /// Where the fields came from. Informational — the other three fields are
    /// already resolved — but it is what lets a test tell "no envelope" from
    /// "an envelope that failed to decode", which resolve identically.
    enum Source: Equatable, Sendable {
        case envelope
        case absent
        case malformed
    }

    /// The continuation cursor to store and pass back verbatim on the next
    /// call's `--since`. Opaque: never parsed, compared or constructed.
    let cursor: String?
    /// Discard everything held from earlier calls; this output starts from
    /// the beginning of the session's current conversation.
    let reset: Bool
    /// The provider stopped at its own size limit; call again at once with
    /// `cursor`. Never true without a cursor.
    let more: Bool
    let source: Source

    /// The envelope's wire shape. Decoded strictly: a `cursor` that is not a
    /// string, or a flag that is not a boolean, makes the envelope malformed
    /// rather than being coerced.
    private struct Wire: Decodable {
        let cursor: String?
        let reset: Bool?
        let more: Bool?
    }

    private static let envelopeKeys: Set<String> = ["cursor", "reset", "more"]

    /// Reads the envelope out of a `transcript read` call's stderr.
    ///
    /// - Parameters:
    ///   - stderr: the call's whole stderr. The envelope is the only stderr
    ///     content the contract defines, but a provider may still write
    ///     diagnostics beside it, so the envelope is the **last** line that is
    ///     a JSON object naming at least one of `cursor`, `reset`, `more`. A
    ///     JSON object naming none of them is a diagnostic (a structured log
    ///     line), not an envelope, and is passed over.
    ///   - requestedSince: whether the call carried `--since`. Without it the
    ///     answer is a reset by definition.
    ///   - provider: named in the malformed-envelope log line only.
    static func parse(
        stderr: String, requestedSince: Bool, provider: String = "?"
    ) -> RemoteTranscriptEnvelope {
        let lines = stderr
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("{") }

        for line in lines.reversed() {
            let data = Data(line.utf8)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return malformed(line: line, provider: provider)
            }
            guard !envelopeKeys.isDisjoint(with: object.keys) else { continue }
            guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else {
                return malformed(line: line, provider: provider)
            }
            let reset = (wire.reset ?? false) || !requestedSince
            let more = (wire.more ?? false) && wire.cursor != nil
            if wire.more == true, wire.cursor == nil {
                envelopeLogger.error(
                    "transcript read provider=\(provider, privacy: .public): envelope sets more without a cursor; reading as caught up")
            }
            return RemoteTranscriptEnvelope(cursor: wire.cursor, reset: reset, more: more, source: .envelope)
        }
        return RemoteTranscriptEnvelope(cursor: nil, reset: true, more: false, source: .absent)
    }

    private static func malformed(line: String, provider: String) -> RemoteTranscriptEnvelope {
        envelopeLogger.error(
            "transcript read provider=\(provider, privacy: .public): malformed stderr envelope \(line, privacy: .public); treating the output as a whole-conversation reset")
        return RemoteTranscriptEnvelope(cursor: nil, reset: true, more: false, source: .malformed)
    }
}
