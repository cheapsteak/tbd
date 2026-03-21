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
