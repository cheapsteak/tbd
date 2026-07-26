import ArgumentParser
import Foundation
import TBDShared

struct PanelCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "panel",
        abstract: "Inspect and arrange a worktree's panels (agent See/Arrange)",
        subcommands: [
            PanelList.self,
            PanelOpen.self,
            PanelNavigate.self,
            PanelClose.self,
            PanelMove.self,
            PanelResize.self,
            PanelBack.self,
            PanelForward.self,
            PanelJump.self,
            PanelSelectTab.self,
        ]
    )
}

// MARK: - ExpressibleByArgument conformance for CLI

extension PanelEdge: ExpressibleByArgument {}

// MARK: - panel list (See)

struct PanelList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Show a worktree's tabs, panels, and layout — read-only, always available regardless of gating"
    )

    @Argument(help: "Worktree name or ID")
    var worktree: String

    @Option(name: .long, help: "Limit to one tab ID")
    var tab: String?

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let worktreeID = try resolveWorktreeArg(worktree, client: client)
        let tabID = try tab.map { try parseUUID($0, label: "tab ID") }

        let result: PanelGetResult = try client.call(
            method: RPCMethod.panelGet,
            params: PanelGetParams(worktreeID: worktreeID, tabID: tabID),
            resultType: PanelGetResult.self
        )

        if json {
            printJSON(result)
        } else {
            if result.tabs.isEmpty {
                print("No tabs found.")
                return
            }
            for (index, tab) in result.tabs.enumerated() {
                if index > 0 { print() }
                for line in tabLines(tab, activeTabID: result.activeTabID) {
                    print(line)
                }
            }
        }
    }
}

// MARK: - panel open / navigate / close / move / resize / history / select-tab (Arrange)

struct PanelOpen: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Open a new panel in a tab's layout"
    )

    @Argument(help: "Worktree name or ID")
    var worktree: String

    @Option(name: .long, help: "Tab ID")
    var tab: String

    @OptionGroup var content: ContentOptions
    @OptionGroup var placement: PlacementOptions

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let worktreeID = try resolveWorktreeArg(worktree, client: client)
        let tabID = try parseUUID(tab, label: "tab ID")
        let panelContent = try resolvePanelContent(content)
        let panelPlacement = try resolvePanelPlacement(placement)

        let result = try applyPanelOperation(
            client: client, worktreeID: worktreeID, tabID: tabID,
            operation: .open(content: panelContent, placement: panelPlacement))
        printApplyResult(result, json: json)
    }
}

struct PanelNavigate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "navigate",
        abstract: "Change what an existing panel displays"
    )

    @Argument(help: "Worktree name or ID")
    var worktree: String

    @Option(name: .long, help: "Tab ID")
    var tab: String

    @Option(name: .long, help: "Panel ID to navigate")
    var panel: String

    @OptionGroup var content: ContentOptions

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let worktreeID = try resolveWorktreeArg(worktree, client: client)
        let tabID = try parseUUID(tab, label: "tab ID")
        let panelID = try parseUUID(panel, label: "panel ID")
        let destination = try resolvePanelContent(content)

        let result = try applyPanelOperation(
            client: client, worktreeID: worktreeID, tabID: tabID,
            operation: .navigate(panelID: panelID, destination: destination))
        printApplyResult(result, json: json)
    }
}

struct PanelClose: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close",
        abstract: "Close a panel"
    )

    @Argument(help: "Worktree name or ID")
    var worktree: String

    @Option(name: .long, help: "Tab ID")
    var tab: String

    @Option(name: .long, help: "Panel ID to close")
    var panel: String

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let worktreeID = try resolveWorktreeArg(worktree, client: client)
        let tabID = try parseUUID(tab, label: "tab ID")
        let panelID = try parseUUID(panel, label: "panel ID")

        let result = try applyPanelOperation(
            client: client, worktreeID: worktreeID, tabID: tabID,
            operation: .close(panelID: panelID))
        printApplyResult(result, json: json)
    }
}

struct PanelMove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "move",
        abstract: "Move a panel to a new placement in the layout"
    )

    @Argument(help: "Worktree name or ID")
    var worktree: String

    @Option(name: .long, help: "Tab ID")
    var tab: String

    @Option(name: .long, help: "Panel ID to move")
    var panel: String

    @OptionGroup var placement: PlacementOptions

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let worktreeID = try resolveWorktreeArg(worktree, client: client)
        let tabID = try parseUUID(tab, label: "tab ID")
        let panelID = try parseUUID(panel, label: "panel ID")
        let panelPlacement = try resolvePanelPlacement(placement)

        let result = try applyPanelOperation(
            client: client, worktreeID: worktreeID, tabID: tabID,
            operation: .move(panelID: panelID, placement: panelPlacement))
        printApplyResult(result, json: json)
    }
}

