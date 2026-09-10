import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

/// What the holder transport's ONE write can and cannot frame.
///
/// A single body of text — one line or many — composes into that write cleanly:
/// `HolderSendComposition` wraps it in `ESC[200~`…`ESC[201~` when the child's
/// bracketed-paste mode calls for it and puts the submitting `\r` after the end
/// marker, which is the same "the Enter is provably outside the paste" property
/// the tmux arm gets from pasting and pressing Enter as two separate acts. So a
/// multi-line message is DELIVERED here, not refused.
///
/// What is still refused is a message that is more than one body: several
/// parts, or a lone image whose write would also have to carry the dispatch
/// envelope attributing the turn. The tmux arm frames those as separate pastes;
/// this transport has only the one write, and how a single write could frame a
/// multi-body message is out of scope until a spec settles it.
@Suite("holder composite send: what one write can frame")
struct HolderCompositeSendRefusalTests {

    /// `ESC [ 2 0 0 ~` — the start of a bracketed paste.
    private static let pasteStart = Data([0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e])
    /// `ESC [ 2 0 1 ~` — the end of a bracketed paste.
    private static let pasteEnd = Data([0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e])
    /// Carriage return: what `send-keys Enter` puts on a pty.
    private static let submitByte: UInt8 = 0x0d

    /// A child that has asked for bracketed paste, witnessed by the daemon's own
    /// live emulator — the reading that makes the composition wrap.
    private static func bracketingChild(_ on: Bool) -> TerminalModeReading {
        TerminalModeReading(
            modes: TerminalScreen.ChildModes(
                bracketedPaste: on, applicationCursor: false, alternateScreen: false),
            modesObserved: true,
            source: TerminalScreen.Source.daemon,
            ageMilliseconds: 0)
    }

    @Test func aPartsSendToAHolderRowIsRefused() async throws {
        let harness = try await SendHarness.make(transport: .holder)
        let response = try await harness.send(TerminalSendParams(
            terminalID: harness.terminal.id, submit: true,
            parts: [.text("a"), .imagePath("/tmp/a.png")]),
            actor: .app)

        #expect(!response.success)
        let error = try #require(response.error)
        #expect(error.contains("pty-holder"))
        #expect(error.contains("more than one part"))
        // The reworded refusal names the framing, not the old 64-byte cliff.
        #expect(error.contains("a single write"))
        #expect(!error.contains("64 bytes"))
    }

    /// **The multi-line send this suite used to prove was refused.**
    ///
    /// Discriminates against `origin/main`, where `performTerminalSend`'s
    /// composite gate matched `body.contains("\n")` and returned
    /// `holderCompositeRefusal` having written nothing. Here the message is
    /// delivered, in one write, wrapped — so the assertion is on the bytes, not
    /// on the absence of an error string.
    @Test func aMultiLineTextSendToAHolderRowIsDeliveredInOneWrappedWrite() async throws {
        let recorder = HolderWriteRecorder()
        let harness = try await SendHarness.make(
            transport: .holder, holderDeliveryRecorder: { recorder.record($0) })
        harness.router.holderModeOracle = { _ in Self.bracketingChild(true) }

        let response = try await harness.send(TerminalSendParams(
            terminalID: harness.terminal.id, text: "line one\nline two", submit: true),
            actor: .app)

        #expect(response.success, "error was: \(response.error ?? "none")")
        #expect(recorder.writes.count == 1, "the whole send is one message")
        let data = try #require(recorder.writes.first)
        #expect(data.starts(with: Self.pasteStart))
        #expect(data.last == Self.submitByte)
        // The submitting carriage return sits AFTER the end marker — the whole
        // point of the wrapping, and a substring check could not see it.
        let tail = data.suffix(Self.pasteEnd.count + 1)
        #expect(Data(tail) == Self.pasteEnd + Data([Self.submitByte]))
        let inner = data
            .dropFirst(Self.pasteStart.count)
            .dropLast(Self.pasteEnd.count + 1)
        let body = String(decoding: inner, as: UTF8.self)
        #expect(body.hasPrefix("<tbd-dispatch"))
        #expect(body.hasSuffix("\nline one\nline two"))
    }

