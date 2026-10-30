import Foundation

/// Validation of the extra plugin folders a terminal carries.
///
/// Pure: the only filesystem access is the injected `fileExists` closure.
enum ClaudePluginDirs {
    struct InvalidPath: LocalizedError, CustomStringConvertible {
        let description: String
        var errorDescription: String? { description }
    }

    /// Expands a leading `~/` against `homeDirectory`, requires each result to
    /// be absolute and existing, standardizes it (`.`, `..`, trailing `/`), keeps
    /// order and drops duplicates of the standardized form.
    static func validated(
        _ paths: [String],
        homeDirectory: String,
        fileExists: (String) -> Bool
    ) throws -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths {
            let joined: String
            if path.hasPrefix("~/") {
                let home = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
                joined = home + "/" + path.dropFirst(2)
            } else {
                joined = path
            }
            guard joined.hasPrefix("/") else {
                throw InvalidPath(description: "plugin folder path must be absolute or start with ~/: \(path)")
            }
            let expanded = (joined as NSString).standardizingPath
            guard fileExists(expanded) else {
                throw InvalidPath(description: "plugin folder does not exist: \(path)")
            }
            if seen.insert(expanded).inserted { result.append(expanded) }
        }
        return result
    }
}
