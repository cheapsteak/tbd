import AppKit
import SwiftUI
import TBDShared

/// The composer: a text field pinned below the transcript, inside the session
/// workbench beside the index rail.
///
/// A send button that **names the target terminal**, so the injection is never
/// anonymous.
///
/// Text sitting unsent in the terminal's own input box is invisible here, and a
/// message sent from the composer appends to it. No signal exists for that
/// outside the rendered screen — Claude Code keeps its composer in process
/// memory, writes no draft file for a pty-hosted session, and exposes nothing
/// about it on its peer socket. The design accepts the limitation rather than
/// warning from a keystroke timestamp that would be wrong in both directions.
///
/// This type owns the **wiring** only. Every decision it makes — which key means
/// what, what the button says, where a staged image lands — is a static function
/// below, tested without mounting SwiftUI.
struct MessageComposerView: View {
    let terminal: Terminal
    let worktree: LocalWorktree
    let state: ComposerState

    @Environment(AppState.self) private var appState
    @State private var controller: CompletionController?
    @State private var coordinator: ComposerSendCoordinator?
    @State private var command: ComposerCommand?
    @State private var commandToken = 0
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var hoveredAttachment: Int?
    @State private var textViewHandle: NSView?

    private var draft: ComposerDraft { appState.composerDraft(for: terminal.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
            }
            if case .blocked(let message) = state {
                blockedBanner(message)
            }
            if case .notRunning(let exited) = state {
                Text(Self.notRunningNoteText(exited: exited))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
            }
            AttachmentStrip(
                draft: draft,
                onReinsert: { insertToken($0) },
                onReveal: { reveal($0) },
                onRemove: { removeAttachment($0) },
                hoveredNumber: hoveredAttachment,
                onHover: { hoveredAttachment = $0 })
            HStack(alignment: .bottom, spacing: 8) {
                MessageComposerTextView(
                    command: command,
                    isEnabled: state.isEnabled && !isSending,
                    onTextChange: { text, caret, hasMarkedText in
                        draft.text = text
                        controller?.update(
                            text: text, selectionLocation: caret,
                            hasMarkedText: hasMarkedText)
                    },
                    onSubmit: { text in submit(text) },
                    onEscape: { appState.focusTranscript(terminalID: terminal.id) },
                    onImageData: { stage($0) },
                    menuIsOpen: { controller?.isOpen ?? false },
                    onMenuAction: { handleMenu($0) },
                    onViewReady: { view in adopt(view) })
                .frame(minHeight: 32, maxHeight: 132)
                sendButton
            }
            .padding(8)
        }
        .background(.background.secondary)
        .overlay(alignment: .bottomLeading) {
            // Opens UPWARD from the composer, offset by the composer's own
            // height so it never covers the text being typed.
            if let controller, controller.isOpen {
                CompletionOverlayView(
                    controller: controller,
                    onAccept: { accept($0) },
                    // Reached only from an explicit click; hover is handled
                    // inside the overlay and moves nothing.
                    onHighlight: { controller.moveTo(index: $0) })
                .frame(width: 460)
                .alignmentGuide(.bottom) { $0[.top] }
            }
        }
        .onDisappear {
            guard let textViewHandle else { return }
            appState.unregisterComposerView(textViewHandle, for: terminal.id)
        }
        .task(id: terminal.id) { await setUp() }
    }

    // MARK: - Set-up

    /// The text view hands itself out once, from `makeNSView`. Registration is
    /// deferred off that call because it writes `@State`, and SwiftUI treats a
    /// state write during a view update as undefined behavior.
    private func adopt(_ view: NSView) {
        Task { @MainActor in
            textViewHandle = view
            appState.registerComposerView(view, for: terminal.id)
        }
    }

    private func setUp() async {
        if controller == nil {
            controller = CompletionController(
                frecency: FrecencyStore(defaults: appState.userDefaults))
        }
        if coordinator == nil {
            coordinator = ComposerSendCoordinator(
                send: { [appState] params in
                    try await appState.daemonClient.sendComposerMessage(params)
                },
                // NOT `wakeTerminal`: that returns only an error string, and the
                // composer needs the incarnation the wake minted, which is the
                // only thing that scopes the hold to this send's own spawn.
                wake: { [appState] terminalID, worktreeID, prompt in
                    await appState.wakeTerminalForComposer(
                        terminalID: terminalID, worktreeID: worktreeID,
                        prompt: prompt)
                },
                awaitSessionStart: { [appState] terminalID, incarnationID in
                    await appState.awaitSessionStart(
                        terminalID: terminalID, incarnationID: incarnationID)
                })
        }
        // Restore the draft into a view that has just been made — the one write
        // the one-way contract admits, as an explicit one-shot command.
        if !draft.text.isEmpty {
            issue(.restore(draft.text))
        }
        // The inventory is warmed when the composer first appears, never on a
        // keystroke: the probe is a process spawn, and paying it on `/` would put
        // half a second between the sigil and the list.
        controller?.adopt(inventory: await appState.fetchCompletions(terminalID: terminal.id))
    }

    // MARK: - Commands

    /// Every command gets a fresh token, including two consecutive `.clear`s:
    /// two commands sharing one is the single way to lose a write.
    private func issue(_ kind: ComposerCommand.Kind) {
        commandToken += 1
        command = ComposerCommand(token: commandToken, kind: kind)
    }

    // MARK: - Completion

    /// What one menu key does, given whether a row is highlighted.
    ///
    /// Pure and named so the Enter/Tab split is assertable: it is the difference
    /// between a composer that sends what a person typed and one that quietly
    /// replaces it with a command they never chose.
    enum MenuOutcome: Equatable {
        case moveUp
        case moveDown
        case close
        /// Take `acceptTarget` — the highlighted row, or the first.
        case accept
        /// Send the text as typed.
        case submit
        /// Not a menu key at all.
        case ignore
    }

    static func menuOutcome(
        for action: ComposerKeyRouter.Action, selectedIndex: Int?
    ) -> MenuOutcome {
        switch action {
        case .menuUp: return .moveUp
        case .menuDown: return .moveDown
        case .menuClose: return .close
        case .menuAccept:
            // Tab. Its whole meaning is "take the obvious one", so it accepts
            // `acceptTarget` whether or not anything is highlighted.
            return .accept
        case .menuAcceptOrSubmit:
            // Return. It accepts only a row the person actually arrowed to;
            // otherwise the message goes as typed. `selectedIndex` is nil
            // mid-sentence, on a non-prefix query, and while the inventory is
            // still loading — every case where a fallback to `rows.first` would
            // be a guess at what somebody meant.
            return selectedIndex == nil ? .submit : .accept
        case .submit, .newline, .blur, .passThrough:
            return .ignore
        }
    }

    private func handleMenu(_ action: ComposerKeyRouter.Action) {
        guard let controller else { return }
        switch Self.menuOutcome(for: action, selectedIndex: controller.selectedIndex) {
        case .moveUp: controller.moveUp()
        case .moveDown: controller.moveDown()
        case .close: controller.close(suppressingCurrentToken: true)
        case .accept:
            if let row = controller.acceptTarget { accept(row) }
        case .submit: submit(currentText())
        case .ignore: break
        }
    }

    private func accept(_ row: CommandRanker.Row) {
        guard let controller, let match = controller.match else { return }
        // A trailing space, so the argument hint renders as an inline placeholder
        // and the menu closes because the token ended.
        issue(.replaceRange(
            match.tokenRange, with: Self.sigil(match.kind) + row.command.name + " "))
        controller.recordAcceptance(row)
    }

    private static func sigil(_ kind: CompletionTrigger.Kind) -> String {
        switch kind {
        case .command: return "/"
        case .mention: return "@"
        }
    }

    // MARK: - Attachments

    /// Write one prepared PNG into this worktree's attachment directory.
    ///
    /// **Atomic, and the directory first.** The token that names this file is
    /// inserted into the message the moment this returns, so a half-written file
    /// behind it would be sent as a broken path. The path is derived from
    /// `TBDConstants`, which is what makes `TBD_HOME` and the test fence apply;
    /// the id is minted per write, so a second image can never overwrite a first.
    static func writeAttachment(
        _ png: Data,
        worktreeID: UUID,
        attachmentID: UUID = UUID(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> (id: UUID, path: String) {
        let directory = TBDConstants.attachmentsDir(
            worktreeID: worktreeID, environment: environment)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let path = TBDConstants.attachmentPath(
            worktreeID: worktreeID, attachmentID: attachmentID, environment: environment)
        try png.write(to: URL(fileURLWithPath: path), options: [.atomic])
        return (attachmentID, path)
    }

    private func stage(_ data: Data) {
        do {
            let prepared = try ComposerImagePreparer.preparePNG(from: data)
            // A write that fails prevents the send — the token would otherwise
            // point at a file that is not there.
            let staged = try Self.writeAttachment(prepared, worktreeID: worktree.id)
            insertToken(draft.stage(path: staged.path, id: staged.id))
            errorMessage = nil
        } catch {
            errorMessage = "That image could not be attached: \(error.localizedDescription)"
        }
    }

    private func insertToken(_ number: Int) {
        issue(.insertAtCaret(ComposerTokens.text(for: number)))
    }

    private func reveal(_ number: Int) {
        guard let path = draft.pathsByNumber[number] else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func removeAttachment(_ number: Int) {
        draft.removeAttachment(number: number)
        // Remove its token from the text too, so the strip and the message agree.
        let token = ComposerTokens.text(for: number)
        if let range = (draft.text as NSString).range(of: token).toOptional() {
            issue(.replaceRange(range, with: ""))
        }
    }

    // MARK: - Sending

    /// The text view's own string, never a struct SwiftUI can leave a keystroke
    /// behind. The draft is the fallback for the moment before the view exists.
    private func currentText() -> String {
        (textViewHandle as? NSTextView)?.string ?? draft.text
    }

    private func submit(_ text: String) {
        // A Return must not do what a disabled button cannot.
        guard state.isEnabled, !isSending, let coordinator else { return }
        draft.text = text
        errorMessage = nil
        isSending = true
        Task { @MainActor in
            defer { isSending = false }
            let outcome = await coordinator.send(
                text: text, paths: draft.pathsByNumber, state: state,
                terminalID: terminal.id, worktreeID: worktree.id)
            switch outcome {
            case .sent, .woke:
                draft.clear()
                issue(.clear)
            case .failed(let message):
                // The text stays exactly where it is; only the banner changes.
                errorMessage = message
            }
        }
    }

    // MARK: - Chrome

    @ViewBuilder
    private var sendButton: some View {
        Button {
            submit(currentText())
        } label: {
            if isSending {
                ProgressView().controlSize(.small)
            } else {
                Text(Self.sendButtonLabel(state: state, terminalLabel: terminal.label))
            }
        }
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!state.isEnabled || isSending)
        .help(Self.sendButtonHelp(state: state))
    }

    /// The button names the target, so an injection is never anonymous.
    static func sendButtonLabel(state: ComposerState, terminalLabel: String?) -> String {
        let name = terminalLabel ?? "Claude"
        switch state {
        case .notRunning: return "Resume \(name)"
        case .running, .blocked, .hidden: return "Send to \(name)"
        }
    }

    static func sendButtonHelp(state: ComposerState) -> String {
        switch state {
        case .notRunning:
            return "Claude is not running here. Sending resumes the session with this "
                + "message as its first prompt. Images are sent as file paths for Claude to "
                + "read, not as attachments."
        case .running, .blocked, .hidden:
            return "Return sends, Shift+Return breaks the line."
        }
    }

    /// One wake path, two sentences: a session that left on its own reads
    /// differently from one TBD parked, and that is the only difference.
    static func notRunningNoteText(exited: Bool) -> String {
        exited
            ? "Claude exited in this terminal. Sending will resume the session."
            : "This session is hibernated. Sending will resume it."
    }

    @ViewBuilder
    private func blockedBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            Text(message).font(.caption).lineLimit(2)
            Spacer(minLength: 0)
            Button("Reveal Terminal") {
                appState.revealTerminal(terminalID: terminal.id)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }
}

private extension NSRange {
    /// `NSString.range(of:)` reports `NSNotFound` rather than nil.
    func toOptional() -> NSRange? { location == NSNotFound ? nil : self }
}