    /// **Both transports carry the same message.** The tmux arm pastes the
    /// composed body and then presses Enter; the holder arm writes the same
    /// composed body wrapped, with the same Enter after the end marker. Asserted
    /// side by side, with the envelope's first line dropped from each because it
    /// carries that harness's own actuation id.
    ///
    /// Discriminates: on `origin/main` the holder leg is refused and writes
    /// nothing, so there is no body to compare.
    @Test func aMultiLineSendCarriesTheSameMessageOnBothTransports() async throws {
        let params = { (id: UUID) in
            TerminalSendParams(terminalID: id, text: "line one\nline two", submit: true)
        }

        let tmuxHarness = try await SendHarness.make(transport: .tmux)
        #expect(try await tmuxHarness.send(params(tmuxHarness.terminal.id), actor: .app).success)
        #expect(tmuxHarness.tmux.pastedBodies.count == 1)
        #expect(tmuxHarness.tmux.sentKeys == ["Enter"])
        let tmuxBody = try #require(tmuxHarness.tmux.pastedBodies.first)

        let recorder = HolderWriteRecorder()
        let holderHarness = try await SendHarness.make(
            transport: .holder, holderDeliveryRecorder: { recorder.record($0) })
        holderHarness.router.holderModeOracle = { _ in Self.bracketingChild(true) }
        #expect(
            try await holderHarness.send(params(holderHarness.terminal.id), actor: .app).success)
        let data = try #require(recorder.writes.first)
        let holderBody = String(
            decoding: data.dropFirst(Self.pasteStart.count)
                .dropLast(Self.pasteEnd.count + 1),
            as: UTF8.self)

