import ArgumentParser
import Foundation
import TBDShared

struct PanelCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "panel",
        abstract: "Inspect and arrange the side panel in each tab of a worktree",
        subcommands: [
            PanelList.self,
            PanelOpen.self,
            PanelNavigate.self,
            PanelClose.self,
            PanelSelect.self,
            PanelBack.self,
            PanelForward.self,
            PanelJump.self,
            PanelCollapse.self,
            PanelExpand.self,
            PanelResize.self,
        ]
    )
}

private let tabHelp: ArgumentHelp = "Tab ID (default: the worktree's active tab)"

// MARK: - panel list (See)

struct PanelList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Show each tab's primary content and side panel — read-only, works even when the side panel is off"
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

        // `panel.get` is ungated, so `list` answers while the flag is off.
        // Unscoped even with `--tab`: only the unscoped get reports the
        // worktree's active tab (see `panelListResult`).
        let all: PanelGetResult = try client.call(
            method: RPCMethod.panelGet,
            params: PanelGetParams(worktreeID: worktreeID),
            resultType: PanelGetResult.self
        )
        let result = panelListResult(all, tabID: tabID)

        if json {
            printJSON(result)
        } else {
            for line in panelListLines(result) {
                print(line)
            }
        }
    }
}

/// What `tbd panel list` shows: the worktree's unscoped `panel.get` reply,
/// narrowed to `tabID` when one is given. A tab-scoped get reports no active
/// tab, so `list --tab` narrows the unscoped reply instead, which keeps the
/// worktree's real `activeTabID` and with it the requested tab's `[ACTIVE]`
/// mark.
func panelListResult(_ all: PanelGetResult, tabID: UUID?) -> PanelGetResult {
    guard let tabID else { return all }
    return PanelGetResult(tabs: all.tabs.filter { $0.id == tabID }, activeTabID: all.activeTabID)
}

/// The text `tbd panel list` prints for `result`: each tab's lines with a
/// blank line between tabs, or a note when there is no tab.
func panelListLines(_ result: PanelGetResult) -> [String] {
    guard !result.tabs.isEmpty else { return ["No tabs found."] }
    var lines: [String] = []
    for (index, tab) in result.tabs.enumerated() {
        if index > 0 { lines.append("") }
        lines.append(contentsOf: tabLines(tab, activeTabID: result.activeTabID))
    }
    return lines
}

// MARK: - Arrange verbs
//
// Each verb names its `PanelOperation` in `operation()` — pure, so tests pin
// the mapping without a daemon — and `run()` hands it to
// `runPanelOperation`, which resolves the tab and applies it.

struct PanelOpen: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Show content in the side panel",
        discussion: """
            Selects a panel already showing this content. Otherwise a file, web page \
            or note goes into the active panel when it is the same kind, else into the \
            most recently used panel of that kind, and the old content stays in that \
            panel's history. A transcript, --new-panel, or content with no panel of \
            its kind gets a new panel after the active one. Opening also expands a \
            collapsed side panel.
            """
    )

    @Argument(help: "Worktree name or ID")
    var worktree: String

    @Option(name: .long, help: tabHelp)
    var tab: String?

    @OptionGroup var content: ContentOptions

    @Flag(name: .long, help: "Always open a new panel instead of reusing one of the same kind")
    var newPanel = false

    @Flag(name: .long, help: "Output JSON")
    var json = false

    func operation() throws -> PanelOperation {
        .open(content: try resolvePanelContent(content), newPanel: newPanel)
    }

    mutating func run() async throws {
        try runPanelOperation(worktree: worktree, tab: tab, json: json, operation: operation())
    }
}

struct PanelNavigate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "navigate",
        abstract: "Point one panel at new content of the same kind"
    )

    @Argument(help: "Worktree name or ID")
    var worktree: String

    @Option(name: .long, help: tabHelp)
    var tab: String?

    @Option(name: .long, help: "Panel ID to navigate")
    var panel: String

    @OptionGroup var content: ContentOptions

    @Flag(name: .long, help: "Output JSON")
    var json = false

    func operation() throws -> PanelOperation {
        .navigate(
            panelID: try parseUUID(panel, label: "panel ID"),
            destination: try resolvePanelContent(content))
    }

    mutating func run() async throws {
        try runPanelOperation(worktree: worktree, tab: tab, json: json, operation: operation())
    }
}

struct PanelClose: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close",
        abstract: "Close a panel and its history"
    )

    @Argument(help: "Worktree name or ID")
    var worktree: String

    @Option(name: .long, help: tabHelp)
    var tab: String?

    @Option(name: .long, help: "Panel ID to close")
    var panel: String

    @Flag(name: .long, help: "Output JSON")
    var json = false

    func operation() throws -> PanelOperation {
        .close(panelID: try parseUUID(panel, label: "panel ID"))
    }

    mutating func run() async throws {
        try runPanelOperation(worktree: worktree, tab: tab, json: json, operation: operation())
    }
}

