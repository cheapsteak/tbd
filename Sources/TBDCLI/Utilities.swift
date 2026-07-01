import Foundation

/// Print a Codable value as pretty-printed JSON to stdout.
func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(value),
       let string = String(data: data, encoding: .utf8) {
        print(string)
    }
}

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
