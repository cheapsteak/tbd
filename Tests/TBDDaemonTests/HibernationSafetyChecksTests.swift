import Testing
import Foundation
@testable import TBDDaemonLib

@Suite("HibernationSafetyChecks")
struct HibernationSafetyChecksTests {

    // MARK: - Pending typed input

    @Test func emptyPromptIsSafe() {
        let capture = """
        ╭──────────────────────────────────────╮
        │ >                                    │
        ╰──────────────────────────────────────╯
        """
        #expect(HibernationSafetyChecks.hasPendingInput(paneCapture: capture) == false)
    }

    @Test func placeholderPromptIsSafe() {
        let capture = """
        ╭──────────────────────────────────────╮
        │ > Try "fix the failing test"         │
        ╰──────────────────────────────────────╯
        """
        #expect(HibernationSafetyChecks.hasPendingInput(paneCapture: capture) == false)
    }

    @Test func typedTextBlocksHibernation() {
        let capture = """
        some transcript output above
        ╭──────────────────────────────────────╮
        │ > refactor the auth module and add    │
        ╰──────────────────────────────────────╯
        """
        #expect(HibernationSafetyChecks.hasPendingInput(paneCapture: capture) == true)
    }

    @Test func emptyCaptureIsSafe() {
        #expect(HibernationSafetyChecks.hasPendingInput(paneCapture: "") == false)
    }

    @Test func plainPromptWithoutBoxWithText() {
        // A `>`-prefixed line without box drawing still counts.
        #expect(HibernationSafetyChecks.hasPendingInput(paneCapture: "> hello world") == true)
    }

    // MARK: - Pending typed input: real screens

    /// The composer region of real Claude Code 2.1.302 screens, captured with
    /// `capture-pane -p -e -J` — the flags `capturePaneWithAnsi` passes — in a
    /// 100-column pane (60 for the wrapped draft). Escapes are kept byte for
    /// byte; tmux's trailing pad spaces are dropped. Current releases draw the
    /// prompt as `❯` (`!` in shell mode) followed by a no-break space, between
    /// two horizontal rules.
    struct RealScreen: Sendable, CustomTestStringConvertible {
        let name: String
        let ansi: String
        let pending: Bool
        var testDescription: String { name }

        /// The same screen without its escapes: what `capture-pane -p` prints,
        /// and what a holder screen's `output` hands the rail.
        var plain: String {
            ansi.replacingOccurrences(
                of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        }
    }

    static let rule = String(repeating: "─", count: 100)
    static let gray = "\u{1B}[38;5;244m"
    static let dim = "\u{1B}[38;5;246m"
    static let pink = "\u{1B}[38;5;211m"
    static let fg = "\u{1B}[39m"
    static let cursorOn = "\u{1B}[7m"
    static let reset = "\u{1B}[0m"
    static let footer = "\(fg)  \(dim)⏸ manual mode on\(fg)"

    static let realScreens: [RealScreen] = [
        RealScreen(name: "empty composer", ansi: """
            \(gray)\(rule)
            \(fg)❯\u{A0}\(cursorOn) \(reset)
            \(gray)\(rule)
            \(fg)  \(dim)⏸ manual mode on · ? for shortcuts
            """, pending: false),
        RealScreen(name: "typed one-line draft", ansi: """
            \(gray)\(rule)
            \(fg)❯\u{A0}refactor the auth module\(cursorOn) \(reset)
            \(gray)\(rule)
            \(footer)
            """, pending: true),
        RealScreen(name: "two-line draft", ansi: """
            \(fg)\(String(repeating: " ", count: 77))\(dim)ctrl+g to edit in Vim
            \(gray)\(rule)
            \(fg)❯\u{A0}refactor the auth module
              and add tests\(cursorOn) \(reset)
            \(gray)\(rule)
            \(footer)
            """, pending: true),
        RealScreen(name: "draft whose first line is blank", ansi: """
            \(fg)\(String(repeating: " ", count: 77))\(dim)ctrl+g to edit in Vim
            \(gray)\(rule)
            \(fg)❯\u{A0}
              second line only\(cursorOn) \(reset)
            \(gray)\(rule)
            \(footer)
            """, pending: true),
        RealScreen(name: "draft wrapped at 60 columns", ansi: """
            \(gray)\(String(repeating: "─", count: 60))
            \(fg)❯\u{A0}please refactor the authentication module so that the
              session handling is easier to follow\(cursorOn)\u{20}
            \(reset)\(gray)\(String(repeating: "─", count: 60))
            \(footer)
            """, pending: true),
        RealScreen(name: "shell-mode draft", ansi: """
            \(pink)\(rule)
            !\u{A0}\(fg)ls -la\(cursorOn) \(reset)
            \(pink)\(rule)
            \(fg)  \(pink)! for shell mode\(fg)
            """, pending: true),
        // Shell mode's status line starts with `!` once trimmed; it is
        // indented, so it must not read as a prompt holding "for shell mode".
        RealScreen(name: "empty shell-mode composer", ansi: """
            \(pink)\(rule)
            !\u{A0}\(cursorOn)\(fg) \(reset)
            \(pink)\(rule)
            \(fg)  \(pink)! for shell mode\(fg)
            """, pending: false),
    ]

    @Test(arguments: realScreens)
    func realScreenWithEscapes(_ screen: RealScreen) {
        #expect(HibernationSafetyChecks.hasPendingInput(paneCapture: screen.ansi) == screen.pending)
    }

    @Test(arguments: realScreens)
    func realScreenAsPlainText(_ screen: RealScreen) {
        #expect(HibernationSafetyChecks.hasPendingInput(paneCapture: screen.plain) == screen.pending)
    }

    // MARK: - Transcript tail validity

    @Test func validJSONTailPasses() {
        let body = #"""
        {"type":"user","text":"hi"}
        {"type":"assistant","text":"hello there"}
        """#
        #expect(HibernationSafetyChecks.isTranscriptTailValid(jsonlBody: body) == true)
    }

    @Test func truncatedTailFails() {
        // Last line is a half-written JSON object — the #18880 corruption case.
        let body = #"""
        {"type":"user","text":"hi"}
        {"type":"assistant","text":"hel
        """#
        #expect(HibernationSafetyChecks.isTranscriptTailValid(jsonlBody: body) == false)
    }

    @Test func emptyTranscriptIsValid() {
        #expect(HibernationSafetyChecks.isTranscriptTailValid(jsonlBody: "") == true)
    }

    @Test func trailingNewlineIgnored() {
        let body = #"""
        {"type":"assistant","text":"done"}

        """#
        #expect(HibernationSafetyChecks.isTranscriptTailValid(jsonlBody: body) == true)
    }
}
