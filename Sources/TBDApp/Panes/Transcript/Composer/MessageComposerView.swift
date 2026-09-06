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
    @State private var handle = ComposerViewHandle()

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
                onFocusToken: { focusToken($0) },
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
                        (handle.view as? ComposerTextView)?.argumentHint =
                            ComposerArgumentHint.hint(
                                text: text, selectionLocation: caret,
                                commands: controller?.inventoryCommands ?? [])
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
            // The flag first, and unconditionally: it is what stops a
            // registration still sitting in the deferred queue from installing a
            // dead view as this terminal's focus target.
            handle.isGone = true
            guard let view = handle.view else { return }
            appState.unregisterComposerView(view, for: terminal.id)
            handle.view = nil
        }
        .task(id: terminal.id) { await setUp() }
    }

    // MARK: - Set-up

    /// The text view hands itself out once, from `makeNSView`. Registration is
    /// deferred off that call because it mutates observable state, and SwiftUI
    /// treats a state write during a view update as undefined behavior.
    ///
    /// **The handle itself is not deferred.** It lives in a reference box written
    /// synchronously here, so a teardown landing inside the one-turn gap still
    /// has a view to unregister — and still gets to veto the registration that
    /// has not run yet. `registerComposerView` has no newer-wins guard (only
    /// `unregisterComposerView` does), so a late registration would silently
    /// install a view whose pane is gone as this terminal's focus target, and
    /// Cmd+/ would put the caret nowhere.
    private func adopt(_ view: NSView) {
        handle.view = view
        // A freshly made view is a new life for this box, whatever the last one
        // ended in.
        handle.isGone = false
        Task { @MainActor in
            guard !handle.isGone, view.window != nil else { return }
            appState.registerComposerView(view, for: terminal.id)
        }
    }

    private func setUp() async {
        // A banner belongs to the terminal it was raised for; carrying it across
        // a switch would blame the new session for the old one's refusal.
        errorMessage = nil
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
        // Restore the draft into the view — the one write the one-way contract
        // admits, as an explicit one-shot command.
        issue(Self.restoreCommand(draftText: draft.text))
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

    /// What a composer handed a terminal does to the text view it is **reusing**.
    ///
    /// An empty draft is a command too. The `NSTextView` survives a switch from
    /// one terminal to the next, so restoring only non-empty drafts leaves the
    /// previous terminal's half-written message sitting in the box — addressed,
    /// after the switch, to somebody else.
    static func restoreCommand(draftText: String) -> ComposerCommand.Kind {
        draftText.isEmpty ? .clear : .restore(draftText)
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

    /// Where the caret goes when an **attached** thumbnail is clicked: onto that
    /// image's own token.
    ///
    /// The token is replaced with itself, which is how the one-shot command
    /// vocabulary spells "put the caret here" — `.replaceRange` leaves the
    /// insertion point after what it inserted, so the text is unchanged
    /// character for character and the caret lands at the end of the token that
    /// was clicked. A person clicking a thumbnail that is in the message is
    /// asking where in the sentence it sits, which is a question only the caret
    /// can answer; the strip carries no second gesture that could mean anything
    /// else.
    static func caretCommand(text: String, number: Int) -> ComposerCommand.Kind? {
        guard let token = ComposerTokens.scan(text).first(where: { $0.number == number })
        else { return nil }
        return .replaceRange(token.range, with: ComposerTokens.text(for: number))
    }

    /// The one command that strips **every** occurrence of one image token.
    ///
    /// One command rather than one per occurrence: the view holds a single
    /// pending instruction, so two issued in the same turn collapse and only the
    /// last would ever reach the text view. The span from the first occurrence to
    /// the last is rewritten in one go instead, with the tokens inside it removed
    /// back to front so the earlier offsets stay valid, and nothing outside the
    /// span is touched. A duplicated token is ordinary — re-inserting an image
    /// twice is how a person refers to it twice — and leaving the second copy
    /// behind would send a path for an image the strip no longer lists.
    static func removalCommand(text: String, number: Int) -> ComposerCommand.Kind? {
        let ranges = ComposerTokens.scan(text)
            .filter { $0.number == number }
            .map(\.range)
        guard let first = ranges.first, let last = ranges.last else { return nil }
        let span = NSRange(
            location: first.location,
            length: last.location + last.length - first.location)
        var replacement = (text as NSString).substring(with: span) as NSString
        for range in ranges.reversed() {
            replacement = replacement.replacingCharacters(
                in: NSRange(location: range.location - span.location, length: range.length),
                with: "") as NSString
        }
        return .replaceRange(span, with: replacement as String)
    }

    private func focusToken(_ number: Int) {
        guard let kind = Self.caretCommand(text: currentText(), number: number)
        else { return }
        issue(kind)
        appState.focusComposer(terminalID: terminal.id)
    }

    private func removeAttachment(_ number: Int) {
        // The text first: the strip's own map is what `currentText()` is read
        // against, and removing the image before the token would leave the
        // command scanning for a number that is already gone.
        let kind = Self.removalCommand(text: currentText(), number: number)
        draft.removeAttachment(number: number)
        // Remove its tokens from the text too, so the strip and the message agree.
        if let kind { issue(kind) }
    }

    // MARK: - Sending

    /// The text view's own string, never a struct SwiftUI can leave a keystroke
    /// behind. The draft is the fallback for the moment before the view exists.
    private func currentText() -> String {
        (handle.view as? NSTextView)?.string ?? draft.text
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

/// The composer's text view, and whether its pane has gone.
///
/// A reference box rather than `@State` for one reason: both facts are written
/// from places a view update forbids state writes in — `makeNSView`, and the
/// deferred turn after it — and both must be readable by `onDisappear`, which can
/// land between the two. Nothing here drives rendering, so nothing needs to
/// invalidate the view.
@MainActor
final class ComposerViewHandle {
    var view: NSView?
    /// Set by `onDisappear`. A registration still queued when this flips must not
    /// run: the pane it belongs to is already gone.
    var isGone = false
}
