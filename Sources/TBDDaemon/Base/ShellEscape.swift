import TBDShared

/// Shell-escape a string for embedding in a single-quoted shell argument.
///
/// `ShellQuoting.singleQuoted(_:)`, which escapes every apostrophe scalar
/// whatever mark follows it.
func shellEscape(_ text: String) -> String {
    ShellQuoting.singleQuoted(text)
}