struct PanelResize: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resize",
        abstract: "Resize a split's children"
    )

    @Argument(help: "Worktree name or ID")
    var worktree: String

    @Option(name: .long, help: "Tab ID")
    var tab: String

    @Option(name: .long, help: "Split ID to resize")
    var split: String

    @Option(name: .long, help: "Comma-separated ratios for the split's children, e.g. '0.5,0.5'")
    var ratios: String

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let worktreeID = try resolveWorktreeArg(worktree, client: client)
        let tabID = try parseUUID(tab, label: "tab ID")
        let splitID = try parseUUID(split, label: "split ID")
        let parsedRatios = try parseRatios(ratios)

        let result = try applyPanelOperation(
            client: client, worktreeID: worktreeID, tabID: tabID,
            operation: .resize(splitID: splitID, ratios: parsedRatios))
        printApplyResult(result, json: json)
    }
}

struct PanelBack: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "back",
        abstract: "Step a panel back in its navigation history"
    )

    @Argument(help: "Worktree name or ID")
    var worktree: String

    @Option(name: .long, help: "Tab ID")
    var tab: String

    @Option(name: .long, help: "Panel ID")
    var panel: String

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let worktreeID = try resolveWorktreeArg(worktree, client: client)
        let tabID = try parseUUID(tab, label: "tab ID")
        let panelID = try parseUUID(panel, label: "panel ID")

        let result = try applyPanelOperation(
            client: client, worktreeID: worktreeID, tabID: tabID,
            operation: .history(panelID: panelID, action: .back))
        printApplyResult(result, json: json)
    }
}

struct PanelForward: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "forward",
        abstract: "Step a panel forward in its navigation history"
    )

    @Argument(help: "Worktree name or ID")
    var worktree: String

    @Option(name: .long, help: "Tab ID")
    var tab: String

    @Option(name: .long, help: "Panel ID")
    var panel: String

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let worktreeID = try resolveWorktreeArg(worktree, client: client)
        let tabID = try parseUUID(tab, label: "tab ID")
        let panelID = try parseUUID(panel, label: "panel ID")

        let result = try applyPanelOperation(
            client: client, worktreeID: worktreeID, tabID: tabID,
            operation: .history(panelID: panelID, action: .forward))
        printApplyResult(result, json: json)
    }
}

struct PanelJump: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "jump",
        abstract: "Jump a panel to a specific index in its navigation history"
    )

    @Argument(help: "Worktree name or ID")
    var worktree: String

    @Option(name: .long, help: "Tab ID")
    var tab: String

    @Option(name: .long, help: "Panel ID")
    var panel: String

    @Option(name: .long, help: "History index to jump to")
    var index: Int

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let worktreeID = try resolveWorktreeArg(worktree, client: client)
        let tabID = try parseUUID(tab, label: "tab ID")
        let panelID = try parseUUID(panel, label: "panel ID")

        let result = try applyPanelOperation(
            client: client, worktreeID: worktreeID, tabID: tabID,
            operation: .history(panelID: panelID, action: .jump(index: index)))
        printApplyResult(result, json: json)
    }
}

struct PanelSelectTab: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "select-tab",
        abstract: "Make a tab the active tab"
    )

    @Argument(help: "Worktree name or ID")
    var worktree: String

    @Option(name: .long, help: "Tab ID to select")
    var tab: String

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let worktreeID = try resolveWorktreeArg(worktree, client: client)
        let tabID = try parseUUID(tab, label: "tab ID")

        let result = try applyPanelOperation(
            client: client, worktreeID: worktreeID, tabID: tabID,
            operation: .selectTab(tabID: tabID))
        printApplyResult(result, json: json)
    }
}

// MARK: - Shared flag groups (open/navigate share content; open/move share placement)

/// The four `PanelContent` sources as CLI flags. Exactly one must be given.
struct ContentOptions: ParsableArguments {
    @Option(name: .long, help: "Open/navigate to a file")
    var file: String?

    @Flag(name: .long, help: "Force rendered presentation for --file")
    var render = false

    @Flag(name: .long, help: "Force source presentation for --file")
    var source = false

    @Option(name: .long, help: "Open/navigate to a URL")
    var web: String?

    @Option(name: .long, help: "Open/navigate to a terminal's transcript (terminal ID)")
    var transcript: String?

