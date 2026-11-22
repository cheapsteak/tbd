import Foundation
import Testing
import GRDB
import DaemonTestSupport
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

/// A person's wake of a session parked on the tmux transport moves it to the
/// pty holder and wakes it there, in one step; a rail's wake moves nothing.
///
/// Driven through the router, with the holder spawn double behind the
/// coordinator, so what these prove is the composition: who moves a row, what
/// the wake answers when the move cannot happen, and that the wake which
/// follows a move resumes the same session on the holder. The move itself is
/// `TerminalTransportMigrator.migrate`, proved in
/// `TerminalTransportMigratorTests`; the coordinator's own refusal of a row
/// still on tmux, in `TmuxWakeBackstopTests`.
@Suite("Wake migrates a parked tmux row")
struct WakeMigratesParkedTmuxRowTests {
    private static let sessionID = "sess-wake-migrates"
    private static let server = "tbd-wake-migrates-test"

    /// Collects every delta the router publishes.
    private final class DeltaBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [StateDelta] = []
        func append(_ d: StateDelta) { lock.withLock { items.append(d) } }
        var all: [StateDelta] { lock.withLock { items } }
    }

    private struct Fixture {
        let db: TBDDatabase
        let router: RPCRouter
        let worktree: Worktree
        let holder: FakeHolderLaunch
        let deltas: DeltaBox
        let actuationLogPath: String
        let scratch: String

        func tearDown() { try? FileManager.default.removeItem(atPath: scratch) }

        /// Every row `terminalID` was published whole as, in order.
        func replaced(_ terminalID: UUID) -> [Terminal] {
            deltas.all.compactMap {
                if case .terminalReplaced(let t) = $0, t.id == terminalID { return t }
                return nil
            }
        }

        /// The outcome rows the actuation record holds, as JSON objects.
        func actuationOutcomes() throws -> [[String: Any]] {
            guard let contents = try? String(
                contentsOfFile: actuationLogPath, encoding: .utf8) else { return [] }
            return try contents
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { line in
                    try #require(try JSONSerialization.jsonObject(
                        with: Data(line.utf8)) as? [String: Any])
                }
                .filter { $0["kind"] as? String == "outcome" }
        }
    }

    /// A router whose coordinator wakes holder rows through the spawn double,
    /// on a worktree whose tmux server `probe` answers for.
    private static func makeFixture(
        probe: LeftoverTmuxServerProbe = .absent
    ) async throws -> Fixture {
        let scratch = fencedScratchRoot(prefix: "tbdwakemig")
        let wtPath = "\(scratch)/wt"
        let logDirectory = "\(scratch)/log"
        for dir in [wtPath, "\(scratch)/repo", logDirectory] {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)
        }
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "\(scratch)/repo", displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "tbd/wt",
            path: wtPath, tmuxServer: Self.server)

        let holder = FakeHolderLaunch()
        let registry = makeHolderRegistryDouble(launch: holder)
        var lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), hooks: HookResolver(),
            codexExecutableResolver: CodexLaunchTestStub.executableResolver,
            codexHomeEnsurer: CodexLaunchTestStub.homeEnsurer,
            leftoverTmuxProbe: probe)
        lifecycle.holderRegistry = registry

        let deltas = DeltaBox()
        let subscriptions = StateSubscriptionManager()
        subscriptions.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                deltas.append(delta)
            }
            return true
        }
        let actuationLogPath = "\(logDirectory)/actuations.jsonl"
        let router = RPCRouter(
            db: db, lifecycle: lifecycle, subscriptions: subscriptions,
            configDirManager: makeIsolatedConfigDirManager(tag: "wake-migrates"),
            codexExecutableResolver: CodexLaunchTestStub.executableResolver,
            codexHomeEnsurer: CodexLaunchTestStub.homeEnsurer,
            actuationLog: ActuationLog(path: actuationLogPath))
        router.holderRegistry = registry
        await router.hibernationCoordinator.setHolderRegistry(registry)
        return Fixture(
            db: db, router: router, worktree: worktree, holder: holder, deltas: deltas,
            actuationLogPath: actuationLogPath, scratch: scratch)
    }

    /// A row parked on tmux with its park complete: what startup reconcile
    /// leaves once a session's tmux server is gone.
    private static func parkedTmuxRow(
        _ f: Fixture, kind: TerminalKind = .claude, session: String = sessionID
    ) async throws -> Terminal {
        let created = try await f.db.terminals.create(
            worktreeID: f.worktree.id, tmuxWindowID: "@4", tmuxPaneID: "%4",
            label: kind == .codex ? TerminalLabel.codex : TerminalLabel.claudeCode,
            claudeSessionID: session, kind: kind, transport: .tmux)
        try await f.db.terminals.setHibernated(
            id: created.id, sessionID: session, reason: .recovery)
        let row = try #require(try await f.db.terminals.get(id: created.id))
        #expect(row.isParked && row.transport == .tmux, "the fixture is not a parked tmux row")
        return row
    }

    /// A row parked on tmux with its park still in flight
    /// (`pendingSessionIncarnationID` set): an earlier build's tmux hibernate
    /// left it so when its respawn failed after it had signalled the agent, so
    /// its session may still be running in tmux.
    private static func parkInFlightTmuxRow(_ f: Fixture) async throws -> Terminal {
        let created = try await f.db.terminals.create(
            worktreeID: f.worktree.id, tmuxWindowID: "@4", tmuxPaneID: "%4",
            label: TerminalLabel.claudeCode, claudeSessionID: Self.sessionID,
            kind: .claude, transport: .tmux)
        let live = try #require(try await f.db.terminals.get(id: created.id))
        _ = try #require(try await f.db.terminals.beginHibernatedShellRespawn(
            id: created.id, expectedState: TerminalHibernationSnapshot(terminal: live),
            reason: .auto))
        let row = try #require(try await f.db.terminals.get(id: created.id))
        #expect(row.isParked && row.pendingSessionIncarnationID != nil,
                "the fixture is not a row whose park is in flight")
        return row
    }

    /// The three requests that wake a parked row.
    enum Entry: CaseIterable, Sendable {
        case terminalWake
        case terminalResume
        case worktreeResume

        func request(_ row: Terminal, actor: ActuationActor?) throws -> RPCRequest {
            switch self {
            case .terminalWake:
                return try RPCRequest(
                    method: RPCMethod.terminalWake,
                    params: TerminalWakeParams(terminalID: row.id), actor: actor)
            case .terminalResume:
                return try RPCRequest(
                    method: RPCMethod.terminalResume,
                    params: TerminalResumeParams(terminalID: row.id), actor: actor)
            case .worktreeResume:
                return try RPCRequest(
                    method: RPCMethod.worktreeResume,
                    params: WorktreeResumeParams(worktreeID: row.worktreeID), actor: actor)
            }
        }
    }

    /// The row moved and woke on the holder as the same session: the same
    /// row, conversation and label, spawned through the holder seam, with the
    /// move published whole so a mounted pane stops reading tmux.
    private static func expectMovedAndResumed(
        _ row: Terminal, _ f: Fixture, command expected: String
    ) async throws {
        let after = try #require(try await f.db.terminals.get(id: row.id))
        #expect(after.transport == .holder, "the wake did not move the row")
        #expect(!after.isParked, "the moved row was not woken")
        #expect(after.claudeSessionID == row.claudeSessionID)
        #expect(after.label == row.label)
        #expect(after.kind == row.kind)
        #expect(f.holder.launches.count == 1)
        let launch = try #require(f.holder.launch(for: row.id), "nothing was spawned through the holder")
        #expect(after.holderPID == launch.handle.holderPID)
        let command = try #require(launch.commandLine)
        #expect(command.contains(expected), "the wake did not resume the session: \(command)")
        let replaced = f.replaced(row.id)
        #expect(replaced.first?.transport == .holder, "the move was not published: \(replaced)")
    }

    // MARK: - Who moves a row

    /// Every actor that is not the daemon is a person's request, a kind a
    /// newer client declares and no declared actor included; every daemon
    /// actor is a rail, whatever its rail name.
    @Test("only a daemon actor's wake leaves a parked tmux row where it is")
    func everyKindButDaemonIsPersonStarted() throws {
        let session = try #require(ActuationActor.session(
            worktree: UUID().uuidString, terminal: UUID().uuidString))
        let people: [ActuationActor?] = [
            nil, .app, .phone(deviceID: UUID()), session, .anonymous,
            ActuationActor(kind: "declared-by-a-newer-client"),
        ]
        for actor in people {
            #expect(TransportMigrationOnWake.isPersonStarted(actor),
                    "\(actor?.kind ?? "no actor") does not move a parked tmux row")
        }
        let rails: [String?] = [
            nil, ActuationRail.sessionRestore, ActuationRail.limitResume,
            ActuationRail.queuedPrompt, ActuationRail.reconcile, ActuationRail.autoHibernate,
        ]
        for rail in rails {
            #expect(!TransportMigrationOnWake.isPersonStarted(.daemon(rail: rail)),
                    "the \(rail ?? "unnamed") rail moves a parked tmux row")
        }
    }

    /// No declared actor reads as a person's, which moves a parked tmux row,
    /// so a caller inside the daemon that forgot to name its actor would move
    /// rows as a person. The handlers take the actor with no default, so
    /// leaving it out does not compile; this pins what each caller passes,
    /// and that no default comes back.
    ///
    /// A rail passes `.daemon(...)`. The socket dispatch passes the actor the
    /// client declared, the handlers forward their own caller's, and the
    /// phone surface passes the phone's, which is a person's gesture. Anything
    /// else is reported, so a new caller is a decision rather than a default.
    ///
    /// A default for `actor` is reported too, wherever it would let a caller
    /// leave the actor out: on an entry point's own declaration, and on any
    /// function that forwards its `actor` to one, which is how a wrapper in a
    /// file allowed to forward `actor` would hand a person's wake to a caller
    /// that never named one. So is a forwarded `actor` that no function around
    /// the call takes as a parameter: a local `let actor` in an allowed file
    /// names nobody's actor. A source pin, because the property is about every
    /// call site.
    ///
    /// The scan reads each file with its comments and strings blanked
    /// (`codeOnly`), and takes the function a call is in from the braces, so
    /// a `func ` in a comment or a string, or a local function closed before
    /// the call, is not read as the call's function. What it does not see: a
    /// local binding that shadows the parameter (`let actor = ...` in the
    /// body), and a closure parameter named `actor`. Both would pass as the
    /// enclosing function's parameter.
    @Test("every caller inside the daemon names the actor it wakes for")
    func everyInProcessWakeCallerNamesItsActor() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/TBDDaemonTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let entryPoints = [
            "handleTerminalWake", "handleTerminalResume", "handleWorktreeResume",
            "moveParkedTmuxRowBeforeWake", "holdWakeIfDenied",
        ]
        let files = FileManager.default.enumerator(
            at: root.appendingPathComponent("Sources/TBDDaemon"), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        var scanned = 0
        var calls: [String] = []
        var offenders: [String] = []
        var declarations: [String] = []
        var forwarders: [String] = []
        var defaulted: [String] = []
        for file in files {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            scanned += 1
            guard entryPoints.contains(where: { source.contains($0) }) else { continue }
            let text = Self.codeOnly(source)
            let fileName = file.lastPathComponent
            for entryPoint in entryPoints {
                for parameters in Self.declaredParameters(of: entryPoint, in: text) {
                    declarations.append("\(fileName): \(entryPoint)")
                    if Self.defaultsActor(parameters) {
                        defaulted.append("\(fileName): func \(entryPoint)")
                    }
                }
                for call in Self.calls(of: entryPoint, in: text) {
                    let site = "\(fileName): \(entryPoint)(\(call.arguments))"
                    calls.append(site)
                    let actor = Self.argument("actor", in: call.arguments)
                    if !Self.isAllowedWakeActor(actor, file: fileName) {
                        offenders.append(site)
                    }
                    guard actor == "actor" else { continue }
                    guard let binding = Self.actorBinding(at: call.start, in: text) else {
                        offenders.append("\(site), whose `actor` no function around the call takes as a parameter")
                        continue
                    }
                    forwarders.append("\(fileName): \(binding.name)")
                    if Self.defaultsActor(binding.parameters) {
                        defaulted.append("\(fileName): func \(binding.name), which passes its actor to \(entryPoint)")
                    }
                }
            }
        }

        #expect(scanned > 100, "the source scan found almost nothing to read — it is passing vacuously")
        #expect(calls.count >= 11, "the scan missed calls it should find: \(calls)")
        #expect(offenders.isEmpty,
                "these wake or resume without naming a rail, the client's actor or the phone's: \(offenders.joined(separator: "; "))")
        #expect(declarations.count == entryPoints.count,
                "the scan did not find each entry point declared once: \(declarations)")
        #expect(Set(forwarders).isSuperset(of: [
            "RPCRouter+HibernationHandlers.swift: handleTerminalWake",
            "RPCRouter+ManualSuspendHandlers.swift: handleTerminalResume",
            "RPCRouter+ManualSuspendHandlers.swift: handleWorktreeResume",
        ]), "the scan missed a handler that forwards its actor: \(forwarders)")
        #expect(defaulted.isEmpty,
                "these give the actor a wake runs for a default, so a caller can leave it out: \(defaulted.joined(separator: "; "))")
    }

    /// The scan's reading of a declaration's `actor` parameter, on the shapes
    /// a default can take and the ones that are not defaults, so a scan that
    /// stopped recognising one would not pass by finding nothing.
    @Test("the source scan tells a defaulted actor parameter from one without a default")
    func theSourceScanReadsActorDefaults() throws {
        let written = """
            func handleTerminalWake(
                _ paramsData: Data, actor: ActuationActor? = nil,
                condition: SessionRestoreCondition? = nil
            ) async throws -> RPCResponse {
                // func holdWakeIfDenied(actor: ActuationActor? = nil)
                let held = await holdWakeIfDenied(actuationID, actor: actor, terminalID: id)
            }
            func holdWakeIfDenied(_ id: String, by actor: ActuationActor = .anonymous) async {}
            func moveParkedTmuxRowBeforeWake(_ id: String, actor: ActuationActor?, terminalID: UUID) {}
            """
        let source = Self.codeOnly(written)
        #expect(Self.declaredParameters(of: "handleTerminalWake", in: source).map(Self.defaultsActor) == [true])
        #expect(Self.declaredParameters(of: "holdWakeIfDenied", in: source).map(Self.defaultsActor) == [true])
        #expect(Self.declaredParameters(of: "moveParkedTmuxRowBeforeWake", in: source)
            .map(Self.defaultsActor) == [false])
        let calls = Self.calls(of: "holdWakeIfDenied", in: source)
        #expect(calls.count == 1, "the scan read the declaration or the comment as a call: \(calls)")
        let call = try #require(calls.first)
        #expect(Self.argument("actor", in: call.arguments) == "actor")
        let binding = try #require(Self.actorBinding(at: call.start, in: source))
        #expect(binding.name == "handleTerminalWake")
        #expect(Self.defaultsActor(binding.parameters))
        #expect(!Self.defaultsActor("_ paramsData: Data, actor: ActuationActor?, condition: X? = nil"))
    }

    /// The scan's reading of which function an `actor` argument comes from,
    /// on the shapes that misled a nearest-`func` reading: a `func ` in a
    /// trailing comment or a string, and a local function closed before the
    /// call. A forwarded `actor` that no function around the call takes as a
    /// parameter has no binding, and one a local function captures from the
    /// function around it binds to that function.
    @Test("the source scan finds the function a forwarded actor comes from")
    func theSourceScanFindsTheActorsFunction() throws {
        let written = """
            func handleTerminalWake(_ paramsData: Data, actor: ActuationActor?) async {
                func describe(_ id: UUID) -> String { "func decoy(actor: ActuationActor) { \\(id) }" }
                let note = 1 // ends func decoy(actor: ActuationActor) {
                /* func decoy(actor: ActuationActor) { */
                await holdWakeIfDenied(id, actor: actor)
            }
            func railWake(_ id: String) async {
                let actor: ActuationActor? = nil
                await moveParkedTmuxRowBeforeWake(id, actor: actor, terminalID: id)
            }
            func outerWake(actor: ActuationActor?) async {
                func again() async {
                    await holdWakeIfDenied(id, actor: actor)
                }
            }
            """
        let source = Self.codeOnly(written)
        #expect(written.contains("decoy"))
        #expect(!source.contains("decoy"), "a comment or a string survived the blanking: \(source)")
        #expect(source.filter { $0 == "\n" }.count == written.filter { $0 == "\n" }.count)
        let holds = Self.calls(of: "holdWakeIfDenied", in: source)
        try #require(holds.count == 2)
        let handler = Self.enclosingFunctions(around: holds[0].start, in: source).map(\.name)
        #expect(handler == ["handleTerminalWake"], "a local function closed before the call was read as its function")
        #expect(Self.actorBinding(at: holds[0].start, in: source)?.name == "handleTerminalWake")
        let captured = Self.enclosingFunctions(around: holds[1].start, in: source).map(\.name)
        #expect(captured == ["again", "outerWake"])
        #expect(Self.actorBinding(at: holds[1].start, in: source)?.name == "outerWake")
        let moves = Self.calls(of: "moveParkedTmuxRowBeforeWake", in: source)
        let rail = try #require(moves.first)
        #expect(Self.argument("actor", in: rail.arguments) == "actor")
        #expect(Self.enclosingFunctions(around: rail.start, in: source).map(\.name) == ["railWake"])
        #expect(Self.actorBinding(at: rail.start, in: source)?.name == nil,
                "a local `let actor` passed for a function that takes none")
    }

    /// The actor each daemon file may pass to a wake or resume entry point.
    private static func isAllowedWakeActor(_ actor: String?, file: String) -> Bool {
        guard let actor else { return false }
        if actor.hasPrefix(".daemon(") { return true }
        switch file {
        case "RPCRouter.swift":
            return actor == "request.actor"
        case "RPCRouter+HibernationHandlers.swift", "RPCRouter+ManualSuspendHandlers.swift":
            return actor == "actor"
        case "RPCRouter+PhoneSessionActions.swift":
            return actor.hasPrefix(".phone(deviceID:")
        default:
            return false
        }
    }

    /// `text` with every comment and every string literal blanked to spaces,
    /// newlines kept, so the scan reads code alone: a `func ` in a trailing
    /// comment, or a parenthesis or brace inside a string, cannot pass for a
    /// declaration or upset the balancing the helpers below rely on. It reads
    /// line comments, nested block comments, single-line, multi-line and raw
    /// strings, and interpolations with strings nested inside them. It works
    /// on UTF-8 bytes: every delimiter is ASCII, and no byte of a multi-byte
    /// character is ASCII, so a character is blanked whole or not at all.
    /// Every helper below reads text this has passed over.
    private static func codeOnly(_ text: String) -> String {
        enum Context {
            /// Code; with `parens`, the code of an interpolation inside a
            /// string, with how many parentheses it has open.
            case code(parens: Int?)
            case blockComment(depth: Int)
            case string(hashes: Int, multiline: Bool)
        }
        let newline = UInt8(ascii: "\n"), slash = UInt8(ascii: "/"), star = UInt8(ascii: "*")
        let quote = UInt8(ascii: "\""), hash = UInt8(ascii: "#"), backslash = UInt8(ascii: "\\")
        let open = UInt8(ascii: "("), close = UInt8(ascii: ")")
        let bytes = Array(text.utf8)
        let count = bytes.count
        var output = bytes
        func blank(_ range: Range<Int>) {
            for index in range where bytes[index] != newline { output[index] = UInt8(ascii: " ") }
        }
        func run(of byte: UInt8, at start: Int, length: Int) -> Bool {
            start + length <= count && bytes[start..<(start + length)].allSatisfy { $0 == byte }
        }
        var stack: [Context] = [.code(parens: nil)]
        var index = 0
        while index < count {
            let byte = bytes[index]
            let next: UInt8? = index + 1 < count ? bytes[index + 1] : nil
            switch stack[stack.count - 1] {
            case .code(let parens):
                if byte == slash, next == slash {
                    var end = index
                    while end < count, bytes[end] != newline { end += 1 }
                    blank(index..<end)
                    index = end
                    continue
                }
                if byte == slash, next == star {
                    blank(index..<(index + 2))
                    stack.append(.blockComment(depth: 0))
                    index += 2
                    continue
                }
                if byte == hash || byte == quote {
                    var opening = index
                    while opening < count, bytes[opening] == hash { opening += 1 }
                    if opening < count, bytes[opening] == quote {
                        let multiline = run(of: quote, at: opening, length: 3)
                        let contentStart = opening + (multiline ? 3 : 1)
                        blank(index..<contentStart)
                        stack.append(.string(hashes: opening - index, multiline: multiline))
                        index = contentStart
                        continue
                    }
                }
                if let parens {
                    if byte == open {
                        stack[stack.count - 1] = .code(parens: parens + 1)
                    } else if byte == close {
                        if parens == 0 {
                            blank(index..<(index + 1))
                            stack.removeLast()
                            index += 1
                            continue
                        }
                        stack[stack.count - 1] = .code(parens: parens - 1)
                    }
                    blank(index..<(index + 1))
                }
                index += 1
            case .blockComment(let depth):
                if byte == slash, next == star {
                    blank(index..<(index + 2))
                    stack[stack.count - 1] = .blockComment(depth: depth + 1)
                    index += 2
                    continue
                }
                if byte == star, next == slash {
                    blank(index..<(index + 2))
                    if depth == 0 {
                        stack.removeLast()
                    } else {
                        stack[stack.count - 1] = .blockComment(depth: depth - 1)
                    }
                    index += 2
                    continue
                }
                blank(index..<(index + 1))
                index += 1
            case .string(let hashes, let multiline):
                if byte == backslash, run(of: hash, at: index + 1, length: hashes) {
                    let escaped = index + 1 + hashes
                    if escaped < count, bytes[escaped] == open {
                        blank(index..<(escaped + 1))
                        stack.append(.code(parens: 0))
                        index = escaped + 1
                        continue
                    }
                    blank(index..<min(escaped + 1, count))
                    index = escaped + 1
                    continue
                }
                let quotes = multiline ? 3 : 1
                if byte == quote, run(of: quote, at: index, length: quotes),
                   run(of: hash, at: index + quotes, length: hashes) {
                    blank(index..<(index + quotes + hashes))
                    stack.removeLast()
                    index += quotes + hashes
                    continue
                }
                blank(index..<(index + 1))
                index += 1
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Every mention of `name(` in `code` that is not part of a longer name,
    /// with whether `func ` precedes it on its line, which makes it the
    /// declaration rather than a call. `code` is `codeOnly`'s, so no comment
    /// or string is among them.
    private static func mentions(
        of name: String, in code: String
    ) -> [(start: String.Index, isDeclaration: Bool, arguments: String)] {
        var found: [(start: String.Index, isDeclaration: Bool, arguments: String)] = []
        var searchStart = code.startIndex
        while let match = code.range(of: name + "(", range: searchStart..<code.endIndex) {
            searchStart = match.upperBound
            if match.lowerBound > code.startIndex {
                let previous = code[code.index(before: match.lowerBound)]
                if previous.isLetter || previous.isNumber || previous == "_" { continue }
            }
            let lead = code[lineStart(of: match.lowerBound, in: code)..<match.lowerBound]
            found.append((
                start: match.lowerBound, isDeclaration: lead.hasSuffix("func "),
                arguments: balancedContents(from: match.upperBound, in: code)))
        }
        return found
    }

    /// The argument text of every call of `name` in `text`, with where the
    /// call starts, leaving out its declaration and longer names that end in
    /// it.
    private static func calls(
        of name: String, in text: String
    ) -> [(start: String.Index, arguments: String)] {
        mentions(of: name, in: text)
            .filter { !$0.isDeclaration }
            .map { (start: $0.start, arguments: $0.arguments) }
    }

    /// The parameter list of every declaration of `name` in `text`.
    private static func declaredParameters(of name: String, in text: String) -> [String] {
        mentions(of: name, in: text).filter(\.isDeclaration).map(\.arguments)
    }

    /// The name and parameter list of every function whose body holds
    /// `position`, innermost first. A function's body is the brace-balanced
    /// block after its signature, so a local function declared and closed
    /// before `position` is passed over rather than read as the function the
    /// position is in, and a declaration with no body of its own (a protocol
    /// requirement) is not credited with the next function's.
    private static func enclosingFunctions(
        around position: String.Index, in code: String
    ) -> [(name: String, parameters: String)] {
        var found: [(name: String, parameters: String)] = []
        var end = position
        while let keyword = code.range(of: "func ", options: .backwards, range: code.startIndex..<end) {
            end = keyword.lowerBound
            if keyword.lowerBound > code.startIndex {
                let previous = code[code.index(before: keyword.lowerBound)]
                if previous.isLetter || previous.isNumber || previous == "_" { continue }
            }
            guard let open = code[keyword.upperBound..<position].firstIndex(where: { $0 == "(" || $0 == "<" }),
                  let paren = code[open..<position].firstIndex(of: "(") else { continue }
            let parametersStart = code.index(after: paren)
            let parametersEnd = matchingClose(from: parametersStart, opening: "(", closing: ")", in: code)
            guard parametersEnd < code.endIndex,
                  let bodyOpen = code[parametersEnd...].firstIndex(of: "{") else { continue }
            let signatureTail = code[code.index(after: parametersEnd)..<bodyOpen]
            if ["func ", "}", "var ", "let "].contains(where: { signatureTail.contains($0) }) { continue }
            let bodyClose = matchingClose(from: code.index(after: bodyOpen), opening: "{", closing: "}", in: code)
            guard bodyOpen < position, position < bodyClose else { continue }
            let name = code[keyword.upperBound..<open].trimmingCharacters(in: .whitespaces)
            found.append((name: name, parameters: String(code[parametersStart..<parametersEnd])))
        }
        return found
    }

    /// The function an `actor` argument at `position` refers to: the
    /// innermost function around it that takes a parameter named `actor`,
    /// which a local function inside it captures. Nil when no function around
    /// the call takes one, so the `actor` passed there is a local binding.
    private static func actorBinding(
        at position: String.Index, in code: String
    ) -> (name: String, parameters: String)? {
        enclosingFunctions(around: position, in: code).first { declaresActor($0.parameters) }
    }

    /// What follows the colon of the parameter named `actor` in a parameter
    /// list (its type and any default), or nil when the list has none.
    private static func actorParameter(_ parameters: String) -> Substring? {
        for piece in topLevelPieces(parameters) {
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let names = trimmed[..<colon].split(separator: " ").map(String.init)
            guard names.last == "actor" else { continue }
            return Substring(trimmed[colon...])
        }
        return nil
    }

    /// Whether a parameter list takes a parameter named `actor`.
    private static func declaresActor(_ parameters: String) -> Bool {
        actorParameter(parameters) != nil
    }

    /// Whether a parameter list gives the parameter named `actor` a default.
    private static func defaultsActor(_ parameters: String) -> Bool {
        actorParameter(parameters)?.contains("=") ?? false
    }

    /// The text of the argument labelled `label` in a call's argument text,
    /// whitespace trimmed, or nil when the call has none.
    private static func argument(_ label: String, in arguments: String) -> String? {
        for piece in topLevelPieces(arguments) {
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix(label + ":") {
                return trimmed.dropFirst(label.count + 1)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    /// An argument or parameter list split at its top-level commas.
    private static func topLevelPieces(_ list: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var depth = 0
        for character in list {
            if "([{".contains(character) { depth += 1 }
            if ")]}".contains(character) { depth -= 1 }
            if character == ",", depth == 0 {
                pieces.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        pieces.append(current)
        return pieces
    }

    /// The text from `start`, just past an opening parenthesis, to the one
    /// that closes it.
    private static func balancedContents(from start: String.Index, in text: String) -> String {
        String(text[start..<matchingClose(from: start, opening: "(", closing: ")", in: text)])
    }

    /// Where the `closing` that matches an `opening` just before `start` is,
    /// or the end of `text` when none does.
    private static func matchingClose(
        from start: String.Index, opening: Character, closing: Character, in text: String
    ) -> String.Index {
        var depth = 1
        var cursor = start
        while cursor < text.endIndex {
            let character = text[cursor]
            if character == opening { depth += 1 }
            if character == closing { depth -= 1 }
            if depth == 0 { break }
            cursor = text.index(after: cursor)
        }
        return cursor
    }

    /// Where the line holding `index` starts.
    private static func lineStart(of index: String.Index, in text: String) -> String.Index {
        text[..<index].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
    }

    // MARK: - A person's wake

    /// The app's wake, by each request that wakes a parked row, moves it to
    /// the holder and resumes the same conversation there.
    @Test("a person's wake moves a parked tmux row to the holder and resumes it there",
          arguments: Entry.allCases)
    func aPersonsWakeMovesTheRowAndResumesIt(_ entry: Entry) async throws {
        let f = try await Self.makeFixture()
        defer { f.tearDown() }
        let row = try await Self.parkedTmuxRow(f)

        let response = await f.router.handle(try entry.request(row, actor: .app))

        #expect(response.success, "the wake failed: \(response.error ?? "")")
        try await Self.expectMovedAndResumed(
            row, f, command: "claude --resume \(Self.sessionID)")
    }

    /// The phone's wake is a person's too.
    @Test("the phone's wake moves a parked tmux row to the holder and resumes it there")
    func thePhonesWakeMovesTheRow() async throws {
        let f = try await Self.makeFixture()
        defer { f.tearDown() }
        let row = try await Self.parkedTmuxRow(f)

        let response = try await f.router.phoneWake(
            TerminalWakeParams(terminalID: row.id), deviceID: UUID())

        #expect(response.success, "the phone's wake failed: \(response.error ?? "")")
        try await Self.expectMovedAndResumed(
            row, f, command: "claude --resume \(Self.sessionID)")
    }

    /// A Codex tab with a recorded thread moves the same way, and its wake
    /// resumes the thread, not a Claude session.
    @Test("a person's wake moves a parked Codex tab and resumes its thread on the holder")
    func aParkedCodexTabIsMovedAndResumed() async throws {
        let f = try await Self.makeFixture()
        defer { f.tearDown() }
        let row = try await Self.parkedTmuxRow(f, kind: .codex, session: "acme-thread")
        #expect(row.recoveryResumePlan?.identity.agentKind == .codex)

        let response = await f.router.handle(try Entry.terminalWake.request(row, actor: .app))

        #expect(response.success, "the wake failed: \(response.error ?? "")")
        try await Self.expectMovedAndResumed(row, f, command: "resume 'acme-thread'")
        let command = try #require(f.holder.launch(for: row.id)?.commandLine)
        #expect(!command.contains("claude --resume"), "a Codex tab woke as Claude: \(command)")
    }

    // MARK: - A rail's wake

    /// A rail's wake moves nothing, by any request: the row stays parked on
    /// tmux, exactly as it was, and the wake answers with the coordinator's
    /// refusal that names the move. Session restore is the rail start
    /// admission checks, and limit resume one it does not.
    @Test("a rail's wake leaves a parked tmux row where it is",
          arguments: [ActuationRail.sessionRestore, ActuationRail.limitResume], Entry.allCases)
    func aRailsWakeMovesNothing(rail: String, entry: Entry) async throws {
        let f = try await Self.makeFixture()
        defer { f.tearDown() }
        let row = try await Self.parkedTmuxRow(f)

        let response = await f.router.handle(try entry.request(row, actor: .daemon(rail: rail)))

        #expect(response.errorCode == RPCErrorCode.terminalOnTmux.rawValue)
        #expect(response.error == HibernationCoordinator.tmuxWakeUnavailableReason(terminalID: row.id))
        #expect(try await f.db.terminals.get(id: row.id) == row, "a rail's wake changed the row")
        #expect(f.holder.launches.isEmpty, "a rail's wake started a holder")
        #expect(f.replaced(row.id).isEmpty, "a rail's wake published a move")
    }

    // MARK: - A move that cannot happen

    /// A row whose park is still in flight may still be running its agent in
    /// tmux, so while its server may run the move is refused, as
    /// `terminal.migrateTransport` refuses it, and the wake with it: nothing is
    /// rewritten and nothing is spawned. Every request that wakes a parked row
    /// answers with the move's refusal and closes its actuation exactly once:
    /// `worktree.resume` goes on to its next terminal without waking this one.
    @Test("a person's wake of a row whose park is in flight is refused while its server may run",
          arguments: Entry.allCases)
    func aParkInFlightRowIsRefusedWhileItsServerMayRun(_ entry: Entry) async throws {
        let f = try await Self.makeFixture(probe: LeftoverTmuxServerProbe { _ in .running })
        defer { f.tearDown() }
        let row = try await Self.parkInFlightTmuxRow(f)

        let response = await f.router.handle(try entry.request(row, actor: .app))

        #expect(response.errorCode == RPCErrorCode.terminalOnTmux.rawValue)
        #expect(response.error == LeftoverTmuxSession.stillRunningRefusal(
            terminalID: row.id, server: Self.server))
        #expect(try await f.db.terminals.get(id: row.id) == row, "a refused move rewrote the row")
        #expect(f.holder.launches.isEmpty, "a refused move started a holder")
        #expect(f.replaced(row.id).isEmpty, "a refused move published a move")
        let outcomes = try f.actuationOutcomes()
        #expect(outcomes.count == 1, "the actuation was not closed exactly once: \(outcomes)")
        #expect(outcomes.first?["result"] as? String == "refused")
        #expect(outcomes.first?["reason"] as? String == "not-eligible")
    }

    /// A row the move turns away for having nothing to resume is refused with
    /// that reason, which says what to do instead, and stays on tmux.
    @Test("a person's wake of a parked tmux row with nothing to resume is refused with the reason")
    func aRowWithNothingToResumeIsRefusedWithItsReason() async throws {
        let f = try await Self.makeFixture()
        defer { f.tearDown() }
        let parked = try await Self.parkedTmuxRow(f)
        let rowID = parked.id
        try await f.db.writerForTests.write { db in
            try db.execute(
                sql: "UPDATE terminal SET claudeSessionID = NULL WHERE id = ?",
                arguments: [rowID.uuidString])
        }
        let row = try #require(try await f.db.terminals.get(id: rowID))
        let skip = try #require(TransportMigrationEligibility.nothingToResumeSkip(row),
                                "the fixture is not a row with nothing to resume")

        let response = await f.router.handle(try Entry.terminalWake.request(row, actor: .app))

        #expect(response.errorCode == RPCErrorCode.terminalOnTmux.rawValue)
        #expect(response.error == skip)
        #expect(try await f.db.terminals.get(id: row.id) == row, "a refused move rewrote the row")
        #expect(f.holder.launches.isEmpty, "a refused move started a holder")
        #expect(f.replaced(row.id).isEmpty, "a refused move published a move")
        let outcomes = try f.actuationOutcomes()
        #expect(outcomes.count == 1, "the actuation was not closed exactly once: \(outcomes)")
        #expect(outcomes.first?["result"] as? String == "refused")
        #expect(outcomes.first?["reason"] as? String == "not-eligible")
    }

    /// A parked shell — one with no session, or one carrying the id a Claude
    /// started by hand inside it recorded — would move, but no wake resumes
    /// it on the holder either. So a person's wake does not move it: it is
    /// refused as its wake on the holder is refused, and the row stays on tmux
    /// exactly as it was, rather than moving and then staying asleep.
    @Test("a person's wake of a parked tmux shell is refused without moving it",
          arguments: [Entry.terminalWake, .terminalResume], [nil, "sess-hand-started"] as [String?])
    func aParkedShellIsRefusedWithoutMovingIt(entry: Entry, session: String?) async throws {
        let f = try await Self.makeFixture()
        defer { f.tearDown() }
        let created = try await f.db.terminals.create(
            worktreeID: f.worktree.id, tmuxWindowID: "@4", tmuxPaneID: "%4",
            label: TerminalLabel.shell, claudeSessionID: session, kind: .shell, transport: .tmux)
        try await f.db.terminals.setHibernated(
            id: created.id, sessionID: session ?? "sess-cleared", reason: .recovery)
        if session == nil {
            try await f.db.writerForTests.write { db in
                try db.execute(
                    sql: "UPDATE terminal SET claudeSessionID = NULL WHERE id = ?",
                    arguments: [created.id.uuidString])
            }
        }
        let row = try #require(try await f.db.terminals.get(id: created.id))
        #expect(row.isParked && row.transport == .tmux && row.recoveryResumePlan == nil,
                "the fixture is not a parked tmux shell with nothing to resume")
        #expect(TransportMigrationEligibility.nothingToResumeSkip(row) == nil,
                "the migration would skip the fixture, so it proves nothing about a shell it moves")

        let response = await f.router.handle(try entry.request(row, actor: .app))

        #expect(!response.success)
        #expect(response.error == (session == nil
            ? "No session ID to resume" : ClaudeResumeDecision.notAClaudeTabReason(.shell)))
        #expect(response.errorCode == nil)
        #expect(try await f.db.terminals.get(id: row.id) == row,
                "a wake that cannot resume the row moved it")
        #expect(f.holder.launches.isEmpty, "a refused wake started a holder")
        #expect(f.replaced(row.id).isEmpty, "a refused wake published a move")
        let outcomes = try f.actuationOutcomes()
        #expect(outcomes.count == 1, "the actuation was not closed exactly once: \(outcomes)")
        #expect(outcomes.first?["result"] as? String == "refused")
        #expect(outcomes.first?["reason"] as? String == "not-eligible")
    }

    /// A read of the row that fails is not a row that is absent or awake. A
    /// person's wake is refused with the read error, which says to try again,
    /// rather than handed on to the coordinator, whose answer for a parked
    /// tmux row tells the person to do what they just did. Recorded as a
    /// failure, not a refusal: nothing was declined.
    @Test("a person's wake whose read of the row fails is refused with the read error")
    func aRowThatCannotBeReadIsRefusedWithTheReadError() async throws {
        let f = try await Self.makeFixture()
        defer { f.tearDown() }
        let row = try await Self.parkedTmuxRow(f)
        try await f.db.writerForTests.write { db in
            try db.execute(sql: "ALTER TABLE terminal RENAME TO terminal_unreadable")
        }

        let response = await f.router.handle(try Entry.terminalWake.request(row, actor: .app))

        #expect(!response.success)
        let error = try #require(response.error)
        #expect(error.hasPrefix("TBD could not read this session"), "the wake was answered with: \(error)")
        #expect(response.errorCode == nil)
        #expect(f.holder.launches.isEmpty, "a wake that could not read the row started a holder")
        let outcomes = try f.actuationOutcomes()
        #expect(outcomes.count == 1, "the actuation was not closed exactly once: \(outcomes)")
        #expect(outcomes.first?["result"] as? String == "transport-failed")
    }

    /// Start admission that admits every wake, after making the terminal
    /// table unreadable: the seam between `worktree.resume`'s list of the
    /// worktree's rows, which must succeed for the call to reach a row at
    /// all, and the move's own read of that row.
    private final class UnreadableAfterAdmission: StartAdmissionEvaluating, @unchecked Sendable {
        private let lock = NSLock()
        private var asked = 0
        private let db: TBDDatabase

        init(db: TBDDatabase) { self.db = db }

        var count: Int { lock.withLock { asked } }

        func evaluate(_ request: StartAdmissionRequest) async -> StartAdmissionVerdict {
            lock.withLock { asked += 1 }
            do {
                try await db.writerForTests.write { database in
                    try database.execute(sql: "ALTER TABLE terminal RENAME TO terminal_unreadable")
                }
            } catch {
                Issue.record("could not make the terminal table unreadable: \(error)")
            }
            return .admit
        }
    }

    /// `worktree.resume` whose move cannot read the row answers with the read
    /// error, which says to try again, and no `terminalOnTmux` code: the
    /// call woke nothing, so it reports the move's own refusal, not the
    /// coordinator's advice for a row still on tmux. Recorded once, as a
    /// failure. The row is listed first, so the read fails only once start
    /// admission, which is asked between the two, has renamed the table.
    @Test("worktree.resume whose move cannot read the row answers with the read error")
    func aWorktreeResumeWhoseMoveCannotReadTheRowAnswersWithTheReadError() async throws {
        let f = try await Self.makeFixture()
        defer { f.tearDown() }
        let row = try await Self.parkedTmuxRow(f)
        let admission = UnreadableAfterAdmission(db: f.db)
        f.router.startAdmission = admission
        try await f.db.config.setStartAdmissionEnabled(true)

        let response = await f.router.handle(try Entry.worktreeResume.request(row, actor: nil))

        #expect(admission.count == 1, "start admission was not asked between the list and the move")
        #expect(!response.success)
        let error = try #require(response.error)
        #expect(error.hasPrefix("TBD could not read this session"), "the resume was answered with: \(error)")
        #expect(response.errorCode == nil)
        #expect(f.holder.launches.isEmpty, "a resume that could not read the row started a holder")
        let outcomes = try f.actuationOutcomes()
        #expect(outcomes.count == 1, "the actuation was not closed exactly once: \(outcomes)")
        #expect(outcomes.first?["result"] as? String == "transport-failed")
    }

    /// Operations whose server sighting first runs `race`, a write by another
    /// writer between the move's read of the row and its compare-and-set, and
    /// then reads the server as gone. Only a row whose park is in flight is
    /// sighted, so only such a row meets the race. Nothing else the move could
    /// do is expected of a parked row.
    private static func racingOperations(
        race: @escaping @Sendable (UUID) async throws -> Void
    ) -> TerminalTransportMigrator.Operations {
        TerminalTransportMigrator.Operations(
            canSpawnHolder: { true },
            tmuxServerSighting: { terminal in
                do {
                    try await race(terminal.id)
                } catch {
                    Issue.record("the other writer's write failed: \(error)")
                }
                return LeftoverTmuxServerSighting(server: Self.server, state: .absent)
            },
            parkLeftover: { _ in
                Issue.record("the move of a parked row parked it again")
                return .leftAlone
            },
            wake: { _ in
                Issue.record("the move woke the row itself; the wake that follows it does")
                return .notFound
            },
            moveRunningShell: { _ in
                Issue.record("the move of a parked row moved a running shell")
                return .refused(reason: "not expected")
            })
    }

    /// The move loses its compare-and-set to another writer. When that writer
    /// left the row on tmux, the wake is refused with a reason that says the
    /// row changed, and the row is as the other writer left it. When it moved
    /// the row to the holder first — a concurrent wake, or a migration — the
    /// wake has nothing left to move and wakes the row there.
    @Test("a move that loses its compare-and-set refuses, unless the row is already on the holder",
          arguments: [false, true])
    func aMoveThatLosesTheRace(endsOnTheHolder: Bool) async throws {
        let f = try await Self.makeFixture()
        defer { f.tearDown() }
        let row = try await Self.parkInFlightTmuxRow(f)
        let db = f.db
        f.router.transportMigratorOperationsOverride = Self.racingOperations { terminalID in
            try await db.writerForTests.write { conn in
                if endsOnTheHolder {
                    try conn.execute(
                        sql: """
                            UPDATE terminal SET transport = 'holder', tmuxWindowID = '',
                                tmuxPaneID = '', pendingSessionIncarnationID = NULL
                            WHERE id = ?
                            """,
                        arguments: [terminalID.uuidString])
                } else {
                    try conn.execute(
                        sql: "UPDATE terminal SET claudeSessionID = ? WHERE id = ?",
                        arguments: ["sess-other-writer", terminalID.uuidString])
                }
            }
        }

        let response = await f.router.handle(try Entry.terminalWake.request(row, actor: .app))

        let after = try #require(try await f.db.terminals.get(id: row.id))
        if endsOnTheHolder {
            #expect(response.success, "the wake of a row moved by another writer failed: \(response.error ?? "")")
            #expect(after.transport == .holder)
            #expect(!after.isParked, "the row another writer moved was not woken")
            let launch = try #require(f.holder.launch(for: row.id))
            #expect(launch.commandLine?.contains("claude --resume \(Self.sessionID)") == true,
                    "the wake did not resume the session: \(launch.commandLine ?? "nil")")
        } else {
            #expect(response.errorCode == RPCErrorCode.terminalOnTmux.rawValue)
            #expect(response.error == TransportMigrationOnWake.raceRefusal)
            #expect(after.transport == .tmux)
            #expect(after.isParked)
            #expect(after.tmuxWindowID == "@4")
            #expect(after.claudeSessionID == "sess-other-writer",
                    "the row is not as the other writer left it")
            #expect(f.holder.launches.isEmpty, "a refused move started a holder")
            #expect(f.replaced(row.id).isEmpty, "a refused move published a move")
        }
        let outcomes = try f.actuationOutcomes()
        #expect(outcomes.count == 1, "the actuation was not closed exactly once: \(outcomes)")
        #expect(outcomes.first?["result"] as? String == (endsOnTheHolder ? "dispatched" : "refused"))
    }

    /// A tab closed while the move ran leaves the rewrite no row to write.
    /// That is a missing row, so the wake answers it as the missing row it now
    /// is — "Terminal not found", recorded as not found — and not as a move
    /// that could not be recorded, whose `terminalOnTmux` code says the
    /// session is still parked on tmux. `worktree.resume` reports no missing
    /// row of its own, so the two single-terminal requests are the ones asked.
    @Test("a person's wake of a row closed while it was being moved answers that it is gone",
          arguments: [Entry.terminalWake, .terminalResume])
    func aRowClosedDuringTheMoveIsNotFound(_ entry: Entry) async throws {
        let f = try await Self.makeFixture()
        defer { f.tearDown() }
        let row = try await Self.parkInFlightTmuxRow(f)
        let db = f.db
        f.router.transportMigratorOperationsOverride = Self.racingOperations { terminalID in
            try await db.terminals.delete(id: terminalID)
        }

        let response = await f.router.handle(try entry.request(row, actor: .app))

        #expect(!response.success)
        #expect(response.error == "Terminal not found")
        #expect(response.errorCode != RPCErrorCode.terminalOnTmux.rawValue,
                "a closed row was answered as one still parked on tmux")
        #expect(try await f.db.terminals.get(id: row.id) == nil, "the fixture did not close the row")
        #expect(f.holder.launches.isEmpty, "the wake of a closed row started a holder")
        let outcomes = try f.actuationOutcomes()
        #expect(outcomes.count == 1, "the actuation was not closed exactly once: \(outcomes)")
        #expect(outcomes.first?["result"] as? String == "refused")
        #expect(outcomes.first?["reason"] as? String == "not-found")
    }
}
