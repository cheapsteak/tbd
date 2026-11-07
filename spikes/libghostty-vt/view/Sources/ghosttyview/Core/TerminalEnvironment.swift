// Adapted from tkzmux c961533 Sources/TkzTerminalCore/TerminalEnvironment.swift (MIT).
// Cut down to the child environment. tkzmux's shell wrappers, hook socket and agent variables are gone.
import Foundation

enum TerminalEnvironment {
    /// Variables the launching process may have set that must not leak into the child.
    static let strippedKeys = ["TERM_SESSION_ID", "TERMINFO_DIRS", "CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT"]
    /// Claude Code stamps its children with these. `CLAUDE_CONFIG_DIR` does not match on purpose.
    static let strippedKeyPrefixes = ["CLAUDE_CODE_"]

    /// The terminfo copied from tkzmux, by source path because there is no bundle.
    static var terminfoDirectory: URL? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("terminfo")
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("78/xterm-ghostty").path) ? url : nil
    }

    static func make(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        for key in strippedKeys { env.removeValue(forKey: key) }
        for key in env.keys.filter({ name in strippedKeyPrefixes.contains(where: name.hasPrefix) }) {
            env.removeValue(forKey: key)
        }
        env["TERM_PROGRAM"] = "ghostty"
        env["TERM_PROGRAM_VERSION"] = "1.0.0"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = base["LANG"] ?? "en_US.UTF-8"
        if let terminfo = terminfoDirectory {
            env["TERM"] = "xterm-ghostty"
            env["TERMINFO"] = terminfo.path
        } else {
            env["TERM"] = "xterm-256color"
        }
        return env
    }
}