struct PanelSelect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "select",
        abstract: "Bring a panel to the front, expanding a collapsed side panel"
    )

    @Argument(help: "Worktree name or ID")
    var worktree: String

    @Option(name: .long, help: tabHelp)
    var tab: String?

    @Option(name: .long, help: "Panel ID to select")
    var panel: String

    @Flag(name: .long, help: "Output JSON")
    var json = false

    func operation() throws -> PanelOperation {
        .select(panelID: try parseUUID(panel, label: "panel ID"))
    }

    mutating func run() async throws {
        try runPanelOperation(worktree: worktree, tab: tab, json: json, operation: operation())
    }
}

struct PanelBack: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "back",
        abstract: "Step a panel back in its navigation history"
    )

    @Argument(help: "Worktree name or ID")
    var worktree: String

    @Option(name: .long, help: tabHelp)
    var tab: String?

    @Option(name: .long, help: "Panel ID")
    var panel: String

    @Flag(name: .long, help: "Output JSON")
    var json = false

    func operation() throws -> PanelOperation {
        .history(panelID: try parseUUID(panel, label: "panel ID"), action: .back)
    }

    mutating func run() async throws {
        try runPanelOperation(worktree: worktree, tab: tab, json: json, operation: operation())
    }
}

struct PanelForward: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "forward",
        abstract: "Step a panel forward in its navigation history"
    )

    @Argument(help: "Worktree name or ID")
    var worktree: String

    @Option(name: .long, help: tabHelp)
    var tab: String?

    @Option(name: .long, help: "Panel ID")
    var panel: String

    @Flag(name: .long, help: "Output JSON")
    var json = false

    func operation() throws -> PanelOperation {
        .history(panelID: try parseUUID(panel, label: "panel ID"), action: .forward)
    }

    mutating func run() async throws {
        try runPanelOperation(worktree: worktree, tab: tab, json: json, operation: operation())
    }
}

struct PanelJump: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "jump",
        abstract: "Jump a panel to a specific index in its navigation history"
    )

    @Argument(help: "Worktree name or ID")
    var worktree: String

    @Option(name: .long, help: tabHelp)
    var tab: String?

    @Option(name: .long, help: "Panel ID")
    var panel: String

    @Option(name: .long, help: "History index to jump to")
    var index: Int

    @Flag(name: .long, help: "Output JSON")
    var json = false

    func operation() throws -> PanelOperation {
        .history(panelID: try parseUUID(panel, label: "panel ID"), action: .jump(index: index))
    }

    mutating func run() async throws {
        try runPanelOperation(worktree: worktree, tab: tab, json: json, operation: operation())
    }
}

struct PanelCollapse: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "collapse",
        abstract: "Hide the side panel, keeping its panels"
    )

    @Argument(help: "Worktree name or ID")
    var worktree: String

    @Option(name: .long, help: tabHelp)
    var tab: String?

    @Flag(name: .long, help: "Output JSON")
    var json = false

    func operation() -> PanelOperation {
        .setCollapsed(true)
    }

    mutating func run() async throws {
        try runPanelOperation(worktree: worktree, tab: tab, json: json, operation: operation())
    }
}

struct PanelExpand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "expand",
        abstract: "Show a collapsed side panel again"
    )

    @Argument(help: "Worktree name or ID")
    var worktree: String

    @Option(name: .long, help: tabHelp)
    var tab: String?

    @Flag(name: .long, help: "Output JSON")
    var json = false

    func operation() -> PanelOperation {
        .setCollapsed(false)
    }

    mutating func run() async throws {
        try runPanelOperation(worktree: worktree, tab: tab, json: json, operation: operation())
    }
}

struct PanelResize: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resize",
        abstract: "Set the side panel's width"
    )

    @Argument(help: "Worktree name or ID")
    var worktree: String

    @Option(name: .long, help: tabHelp)
    var tab: String?

    @Option(
        name: .long,
        help: """
            Width as a fraction of the tab's width, from \(SideRegion.widthRange.lowerBound) \
            to \(SideRegion.widthRange.upperBound)
            """)
    var width: Double

    @Flag(name: .long, help: "Output JSON")
    var json = false

    /// Sent as given: the daemon rejects an out-of-range or non-finite width
    /// with a typed error, which `run()` prints.
    func operation() -> PanelOperation {
        .resize(width: width)
    }

    mutating func run() async throws {
        try runPanelOperation(worktree: worktree, tab: tab, json: json, operation: operation())
    }
}

// MARK: - Content flags (used by open and navigate)

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
    let content = resolved[0]
    if opts.render || opts.source {
        guard case .file = content else {
            throw CLIError.invalidArgument("--render/--source only apply to --file")
        }
    }
    return content
}

