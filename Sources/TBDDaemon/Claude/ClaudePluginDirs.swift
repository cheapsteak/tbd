import Foundation

/// Validation of the extra plugin folders a terminal carries.
///
/// Pure: the only filesystem access is the injected `fileExists` closure.
enum ClaudePluginDirs {
    struct InvalidPath: Error, CustomStringConvertible {
        let description: String
    }

    /// Expands a leading `~/` against `homeDirectory`, requires each result to
    /// be absolute and existing, keeps order and drops duplicates.
    static func validated(
        _ paths: [String],
        homeDirectory: String,
        fileExists: (String) -> Bool
    ) throws -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths {
            let expanded: String
            if path.hasPrefix("~/") {
                let home = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
                expanded = home + "/" + path.dropFirst(2)
            } else {
                expanded = path
            }
            guard expanded.hasPrefix("/") else {
                throw InvalidPath(description: "plugin folder path must be absolute or start with ~/: \(path)")
            }
            guard fileExists(expanded) else {
                throw InvalidPath(description: "plugin folder does not exist: \(path)")
            }
            if seen.insert(expanded).inserted { result.append(expanded) }
        }
        return result
    }
}