        // Everything after the envelope line, which is the caller's message
        // verbatim on both transports.
        #expect(
            String(holderBody.drop(while: { $0 != "\n" }))
                == String(tmuxBody.drop(while: { $0 != "\n" })))
        #expect(String(holderBody.drop(while: { $0 != "\n" })) == "\nline one\nline two")
    }

    /// A child that never asked for bracketing gets bare bytes — markers it does
    /// not understand are markers it prints. The multi-line body still goes.
    @Test func aMultiLineSendToAChildWithBracketingOffIsBare() async throws {
        let recorder = HolderWriteRecorder()
        let harness = try await SendHarness.make(
            transport: .holder, kind: .shell,
            holderDeliveryRecorder: { recorder.record($0) })
        harness.router.holderModeOracle = { _ in Self.bracketingChild(false) }

        let response = try await harness.send(TerminalSendParams(
            terminalID: harness.terminal.id, text: "one\ntwo", submit: true),
            actor: .app)

        #expect(response.success, "error was: \(response.error ?? "none")")
        // A shell carries no envelope, so this is the whole message.
        #expect(try #require(recorder.writes.first) == Data("one\ntwo\r".utf8))
    }

    /// A single-part, single-line message is exactly what the holder arm can
    /// carry today, and must still go through. Without this the suite could be
    /// green on a refusal that rejects every holder send. Wired with the same
    /// `holderDeliveryRecorder` seam the `.parts` tests below use, so this
    /// asserts the exact bytes delivered rather than only "got past the gate".
    @Test func aSingleLineTextSendToAHolderRowIsNotRefused() async throws {
        let recorder = HolderWriteRecorder()
        let harness = try await SendHarness.make(
            transport: .holder, holderDeliveryRecorder: { recorder.record($0) })
        let response = try await harness.send(TerminalSendParams(
            terminalID: harness.terminal.id, text: "hello", submit: true),
            actor: .app)

        let error = response.error ?? ""
        #expect(!error.contains("more than one part"))
        #expect(response.success, "error was: \(error)")
        // `actor: .app` against a `.claude` row carries the dispatch envelope —
        // mirroring the exact assertion `aSinglePartTextSendToAHolderRowIsNotRefused`
        // makes for its single text part, since both paths converge on the same
        // `deliverHolderText` call. No oracle is installed, so nothing answered
        // and the composition goes bare.
        #expect(recorder.writes.count == 1)
        let body = String(bytes: try #require(recorder.writes.first), encoding: .utf8) ?? ""
        #expect(body.hasPrefix("<tbd-dispatch"))
        #expect(body.hasSuffix("\nhello\r"))
    }

    /// A single-part `.parts` payload is exactly the remainder that reaches
    /// `performHolderSend`'s `.parts` arm once the composite gate above has
    /// turned away anything bigger — and a single text part is delivered the
    /// same way `--text` delivers a body. Modeled on
    /// `aSingleLineTextSendToAHolderRowIsNotRefused`: SendHarness wires a real
    /// (test-only) injection courier here, so this asserts the exact bytes
    /// delivered rather than only "got past the gate".
    @Test func aSinglePartTextSendToAHolderRowIsNotRefused() async throws {
        let recorder = HolderWriteRecorder()
        let harness = try await SendHarness.make(
            transport: .holder, holderDeliveryRecorder: { recorder.record($0) })
        let response = try await harness.send(TerminalSendParams(
            terminalID: harness.terminal.id, submit: true, parts: [.text("hello")]),
            actor: .app)

        let error = response.error ?? ""
        #expect(!error.contains("more than one part"))
        #expect(!error.contains("parts"))
        #expect(response.success, "error was: \(error)")
        // `actor: .app` against a `.claude` row carries the dispatch envelope,
        // exactly as the `.text` arm's body would — this single-part `.parts`
        // send is deliberately delivered the same way, envelope included.
        #expect(recorder.writes.count == 1)
        let body = String(bytes: try #require(recorder.writes.first), encoding: .utf8) ?? ""
        #expect(body.hasPrefix("<tbd-dispatch"))
        #expect(body.hasSuffix("\nhello\r"))
    }

    /// A single text part may itself be multi-line, and takes the same wrapped
    /// write the `.text` arm takes — the two arms converge on `deliverHolderText`.
    ///
    /// Discriminates: on `origin/main` the composite gate matched a newline
    /// inside a `.parts` payload too, so this was refused.
    @Test func aSingleMultiLineTextPartIsDelivered() async throws {
        let recorder = HolderWriteRecorder()
        let harness = try await SendHarness.make(
            transport: .holder, holderDeliveryRecorder: { recorder.record($0) })
        harness.router.holderModeOracle = { _ in Self.bracketingChild(true) }

        let response = try await harness.send(TerminalSendParams(
            terminalID: harness.terminal.id, submit: true, parts: [.text("one\ntwo")]),
            actor: .app)

        #expect(response.success, "error was: \(response.error ?? "none")")
        let data = try #require(recorder.writes.first)
        #expect(data.starts(with: Self.pasteStart))
        #expect(Data(data.suffix(Self.pasteEnd.count + 1))
            == Self.pasteEnd + Data([Self.submitByte]))
        let body = String(
            decoding: data.dropFirst(Self.pasteStart.count).dropLast(Self.pasteEnd.count + 1),
            as: UTF8.self)
        #expect(body.hasSuffix("\none\ntwo"))
    }

    /// **An image-only send that would carry an envelope is refused here.**
    ///
    /// The holder arm writes the whole message in ONE write, and that one write
    /// cannot carry both a dispatch envelope and a bare image path: Claude Code
    /// attaches an image only when the whole paste is the quoted path and
    /// nothing else (measured on 2.1.261), so prefixing it attaches nothing —
    /// and dropping the envelope instead would let any local process submit an
    /// unattributed user turn carrying an image. The tmux arm escapes the
    /// dilemma by pasting the envelope separately; this transport has no second
    /// write to give, and how one write could frame both is out of scope until a
    /// spec settles it.
    ///
    /// `connection: nil` (unauthenticated, asking for no suppression) is the
    /// disposition an envelope attaches under.
    @Test func anUnauthenticatedSingleImagePartSendToAHolderRowIsRefused() async throws {
        let recorder = HolderWriteRecorder()
        let harness = try await SendHarness.make(
            transport: .holder, holderDeliveryRecorder: { recorder.record($0) })
        let response = try await harness.send(
            TerminalSendParams(
                terminalID: harness.terminal.id, submit: true, parts: [.imagePath("/tmp/a.png")]),
            actor: .app, connection: nil)

        #expect(!response.success)
        let error = try #require(response.error)
        #expect(error.contains("pty-holder"))
        #expect(error.contains("image"))
        // The reworded out-of-scope note: framing, not the retired byte cliff.
        #expect(error.contains("a single write"))
        #expect(!error.contains("unwrapped write"))
        #expect(recorder.writes.isEmpty, "nothing may be written")
    }

    /// The other branch: an authenticated connection that asked for suppression
    /// carries no envelope, so the one write is the bare quoted path and the
    /// image attaches exactly as it does on tmux.
    @Test func anAuthenticatedSingleImagePartSendToAHolderRowIsDelivered() async throws {
        let recorder = HolderWriteRecorder()
        let harness = try await SendHarness.makeAuthenticated(
            transport: .holder, holderDeliveryRecorder: { recorder.record($0) })
        let response = try await harness.send(
            TerminalSendParams(
                terminalID: harness.terminal.id, submit: true,
                parts: [.imagePath("/tmp/a.png")], envelope: .suppressed),
            actor: .app, connection: SendHarness.AuthenticatedApp.connection)

        #expect(response.success, "error was: \(response.error ?? "none")")
        #expect(recorder.writes.count == 1)
        let body = String(bytes: try #require(recorder.writes.first), encoding: .utf8) ?? ""
        #expect(!body.contains("<tbd-dispatch"))
        #expect(body == "'/tmp/a.png'\r")
    }

    /// A shell row carries no envelope whatever the disposition, so the same
    /// image-only send goes through unauthenticated — the refusal above belongs
    /// to the envelope that would otherwise have to share the write, not to
    /// image parts as such.
    @Test func anImageOnlySendToAHolderShellRowIsDelivered() async throws {
        let recorder = HolderWriteRecorder()
        let harness = try await SendHarness.make(
            transport: .holder, kind: .shell,
            holderDeliveryRecorder: { recorder.record($0) })
        let response = try await harness.send(
            TerminalSendParams(
                terminalID: harness.terminal.id, submit: true, parts: [.imagePath("/tmp/a.png")]),
            actor: .app, connection: nil)

        #expect(response.success, "error was: \(response.error ?? "none")")
        let body = String(bytes: try #require(recorder.writes.first), encoding: .utf8) ?? ""
        #expect(body == "'/tmp/a.png'\r")
    }

    /// **The rail disposition is not the effective one.** An authenticated
    /// suppression request must reach the holder arm too: before the fix
    /// `performHolderSend` was handed the RAIL disposition, so a composer send
    /// to a holder-backed row silently got the envelope the person asked to
    /// speak without.
    @Test func anAuthenticatedTextSendToAHolderRowCarriesNoEnvelope() async throws {
        let recorder = HolderWriteRecorder()
        let harness = try await SendHarness.makeAuthenticated(
            transport: .holder, holderDeliveryRecorder: { recorder.record($0) })
        let response = try await harness.send(
            TerminalSendParams(
                terminalID: harness.terminal.id, submit: true,
                parts: [.text("hello")], envelope: .suppressed),
            actor: .app, connection: SendHarness.AuthenticatedApp.connection)

        #expect(response.success, "error was: \(response.error ?? "none")")
        #expect(recorder.writes.count == 1)
        let body = String(bytes: try #require(recorder.writes.first), encoding: .utf8) ?? ""
        #expect(!body.contains("<tbd-dispatch"))
        #expect(body == "hello\r")
    }

    /// A tmux row is untouched by any of it.
    @Test func aTmuxRowStillAcceptsMultiLineAndParts() async throws {
        let harness = try await SendHarness.make(transport: .tmux)
        let multiline = try await harness.send(TerminalSendParams(
            terminalID: harness.terminal.id, text: "line one\nline two", submit: true),
            actor: .app)
        #expect(multiline.success, "error was: \(multiline.error ?? "none")")

        let parts = try await harness.send(TerminalSendParams(
            terminalID: harness.terminal.id, submit: true,
            parts: [.text("a"), .imagePath("/tmp/a.png")]),
            actor: .app)
        #expect(parts.success, "error was: \(parts.error ?? "none")")
    }
}

/// Collects the bytes `SendHarness`'s stubbed `HolderInjectionCourier` was
/// asked to write, when a test passes `holderDeliveryRecorder`. A lock-guarded
/// class, matching `SendHarness.TmuxDouble`, because the courier's
/// `writeDirectly` closure runs off the test's task.
private final class HolderWriteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _writes: [Data] = []
    var writes: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return _writes
    }
    func record(_ bytes: Data) {
        lock.lock()
        defer { lock.unlock() }
        _writes.append(bytes)
    }
}
