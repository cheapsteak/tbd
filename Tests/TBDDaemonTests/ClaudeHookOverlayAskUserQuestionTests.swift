import Testing
@testable import TBDDaemonLib

/// The overlay's two `AskUserQuestion` entries are the only callers of the
/// CLI's hidden `tbd ask-user-question pre|post` subcommands.
/// `ClaudeHookOverlayTests.registersNotificationHookWithoutAMatcherAndLeavesTheOthersUntouched`
/// pins where every command is registered, by symbol; this pins what these two
/// invoke, so a renamed subcommand on either side goes red.
@Suite struct ClaudeHookOverlayAskUserQuestionTests {
    @Test func askUserQuestionHooksInvokeTheCLISubcommands() {
        #expect(ClaudeHookOverlay.askUserQuestionPreCommand.hasPrefix("tbd ask-user-question pre "))
        #expect(ClaudeHookOverlay.askUserQuestionPostCommand.hasPrefix("tbd ask-user-question post "))
    }
}
