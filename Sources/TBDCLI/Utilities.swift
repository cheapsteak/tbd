import Foundation
import TBDShared

/// Compose a Codable value into the pretty-printed JSON text the CLI prints.
/// Internal (not private) so TBDCLITests can assert against the same composed
/// output a command actually emits, rather than a re-encoded lookalike.
func jsonString<T: Encodable>(_ value: T) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(value) else { return nil }
    return String(data: data, encoding: .utf8)
}

/// Print a Codable value as pretty-printed JSON to stdout.
func printJSON<T: Encodable>(_ value: T) {
    if let string = jsonString(value) {
        print(string)
    }
}

/// A type whose `Encodable` conformance produces a JSON **object** — not an
/// array, not a scalar. Conforming is an assertion about encoded shape, and
/// nothing but the author checks it.
///
/// It exists because `VersionedJSONEnvelope` reuses its payload's top-level
/// container to add one key. A payload that encodes as an array or a scalar has
/// already claimed the encoder's single top-level container, and asking for a
/// keyed one afterwards trips `JSONEncoder`'s `preconditionFailure` — a crash,
/// not a thrown error, so `try?` at the call site would not save it. Most of
/// this CLI's `--json` output is a bare array (`tbd terminal list --json`,
/// which stays unversioned for exactly this reason), so the next person to
/// reach for the envelope is more likely than not holding the wrong shape.
/// Requiring this conformance turns that into a compile error.
protocol JSONObjectPayload: Encodable {}

/// The one versioned payload today. Conformance lives in TBDCLI rather than
/// beside the type in TBDShared: which surfaces carry a printed contract is the
/// CLI's knowledge, and the daemon's RPC results are an internal seam that
/// should not grow CLI-shaped marker protocols.
extension ModelProfileListResult: JSONObjectPayload {}

/// Wraps a command's JSON payload with the top-level `schemaVersion` the CLI
/// contract promises (see `docs/capacity-facts.md`): fields may be added
/// within a version; a field never changes meaning; removing a field or
/// changing its meaning requires a version bump.
///
/// The payload encodes into the *same* keyed container as `schemaVersion`, so
/// the envelope is drift-proof: any field the underlying RPC result gains
/// flows through automatically, with no envelope-side mirror to update.
///
/// Two consequences of that sharing:
///
/// - **Object-shaped payloads only**, enforced by `JSONObjectPayload`.
/// - **The envelope's `schemaVersion` wins.** It is encoded last, so if a
///   payload ever grows a `schemaVersion` key of its own the envelope's value
///   overwrites it. That is the intended authority order: the CLI's printed
///   contract version is the CLI's to state, not the daemon's.
struct VersionedJSONEnvelope<Payload: JSONObjectPayload>: Encodable {
    let schemaVersion: Int
    let payload: Payload

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
    }

    func encode(to encoder: Encoder) throws {
        try payload.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
    }
}

/// Contract version of `tbd profile list --json` — the machine-readable
/// capacity surface documented in `docs/capacity-facts.md`. Bump only for a
/// breaking change (a removed field, or a field whose meaning or units
/// changed); additions ship within the current version.
let profileListSchemaVersion = 1

/// Print a dictionary as pretty-printed JSON to stdout.
func printJSON(_ dict: [String: String]) {
    if let data = try? JSONSerialization.data(
        withJSONObject: dict,
        options: [.prettyPrinted, .sortedKeys]
    ), let string = String(data: data, encoding: .utf8) {
        print(string)
    }
}

/// Format a table row for plain-text list output: each value is
/// left-justified (space-padded, never truncated) to its column width,
/// and columns are joined with two spaces. Use a width of 0 for the
/// final column so it isn't right-padded.
///
/// This replaces `String(format: "%-36s ...", ...)`, which is undefined
/// behavior on Darwin when handed Swift String/NSString arguments (`%s`
/// expects a C string pointer) and crashed with SIGSEGV.
func tableRow(_ cells: [(value: String, width: Int)]) -> String {
    cells.map { cell in
        let padding = cell.width - cell.value.count
        return padding > 0 ? cell.value + String(repeating: " ", count: padding) : cell.value
    }.joined(separator: "  ")
}

/// Resolve a path relative to the current working directory.
func resolvePath(_ path: String) -> String {
    if path.hasPrefix("/") {
        return path
    }
    return URL(
        fileURLWithPath: path,
        relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ).standardized.path
}

/// Resolve prompt text from `--prompt` (inline) and `--prompt-file` (file/stdin).
/// The two flags are mutually exclusive. Returns nil if neither is provided.
func resolvePrompt(inline: String?, file: String?) throws -> String? {
    guard inline == nil || file == nil else {
        throw CLIError.invalidArgument("Cannot use both --prompt and --prompt-file")
    }
    guard let file else { return inline }
    if file == "-" {
        guard isatty(STDIN_FILENO) == 0 else {
            throw CLIError.invalidArgument("--prompt-file - requires piped input (e.g., <<'EOF' ... EOF)")
        }
        return String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)
    }
    let resolved = resolvePath(file)
    guard FileManager.default.fileExists(atPath: resolved) else {
        throw CLIError.invalidArgument("Prompt file not found: \(file)")
    }
    return try String(contentsOfFile: resolved, encoding: .utf8)
}
