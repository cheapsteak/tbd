import Foundation

enum CodexContinuationPacketError: Error, Equatable, LocalizedError {
    case rolloutPathMustBeAbsolute
    case rolloutUnreadable
    case contentFreeRollout
    case gitStatusFailed

    var errorDescription: String? {
        switch self {
        case .rolloutPathMustBeAbsolute:
            return "The Codex rollout path is not absolute."
        case .rolloutUnreadable:
            return "The Codex rollout could not be read."
        case .contentFreeRollout:
            return "The Codex rollout contains no usable conversation content."
        case .gitStatusFailed:
            return "The worktree's git status could not be captured."
        }
    }
}

protocol CodexContinuationGitStatusProviding: Sendable {
    func status(worktreePath: String) async throws -> String
}

struct CodexProcessGitStatusProvider: CodexContinuationGitStatusProviding {
    let timeout: Duration
    let clock: any Clock<Duration>

    init(
        timeout: Duration = .seconds(10),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.timeout = timeout
        self.clock = clock
    }

    func status(worktreePath: String) async throws -> String {
        let outcome = try await runBoundedProcess(
            executable: "/usr/bin/git",
            arguments: [
                "-C", worktreePath, "status", "--short", "--branch",
                "--untracked-files=all",
            ],
            currentDirectory: nil,
            timeout: timeout,
            clock: clock)

        switch outcome {
        case .timedOut:
            throw CodexContinuationPacketError.gitStatusFailed
        case let .completed(status, stdout, _):
            guard status == 0,
                  let output = String(data: stdout, encoding: .utf8) else {
                throw CodexContinuationPacketError.gitStatusFailed
            }
            return output
        }
    }
}

/// Builds the bounded initial prompt used to hand a Codex terminal to Claude.
///
/// The source JSONL is streamed in fixed-size chunks and no input record may
/// exceed one MiB. Selection and redaction are mechanical: this type never
/// invokes a model and never writes another durable handoff artifact.
struct CodexContinuationPacketBuilder: Sendable {
    static let promptByteLimit = 64 * 1024
    static let envelopeByteLimit = 16 * 1024
    static let historyByteLimit = 48 * 1024
    static let recordByteLimit = 1024 * 1024

    private let gitStatusProvider: any CodexContinuationGitStatusProviding

    init(
        gitStatusProvider: any CodexContinuationGitStatusProviding =
            CodexProcessGitStatusProvider()
    ) {
        self.gitStatusProvider = gitStatusProvider
    }

    func build(rolloutPath: String, worktreePath: String) async throws -> String {
        guard rolloutPath.hasPrefix("/") else {
            throw CodexContinuationPacketError.rolloutPathMustBeAbsolute
        }
        let sourceURL = URL(fileURLWithPath: rolloutPath).standardizedFileURL
        let worktreeURL = URL(fileURLWithPath: worktreePath).standardizedFileURL

        let status: String
        do {
            status = try await gitStatusProvider.status(worktreePath: worktreeURL.path)
        } catch {
            throw CodexContinuationPacketError.gitStatusFailed
        }

        var accumulator = HistoryAccumulator(byteLimit: Self.historyByteLimit)
        do {
            try JSONLScanner(
                recordByteLimit: Self.recordByteLimit,
                chunkByteCount: 64 * 1024
            ).scan(url: sourceURL) { record in
                accumulator.consume(record: record)
            } oversizedRecord: {
                accumulator.oversizedRecordCount += 1
            } unterminatedRecord: {
                accumulator.malformedRecordCount += 1
            }
        } catch {
            throw CodexContinuationPacketError.rolloutUnreadable
        }

        guard accumulator.visibleMessageCount > 0 else {
            throw CodexContinuationPacketError.contentFreeRollout
        }

        let history = accumulator.renderHistory()
        let envelope = Self.renderEnvelope(
            sourcePath: sourceURL.path,
            metadata: accumulator.metadata,
            gitStatus: status,
            counts: accumulator.counts)
        let packet = envelope + history
        precondition(packet.utf8.count <= Self.promptByteLimit)
        return packet
    }