    @Option(name: .long, help: "Open/navigate to a note (note ID)")
    var note: String?

    init() {}
}

/// `PanelPlacement` as CLI flags. Neither `--replace` nor `--beside` given
/// means `.automatic`.
struct PlacementOptions: ParsableArguments {
    @Option(name: .long, help: "Replace this panel's content in place (panel ID)")
    var replace: String?

    @Option(name: .long, help: "Place beside this anchor: 'primary' or a panel ID")
    var beside: String?

    @Option(name: .long, help: "Edge to place beside — required with --beside")
    var edge: PanelEdge?

    @Option(name: .long, help: "Share of space (0..1) for the new panel — optional with --beside")
    var share: Double?

    init() {}
}

/// Resolve `ContentOptions` into a `PanelContent`. Exactly one of
/// --file/--web/--transcript/--note must be given.
func resolvePanelContent(_ opts: ContentOptions) throws -> PanelContent {
    var resolved: [PanelContent] = []

    if let file = opts.file {
        guard !(opts.render && opts.source) else {
            throw CLIError.invalidArgument("Cannot use both --render and --source")
        }
        let presentation: FilePresentation = opts.render ? .rendered : (opts.source ? .source : .automatic)
        resolved.append(.file(FileReference(path: resolvePath(file), presentation: presentation)))
    }
    if let web = opts.web {
        guard let url = URL(string: web) else {
            throw CLIError.invalidArgument("Invalid URL: \(web)")
        }
        resolved.append(.web(url))
    }
    if let transcript = opts.transcript {
        resolved.append(.transcript(terminalID: try parseUUID(transcript, label: "terminal ID")))
    }
    if let note = opts.note {
        resolved.append(.note(noteID: try parseUUID(note, label: "note ID")))
    }

    guard resolved.count == 1 else {
        throw CLIError.invalidArgument(
            resolved.isEmpty
                ? "Specify one of --file, --web, --transcript, --note"
                : "Specify only one of --file, --web, --transcript, --note")
    }
    return resolved[0]
}

/// Resolve `PlacementOptions` into a `PanelPlacement`. `--replace` and
/// `--beside` are mutually exclusive; `--edge`/`--share` are only valid
/// alongside `--beside`; no placement flags at all means `.automatic`.
func resolvePanelPlacement(_ opts: PlacementOptions) throws -> PanelPlacement {
    if let share = opts.share {
        guard (0...1).contains(share) else {
            throw CLIError.invalidArgument("--share must be between 0 and 1")
        }
    }

    switch (opts.replace, opts.beside) {
    case (nil, nil):
        guard opts.edge == nil, opts.share == nil else {
            throw CLIError.invalidArgument("--edge/--share require --beside")
        }
        return .automatic

    case (let replace?, nil):
        guard opts.edge == nil, opts.share == nil else {
            throw CLIError.invalidArgument("--edge/--share are not valid with --replace")
        }
        return .replace(panelID: try parseUUID(replace, label: "panel ID"))

    case (nil, let beside?):
        guard let edge = opts.edge else {
            throw CLIError.invalidArgument("--beside requires --edge")
        }
        let anchor: PanelAnchor = beside.lowercased() == "primary"
            ? .primary
            : .panel(try parseUUID(beside, label: "--beside target"))
        return .beside(target: anchor, edge: edge, share: opts.share)

    case (.some, .some):
        throw CLIError.invalidArgument("Cannot use both --replace and --beside")
    }
}

