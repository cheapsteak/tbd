import Foundation

/// Reads Claude Code's `permission_suggestions` — the "don't ask again"
/// entries a permission dialog offers.
///
/// They are not always permission rules: for a plain Bash call Claude Code may
/// suggest adding a directory or switching the session's mode. So the
/// permission card lists what each one does, and `allow_always` applies them
/// all with the destination forced to `session`, so nothing reaches disk.
public enum PermissionSuggestionSummary {
    /// One readable line per effect: "adds directory /x", "switches to
    /// acceptEdits", "allows Bash(touch:*)", else "changes a permission
    /// setting". Empty for nil, an empty array, or JSON that is not an array.
    public static func lines(fromJSON json: String?) -> [String] {
        suggestions(fromJSON: json).flatMap(lines(for:))
    }

    /// Every suggestion object with `destination` set to `"session"`; nil when
    /// there are none.
    public static func sessionScoped(fromJSON json: String?) -> [[String: Any]]? {
        let scoped = suggestions(fromJSON: json).map { suggestion -> [String: Any] in
            var copy = suggestion
            copy["destination"] = "session"
            return copy
        }
        return scoped.isEmpty ? nil : scoped
    }

    static let fallbackLine = "changes a permission setting"

    private static func suggestions(fromJSON json: String?) -> [[String: Any]] {
        guard let json,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let array = object as? [Any] else {
            return []
        }
        return array.compactMap { $0 as? [String: Any] }
    }

    private static func lines(for suggestion: [String: Any]) -> [String] {
        switch suggestion["type"] as? String {
        case "addDirectories":
            let directories = (suggestion["directories"] as? [Any])?.compactMap { $0 as? String } ?? []
            return directories.isEmpty ? [fallbackLine] : directories.map { "adds directory \($0)" }
        case "setMode":
            guard let mode = suggestion["mode"] as? String else { return [fallbackLine] }
            return ["switches to \(mode)"]
        case "addRules":
            let behavior = (suggestion["behavior"] as? String) ?? "allow"
            let verb: String
            switch behavior {
            case "allow": verb = "allows"
            case "deny": verb = "denies"
            default: return [fallbackLine]
            }
            let rules = (suggestion["rules"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
            let lines: [String] = rules.compactMap { rule in
                guard let tool = rule["toolName"] as? String else { return nil }
                if let content = rule["ruleContent"] as? String, !content.isEmpty {
                    return "\(verb) \(tool)(\(content))"
                }
                return "\(verb) \(tool)"
            }
            return lines.isEmpty ? [fallbackLine] : lines
        default:
            return [fallbackLine]
        }
    }
}