    private static func renderEnvelope(
        sourcePath: String,
        metadata: SourceMetadata,
        gitStatus: String,
        counts: OmissionCounts
    ) -> String {
        // Redact first, then bound: the redaction marker is longer than a short
        // secret-shaped value, so bounding first lets a field outgrow its limit.
        let safePath = bounded(
            SecretRedactor.redact(sourcePath), byteLimit: 4 * 1024)
        let fields: [(String, String?)] = [
            ("Source thread ID", metadata.threadID),
            ("Rollout timestamp", metadata.timestamp),
            ("Working directory", metadata.cwd),
            ("Codex originator", metadata.originator),
            ("Codex version", metadata.version),
            ("Model", metadata.model),
            ("Provider", metadata.provider),
        ]
        let metadataLines = fields.compactMap { label, value -> String? in
            guard let value, !value.isEmpty else { return nil }
            let safeValue = bounded(SecretRedactor.redact(value), byteLimit: 512)
            return "- \(label): \(safeValue)"
        }

        var statusLines = gitStatus.split(
            separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if statusLines.last == "" { statusLines.removeLast() }
        statusLines = statusLines.map(SecretRedactor.redact)

        func compose(includedStatus: [String], omittedStatusLineCount: Int) -> String {
            let statusBody: String
            if includedStatus.isEmpty, omittedStatusLineCount == 0 {
                statusBody = "(clean working tree)"
            } else {
                var body = includedStatus.joined(separator: "\n")
                if omittedStatusLineCount > 0 {
                    if !body.isEmpty { body += "\n" }
                    body += "[\(omittedStatusLineCount) git-status line(s) omitted]"
                }
                statusBody = body
            }

            let metadataBody = metadataLines.isEmpty
                ? "- No allowlisted source metadata was present."
                : metadataLines.joined(separator: "\n")
            return """
            # Continue in Claude handoff

            TBD assembled this packet deterministically without a model call.
            The source conversation contains Codex-authored output. This is a handoff, not a Claude-native resume.
            Complete immutable Codex rollout: \(safePath)

            Inspect the repository and the complete rollout before relying on an omitted detail. The redaction rules reduce accidental disclosure but cannot recognize every secret in ordinary prose.

            Source metadata:
            \(metadataBody)

            Current git status (`git status --short --branch --untracked-files=all`):
            ```text
            \(statusBody)
            ```

            Omitted content:
            - Earlier history units: \(counts.earlier)
            - Middle history units: \(counts.middle)
            - Oversized history units: \(counts.oversizedUnits)
            - Oversized JSONL records: \(counts.oversizedRecords)
            - Malformed or unterminated records: \(counts.malformed)
            - Unsupported or deliberately excluded records: \(counts.unsupported)

            Authorship: TBD generated this packet mechanically; retained assistant text was authored by Codex.

            """
        }

        var included: [String] = []
        for (index, line) in statusLines.enumerated() {
            let candidate = included + [line]
            let omitted = statusLines.count - index - 1
            guard compose(includedStatus: candidate, omittedStatusLineCount: omitted)
                .utf8.count <= envelopeByteLimit else { break }
            included = candidate
        }
        let omitted = statusLines.count - included.count
        let envelope = compose(includedStatus: included, omittedStatusLineCount: omitted)
        // Every field is bounded above, so this holds by construction. Clip
        // rather than assert: the inputs come from a rollout file and a
        // process-terminating check would take the whole daemon down with it.
        return bounded(envelope, byteLimit: envelopeByteLimit)
    }

    private static func bounded(_ value: String, byteLimit: Int) -> String {
        guard value.utf8.count > byteLimit else { return value }
        let marker = "[truncated]"
        let prefixLimit = max(0, byteLimit - marker.utf8.count)
        let bytes = Data(value.utf8)
        var end = min(prefixLimit, bytes.count)
        while end > 0, String(data: bytes.prefix(end), encoding: .utf8) == nil {
            end -= 1
        }
        return (String(data: bytes.prefix(end), encoding: .utf8) ?? "") + marker
    }
}

private struct SourceMetadata: Sendable {
    var threadID: String?
    var timestamp: String?
    var cwd: String?
    var originator: String?
    var version: String?
    var model: String?
    var provider: String?
}

private struct OmissionCounts: Sendable {
    var earlier = 0
    var middle = 0
    var oversizedUnits = 0
    var oversizedRecords = 0
    var malformed = 0
    var unsupported = 0
}

private struct HistoryUnit: Sendable {
    enum Kind: Sendable {
        case user
        case assistant(phase: String?)
        case tool(name: String, paths: [(String, String)])
    }

    let ordinal: Int
    let kind: Kind
    let text: String
    let signature: String?
    let canonical: Bool

    var isUser: Bool {
        if case .user = kind { return true }
        return false
    }

