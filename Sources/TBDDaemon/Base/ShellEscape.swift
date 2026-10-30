import Foundation

/// Shell-escape a string for embedding in a single-quoted shell argument.
func shellEscape(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