// MARK: - Rendering (used by `list` and by Arrange result printing)

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

/// The side region, one line per panel in tab-strip order. Each panel line
/// carries the panel ID — the handle `--panel` takes — and its content, which
/// `describe` leads with the panel's kind; the active panel is marked
/// `[ACTIVE]`. The header gives the width and notes a collapsed region.
func renderSideRegion(_ surface: WorkspaceTabSurface) -> [String] {
    let side = surface.side
    guard !side.panels.isEmpty else { return ["side region: no panels"] }

    let count = side.panels.count == 1 ? "1 panel" : "\(side.panels.count) panels"
    var header = "side region: \(count), width \(String(format: "%.2f", side.width))"
    if side.collapsed {
        header += ", collapsed (hidden, panels kept; `tbd panel expand` shows it)"
    }

    var lines = [header]
    for panel in side.panels {
        let marker = panel.id == side.activePanelID ? " [ACTIVE]" : ""
        let shown = panel.content.map { describe($0) } ?? "(no content)"
        lines.append("  panel \(panel.id)\(marker): \(shown)")
    }
    return lines
}

/// Full text rendering of one tab: header + primary + revision + side region.
func tabLines(_ tab: WorkspaceTabSurface, activeTabID: UUID?) -> [String] {
    let marker = tab.id == activeTabID ? " [ACTIVE]" : ""
    let label = tab.label.map { " — \($0)" } ?? ""
    var lines = ["Tab \(tab.id)\(marker)\(label)"]
    lines.append("  primary: \(describe(tab.primary))")
    lines.append("  revision: \(tab.revision)")
    lines.append(contentsOf: renderSideRegion(tab).map { "  " + $0 })
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

/// The tab an Arrange verb acts on, and the `panel.get` reply its
/// `baseRevision` comes from.
struct PanelTarget {
    let tabID: UUID
    let current: PanelGetResult
}

/// Resolves the tab an Arrange verb acts on with one `panel.get`, whose reply
/// the envelope's `baseRevision` is then read from. `get` sends that get,
/// scoped to the tab it is passed or unscoped for nil.
///
/// With `--tab`, the get is scoped to that tab. Without it, the get is
/// unscoped: its `activeTabID` names the worktree's active tab (the daemon
/// reads `worktree.activeTabID`, which the app keeps current), and it carries
/// every surface of the worktree, that tab's among them when it has one.
func resolvePanelTarget(
    tab: String?, get: (_ tabID: UUID?) throws -> PanelGetResult
) throws -> PanelTarget {
    if let tab {
        let tabID = try parseUUID(tab, label: "tab ID")
        return PanelTarget(tabID: tabID, current: try get(tabID))
    }
    let current = try get(nil)
    guard let active = current.activeTabID else {
        throw CLIError.invalidArgument("no active tab; pass --tab")
    }
    return PanelTarget(tabID: active, current: current)
}

/// Resolve the worktree and tab, apply `operation` as the agent CLI, and
/// print the tab it leaves behind. Every Arrange verb's `run()` is this call:
/// one `panel.get` (see `resolvePanelTarget`), then one `panel.apply`.
private func runPanelOperation(
    worktree: String, tab: String?, json: Bool, operation: PanelOperation
) throws {
    let client = SocketClient()
    let worktreeID = try resolveWorktreeArg(worktree, client: client)
    let target = try resolvePanelTarget(tab: tab) { scopedTabID in
        try client.call(
            method: RPCMethod.panelGet,
            params: PanelGetParams(worktreeID: worktreeID, tabID: scopedTabID),
            resultType: PanelGetResult.self
        )
    }
    let envelope = panelEnvelope(
        worktreeID: worktreeID, tabID: target.tabID, current: target.current, operation: operation)
    let result: PanelApplyResult = try client.call(
        method: RPCMethod.panelApply,
        params: PanelApplyParams(envelope: envelope),
        resultType: PanelApplyResult.self
    )
    printApplyResult(result, json: json)
}

/// The envelope an Arrange verb sends, as `origin: .agentCLI`. `baseRevision`
/// is the tab's revision in `current`, or nil when `current` holds no surface
/// for the tab. The apply still goes out then, so the daemon names the real
/// reason: the side panel is off (no surfaces exist until it is turned on),
/// or no surface exists for that tab.
func panelEnvelope(
    worktreeID: UUID, tabID: UUID, current: PanelGetResult, operation: PanelOperation,
    operationID: UUID = UUID()
) -> PanelOperationEnvelope {
    PanelOperationEnvelope(
        operationID: operationID, worktreeID: worktreeID, tabID: tabID,
        baseRevision: current.tabs.first(where: { $0.id == tabID })?.revision,
        origin: .agentCLI, operation: operation)
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