    func rendered() -> String {
        switch kind {
        case .user:
            return "### User\n\(text)\n\n"
        case .assistant(let phase):
            let suffix = phase.map { " (\($0))" } ?? ""
            return "### Codex\(suffix)\n\(text)\n\n"
        case let .tool(name, paths):
            let pathBody = paths.isEmpty
                ? "- No path-like arguments retained."
                : paths.map { "- \($0.0): \($0.1)" }.joined(separator: "\n")
            return "### Tool call: \(name)\n\(pathBody)\n\n"
        }
    }
}

private struct SelectedHistoryUnit: Sendable {
    var unit: HistoryUnit
    var rendered: String
}

private struct SelectedHistoryTurn: Sendable {
    let ordinal: Int
    let rendered: String
}

private struct PendingHistoryTurn: Sendable {
    var identifier: String?
    var firstOrdinal: Int?
    var userSignature: String?
    var userIsInitialTask = false
    var units: [SelectedHistoryUnit] = []
    var renderedByteCount = 0
    var isOversized = false

    var hasContent: Bool {
        firstOrdinal != nil || !units.isEmpty || isOversized
    }
}

private struct HistoryAccumulator {
    private let heading = "## Selected history\n\n"
    private let byteLimit: Int
    private var ordinal = 0
    private var initial: SelectedHistoryUnit?
    private var currentTurn = PendingHistoryTurn()
    private var suffix: [SelectedHistoryTurn] = []
    private var suffixByteCount = 0
    private(set) var visibleMessageCount = 0
    private(set) var metadata = SourceMetadata()
    private(set) var counts = OmissionCounts()

    var oversizedRecordCount: Int {
        get { counts.oversizedRecords }
        set { counts.oversizedRecords = newValue }
    }

    var malformedRecordCount: Int {
        get { counts.malformed }
        set { counts.malformed = newValue }
    }

    init(byteLimit: Int) {
        self.byteLimit = byteLimit
    }

    mutating func consume(record: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: record),
              let envelope = object as? [String: Any],
              let type = envelope["type"] as? String,
              let payload = envelope["payload"] as? [String: Any] else {
            counts.malformed += 1
            return
        }

        switch type {
        case "session_meta":
            consumeSessionMetadata(payload)
        case "response_item":
            consumeResponseItem(payload)
        case "event_msg":
            consumeEventMessage(payload)
        case "turn_context":
            beginTurn(identifier: scalar(payload["turn_id"]))
        default:
            counts.unsupported += 1
        }
    }

    mutating func renderHistory() -> String {
        finalizeCurrentTurn()
        return heading
            + (initial?.rendered ?? "")
            + suffix.map(\.rendered).joined()
    }

    private mutating func consumeSessionMetadata(_ payload: [String: Any]) {
        metadata.threadID = metadata.threadID ?? scalar(payload["id"])
            ?? scalar(payload["thread_id"])
        metadata.timestamp = metadata.timestamp ?? scalar(payload["timestamp"])
        metadata.cwd = metadata.cwd ?? scalar(payload["cwd"])
        metadata.originator = metadata.originator ?? scalar(payload["originator"])
            ?? scalar(payload["source"])
        metadata.version = metadata.version ?? scalar(payload["cli_version"])
            ?? scalar(payload["version"])
        metadata.model = metadata.model ?? scalar(payload["model"])
            ?? scalar(payload["model_name"])
        metadata.provider = metadata.provider ?? scalar(payload["model_provider"])
            ?? scalar(payload["provider"])
    }