/// Parse a comma-separated ratio list, e.g. "0.5,0.5" -> [0.5, 0.5].
func parseRatios(_ csv: String) throws -> [Double] {
    let parts = csv.split(separator: ",", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
    guard !parts.isEmpty, !parts.contains("") else {
        throw CLIError.invalidArgument("Invalid --ratios: \(csv)")
    }
    return try parts.map { part in
        guard let value = Double(part) else {
            throw CLIError.invalidArgument("Invalid ratio: \(part)")
        }
        return value
    }
}

// MARK: - Layout tree rendering (shared by `list` and Arrange result printing)

func describe(_ content: PanelContent) -> String {
    switch content {
    case .file(let ref):
        return "file \(ref.path)" + (ref.presentation == .automatic ? "" : " (\(ref.presentation.rawValue))")
    case .web(let url):
        return "web \(url.absoluteString)"
    case .transcript(let terminalID):
        return "transcript \(terminalID)"
    case .note(let noteID):
        return "note \(noteID)"
    }
}

func describe(_ content: PrimaryContent) -> String {
    switch content {
    case .terminal(let terminalID):
        return "terminal \(terminalID)"
    case .note(let noteID):
        return "note \(noteID)"
    case .file(let ref):
        return "file \(ref.path)" + (ref.presentation == .automatic ? "" : " (\(ref.presentation.rawValue))")
    case .web(let url):
        return "web \(url.absoluteString)"
    case .transcript(let terminalID):
        return "transcript \(terminalID)"
    }
}

/// Render a layout tree indented, one line per node. Panel slots show their
/// panelID + content; splits show their splitID, direction, and ratios;
/// `.primary` marks where the tab's primary anchor sits in the tree — these
/// IDs are the handles agents need to target Arrange mutations.
func renderPanelTree(_ node: PanelLayoutNode, indent: String) -> [String] {
    switch node {
    case .primary:
        return ["\(indent)[primary]"]
    case .panel(let slot):
        return ["\(indent)panel \(slot.id): \(describe(slot.content))"]
    case .split(let split):
        let ratios = split.ratios.map { String(format: "%.2f", $0) }.joined(separator: ",")
        var lines = ["\(indent)split \(split.id) (\(split.direction.rawValue), ratios: \(ratios))"]
        for child in split.children {
            lines.append(contentsOf: renderPanelTree(child, indent: indent + "  "))
        }
        return lines
    }
}

/// Full text rendering of one tab: header + primary + layout tree.
func tabLines(_ tab: WorkspaceTabSurface, activeTabID: UUID?) -> [String] {
    let marker = tab.id == activeTabID ? " [ACTIVE]" : ""
    let label = tab.label.map { " — \($0)" } ?? ""
    var lines = ["Tab \(tab.id)\(marker)\(label)"]
    lines.append("  primary: \(describe(tab.primary))")
    lines.append("  revision: \(tab.revision)")
    lines.append(contentsOf: renderPanelTree(tab.layout, indent: "  "))
    return lines
}

private func printApplyResult(_ result: PanelApplyResult, json: Bool) {
    if json {
        printJSON(result)
    } else {
        if result.replayed {
            print("(replayed — operation was already applied)")
        }
        for line in tabLines(result.tab, activeTabID: nil) {
            print(line)
        }
    }
}

// MARK: - Helpers

private func parseUUID(_ raw: String, label: String) throws -> UUID {
    guard let id = UUID(uuidString: raw) else {
        throw CLIError.invalidArgument("Invalid \(label): \(raw)")
    }
    return id
}

/// Fetch a tab's current revision, then apply an operation against it as
/// `origin: .agentCLI`. Every Arrange verb funnels through here so the
/// `baseRevision` fetch-then-apply sequence lives in exactly one place.
private func applyPanelOperation(
    client: SocketClient, worktreeID: UUID, tabID: UUID, operation: PanelOperation
) throws -> PanelApplyResult {
    let current: PanelGetResult = try client.call(
        method: RPCMethod.panelGet,
        params: PanelGetParams(worktreeID: worktreeID, tabID: tabID),
        resultType: PanelGetResult.self
    )
    guard let tab = current.tabs.first(where: { $0.id == tabID }) else {
        throw CLIError.invalidArgument("Tab not found: \(tabID)")
    }

    let envelope = PanelOperationEnvelope(
        operationID: UUID(), worktreeID: worktreeID, tabID: tabID,
        baseRevision: tab.revision, origin: .agentCLI, operation: operation)
    return try client.call(
        method: RPCMethod.panelApply,
        params: PanelApplyParams(envelope: envelope),
        resultType: PanelApplyResult.self
    )
}

/// Resolve a worktree argument that could be a UUID or a name. Duplicated
/// from `TerminalCommands.swift` (that copy is `private` there) rather than
/// promoted to a shared internal helper — see PR brief.
private func resolveWorktreeArg(_ nameOrID: String, client: SocketClient) throws -> UUID {
    if let id = UUID(uuidString: nameOrID) {
        return id
    }

    let worktrees: [Worktree] = try client.call(
        method: RPCMethod.worktreeList,
        params: WorktreeListParams(),
        resultType: [Worktree].self
    )

    let matches = worktrees.filter { $0.name == nameOrID || $0.displayName == nameOrID }
    guard let match = matches.first else {
        throw CLIError.invalidArgument("No worktree found with name or ID: \(nameOrID)")
    }
    if matches.count > 1 {
        throw CLIError.invalidArgument("Multiple worktrees match '\(nameOrID)'. Use the full ID instead.")
    }
    return match.id
}