    private mutating func consumeResponseItem(_ payload: [String: Any]) {
        guard let itemType = payload["type"] as? String else {
            counts.malformed += 1
            return
        }
        switch itemType {
        case "message", "user_message", "assistant_message":
            guard let role = payload["role"] as? String,
                  let text = messageText(payload),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                counts.unsupported += 1
                return
            }
            let safeText = SecretRedactor.redact(text)
            switch role {
            case "user":
                visibleMessageCount += 1
                append(unit(kind: .user, text: safeText, canonical: true))
            case "assistant":
                visibleMessageCount += 1
                let phase = scalar(payload["phase"])
                    ?? (payload["final"] as? Bool == true ? "final" : nil)
                append(unit(
                    kind: .assistant(phase: phase), text: safeText, canonical: true))
            default:
                counts.unsupported += 1
            }
        case "function_call", "custom_tool_call":
            let rawName = scalar(payload["name"]) ?? "unknown"
            let name = SecretRedactor.redact(rawName)
            let arguments = decodedArguments(payload["arguments"] ?? payload["input"])
            let redacted = SecretRedactor.redactStructured(arguments)
            let paths = pathArguments(in: redacted)
            append(unit(kind: .tool(name: name, paths: paths), text: "", canonical: true))
        case "function_call_output", "custom_tool_call_output", "reasoning",
             "encrypted_reasoning", "image", "input_image", "computer_screenshot":
            counts.unsupported += 1
        default:
            counts.unsupported += 1
        }
    }

    private mutating func consumeEventMessage(_ payload: [String: Any]) {
        guard let eventType = payload["type"] as? String else {
            counts.malformed += 1
            return
        }
        switch eventType {
        case "user_message", "agent_message":
            guard let message = scalar(payload["message"]),
                  !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                counts.unsupported += 1
                return
            }
            let safeText = SecretRedactor.redact(message)
            visibleMessageCount += 1
            let kind: HistoryUnit.Kind = eventType == "user_message"
                ? .user : .assistant(phase: nil)
            append(unit(kind: kind, text: safeText, canonical: false))
        case "task_started":
            beginTurn(identifier: scalar(payload["turn_id"]))
        case "task_complete", "turn_aborted":
            finishTurn(identifier: scalar(payload["turn_id"]))
        default:
            counts.unsupported += 1
        }
    }

    private mutating func unit(
        kind: HistoryUnit.Kind,
        text: String,
        canonical: Bool
    ) -> HistoryUnit {
        defer { ordinal += 1 }
        let signature: String?
        switch kind {
        case .user:
            signature = "user\u{0}" + normalized(text)
        case .assistant:
            signature = "assistant\u{0}" + normalized(text)
        case .tool:
            signature = nil
        }
        return HistoryUnit(
            ordinal: ordinal,
            kind: kind,
            text: text,
            signature: signature,
            canonical: canonical)
    }

    private mutating func append(_ unit: HistoryUnit) {
        if unit.isUser {
            appendUser(unit)
        } else {
            appendToCurrentTurn(unit)
        }
    }

    private mutating func appendUser(_ unit: HistoryUnit) {
        if currentTurn.userSignature == unit.signature {
            replaceEquivalentUnitIfPreferred(unit)
            return
        }

        if currentTurn.hasContent {
            finalizeCurrentTurn()
        }

        currentTurn.firstOrdinal = unit.ordinal
        currentTurn.userSignature = unit.signature
        if initial == nil {
            counts.earlier += suffix.count
            suffix.removeAll(keepingCapacity: false)
            suffixByteCount = 0
            initial = SelectedHistoryUnit(
                unit: unit,
                rendered: renderedForSelection(unit))
            currentTurn.userIsInitialTask = true
            trimSuffix()
        } else {
            appendToCurrentTurn(unit)
        }
    }

    private mutating func appendToCurrentTurn(_ unit: HistoryUnit) {
        if currentTurn.firstOrdinal == nil {
            currentTurn.firstOrdinal = unit.ordinal
        }
        guard !currentTurn.isOversized else { return }

        if let signature = unit.signature,
           currentTurn.units.contains(where: { $0.unit.signature == signature }) {
            replaceEquivalentUnitIfPreferred(unit)
            return
        }

        let selected = SelectedHistoryUnit(unit: unit, rendered: unit.rendered())
        let nextByteCount = currentTurn.renderedByteCount + selected.rendered.utf8.count
        guard nextByteCount <= historyContentByteLimit else {
            currentTurn.units.removeAll(keepingCapacity: false)
            currentTurn.renderedByteCount = 0
            currentTurn.isOversized = true
            return
        }
        currentTurn.units.append(selected)
        currentTurn.renderedByteCount = nextByteCount
    }

    private mutating func replaceEquivalentUnitIfPreferred(_ unit: HistoryUnit) {
        guard unit.canonical else { return }

        if currentTurn.userIsInitialTask,
           let current = initial,
           current.unit.signature == unit.signature,
           !current.unit.canonical {
            let replacement = preservingOrdinal(of: current.unit, with: unit)
            initial = SelectedHistoryUnit(
                unit: replacement,
                rendered: renderedForSelection(replacement))
            trimSuffix()
            return
        }

        guard !currentTurn.isOversized,
              let index = currentTurn.units.firstIndex(where: {
                  $0.unit.signature == unit.signature
              }),
              !currentTurn.units[index].unit.canonical else { return }
        let existing = currentTurn.units[index]
        let replacement = preservingOrdinal(of: existing.unit, with: unit)
        let selected = SelectedHistoryUnit(unit: replacement, rendered: replacement.rendered())
        let nextByteCount = currentTurn.renderedByteCount
            - existing.rendered.utf8.count
            + selected.rendered.utf8.count
        guard nextByteCount <= historyContentByteLimit else {
            currentTurn.units.removeAll(keepingCapacity: false)
            currentTurn.renderedByteCount = 0
            currentTurn.isOversized = true
            return
        }
        currentTurn.units[index] = selected
        currentTurn.renderedByteCount = nextByteCount
    }

    private func preservingOrdinal(
        of existing: HistoryUnit,
        with replacement: HistoryUnit
    ) -> HistoryUnit {
        HistoryUnit(
            ordinal: existing.ordinal,
            kind: replacement.kind,
            text: replacement.text,
            signature: replacement.signature,
            canonical: replacement.canonical)
    }

    private mutating func beginTurn(identifier: String?) {
        guard let identifier, !identifier.isEmpty else { return }
        guard let currentIdentifier = currentTurn.identifier else {
            currentTurn.identifier = identifier
            return
        }
        guard currentIdentifier != identifier else { return }
        finalizeCurrentTurn()
        currentTurn.identifier = identifier
    }

    private mutating func finishTurn(identifier: String?) {
        if let identifier,
           let currentIdentifier = currentTurn.identifier,
           identifier != currentIdentifier {
            return
        }
        finalizeCurrentTurn()
    }

    private mutating func finalizeCurrentTurn() {
        defer { currentTurn = PendingHistoryTurn() }
        guard currentTurn.hasContent else { return }

        let rendered: String
        if currentTurn.isOversized {
            counts.oversizedUnits += 1
            rendered = "### Turn\n[Oversized turn omitted; inspect the complete rollout.]\n\n"
        } else {
            rendered = currentTurn.units.map(\.rendered).joined()
        }
        guard !rendered.isEmpty else { return }

        suffix.append(SelectedHistoryTurn(
            ordinal: currentTurn.firstOrdinal ?? ordinal,
            rendered: rendered))
        suffixByteCount += rendered.utf8.count
        trimSuffix()
    }

    private mutating func renderedForSelection(_ unit: HistoryUnit) -> String {
        let rendered = unit.rendered()
        let available = historyContentByteLimit
        guard rendered.utf8.count > available else { return rendered }
        counts.oversizedUnits += 1
        let type: String
        switch unit.kind {
        case .user: type = "User"
        case .assistant: type = "Codex"
        case .tool: type = "Tool call"
        }
        return "### \(type)\n[Oversized unit omitted; inspect the complete rollout.]\n\n"
    }

    private mutating func trimSuffix() {
        let initialBytes = initial?.rendered.utf8.count ?? 0
        let available = max(0, historyContentByteLimit - initialBytes)
        while suffixByteCount > available, !suffix.isEmpty {
            let removed = suffix.removeFirst()
            suffixByteCount -= removed.rendered.utf8.count
            if let initial, removed.ordinal > initial.unit.ordinal {
                counts.middle += 1
            } else {
                counts.earlier += 1
            }
        }
    }

    private var historyContentByteLimit: Int {
        max(0, byteLimit - heading.utf8.count)
    }

    private func scalar(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    private func messageText(_ payload: [String: Any]) -> String? {
        if let content = payload["content"] as? String { return content }
        guard let content = payload["content"] as? [[String: Any]] else { return nil }
        let parts = content.compactMap { part -> String? in
            guard let type = part["type"] as? String,
                  ["input_text", "output_text", "text"].contains(type) else { return nil }
            return part["text"] as? String
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private func decodedArguments(_ value: Any?) -> Any {
        guard let string = value as? String,
              let data = string.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) else {
            return value ?? NSNull()
        }
        return decoded
    }

    private func pathArguments(in value: Any) -> [(String, String)] {
        var result: [(String, String)] = []
        func walk(_ node: Any) {
            if let dictionary = node as? [String: Any] {
                for key in dictionary.keys.sorted() {
                    let child = dictionary[key] as Any
                    if isPathKey(key) {
                        for path in stringValues(child) {
                            result.append((key, SecretRedactor.redact(path)))
                        }
                    }
                    walk(child)
                }
            } else if let array = node as? [Any] {
                array.forEach(walk)
            }
        }
        walk(value)
        return result
    }

    private func isPathKey(_ key: String) -> Bool {
        let normalized = key.lowercased().filter { $0.isLetter }
        return [
            "path", "paths", "file", "files", "filename", "directory",
            "cwd", "workdir", "worktree", "target",
        ].contains(normalized)
    }

    private func stringValues(_ value: Any) -> [String] {
        if let value = value as? String { return [value] }
        if let values = value as? [Any] { return values.compactMap { $0 as? String } }
        return []
    }

    private func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

private struct JSONLScanner {
    let recordByteLimit: Int
    let chunkByteCount: Int

    func scan(
        url: URL,
        record: (Data) throws -> Void,
        oversizedRecord: () -> Void,
        unterminatedRecord: () -> Void
    ) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var buffer = Data()
        var discarding = false

        while let chunk = try handle.read(upToCount: chunkByteCount), !chunk.isEmpty {
            var start = chunk.startIndex
            while start < chunk.endIndex {
                if let newline = chunk[start...].firstIndex(of: 0x0A) {
                    if discarding {
                        discarding = false
                    } else {
                        buffer.append(contentsOf: chunk[start..<newline])
                        if buffer.count > recordByteLimit {
                            oversizedRecord()
                        } else if !buffer.isEmpty {
                            if buffer.last == 0x0D { buffer.removeLast() }
                            if !buffer.isEmpty { try record(buffer) }
                        }
                        buffer.removeAll(keepingCapacity: true)
                    }
                    start = chunk.index(after: newline)
                } else {
                    if !discarding {
                        buffer.append(contentsOf: chunk[start...])
                        if buffer.count > recordByteLimit {
                            buffer.removeAll(keepingCapacity: true)
                            discarding = true
                            oversizedRecord()
                        }
                    }
                    start = chunk.endIndex
                }
            }
        }

        if discarding || !buffer.isEmpty {
            if !discarding { unterminatedRecord() }
        }
    }
}

private enum SecretRedactor {
    private static let marker = "[REDACTED]"
    private static let secretKeys = [
        "token", "secret", "password", "credential", "authorization", "apikey",
        "privatekey", "cookie", "sessioncookie",
    ]

    static func redactStructured(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, child) in dictionary {
                let normalized = key.lowercased().filter { $0.isLetter }
                if secretKeys.contains(where: { normalized.contains($0) }) {
                    result[key] = marker
                } else {
                    result[key] = redactStructured(child)
                }
            }
            return result
        }
        if let array = value as? [Any] { return array.map(redactStructured) }
        if let string = value as? String { return redact(string) }
        return value
    }

    static func redact(_ value: String) -> String {
        var result = value
        result = replacing(
            #"-----BEGIN(?: [A-Z0-9]+)* PRIVATE KEY-----[\s\S]*?-----END(?: [A-Z0-9]+)* PRIVATE KEY-----"#,
            in: result,
            with: marker,
            options: [.caseInsensitive])
        result = replacing(
            #"\b(authorization\s*[:=]\s*)(?:bearer|basic)\s+[^\s,;]+"#,
            in: result,
            with: "$1" + marker,
            options: [.caseInsensitive])
        result = replacing(
            #"(?<![A-Za-z0-9])((?:[A-Za-z][A-Za-z0-9_-]*)?(?:token|secret|password|credential|authorization|api[ _-]?key|private[ _-]?key|cookie|session[ _-]?cookie)[A-Za-z0-9_-]*)([\"']?\s*[:=]\s*)(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#,
            in: result,
            with: "$1$2" + marker,
            options: [.caseInsensitive])
        result = replacing(
            #"\b([a-z][a-z0-9+.-]*://)[^/@\s:]+:[^/@\s]+@"#,
            in: result,
            with: "$1" + marker + "@",
            options: [.caseInsensitive])
        result = replacing(
            #"\b(?:sk-[A-Za-z0-9_-]{4,}|gh[pousr]_[A-Za-z0-9_]{4,}|github_pat_[A-Za-z0-9_]{4,}|xox[baprs]-[A-Za-z0-9-]{4,}|AKIA[A-Z0-9]{12,})\b"#,
            in: result,
            with: marker,
            options: [])
        return result
    }

    private static func replacing(
        _ pattern: String,
        in value: String,
        with template: String,
        options: NSRegularExpression.Options
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return value
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(
            in: value, options: [], range: range, withTemplate: template)
    }
}
