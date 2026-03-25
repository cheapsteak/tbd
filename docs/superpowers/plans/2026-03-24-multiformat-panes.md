# Multi-Format Panes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add webview and code viewer panes alongside terminals, all splittable within the same layout tree.

**Architecture:** Generalize `LayoutNode` leaves from terminal-only to a `PaneContent` enum (terminal/webview/codeViewer). Replace the terminal-driven tab system with a `Tab` model as single source of truth. Add `WebviewPaneView` (WKWebView) and `CodeViewerPaneView` (Highlightr) as new pane renderers.

**Tech Stack:** SwiftUI, WebKit (WKWebView), Highlightr (SPM), SwiftTerm

**Spec:** `docs/superpowers/specs/2026-03-24-multiformat-panes-design.md`

---

## File Structure

### New files
- `Sources/TBDApp/Terminal/PaneContent.swift` — `PaneContent` enum, `Tab` struct
- `Sources/TBDApp/Panes/PanePlaceholder.swift` — universal pane leaf wrapper (replaces `TerminalPanelPlaceholder`)
- `Sources/TBDApp/Panes/WebviewPaneView.swift` — WKWebView NSViewRepresentable
- `Sources/TBDApp/Panes/CodeViewerPaneView.swift` — Highlightr-based code viewer with file sidebar
- `Sources/TBDApp/TabBar.swift` — generic tab bar (replaces `TerminalTabBar`)
- `Tests/TBDAppTests/LayoutNodeTests.swift` — tests for PaneContent, LayoutNode migration, tree ops
- `Tests/TBDAppTests/PaneContentTests.swift` — tests for PaneContent codable, paneID

### Modified files
- `Package.swift` — add Highlightr dependency
- `Sources/TBDApp/Terminal/LayoutNode.swift` — `.terminal()` → `.pane(PaneContent)`, rename helpers
- `Sources/TBDApp/Terminal/SplitLayoutView.swift` — switch on `.pane()`, remove `TerminalPanelPlaceholder`
- `Sources/TBDApp/Terminal/TerminalContainerView.swift` — read from `appState.tabs`, use `TabBar`
- `Sources/TBDApp/AppState.swift` — add `tabs: [UUID: [Tab]]` property
- `Sources/TBDApp/AppState+Terminals.swift` — update `createTerminal` to also append tab
- `Sources/TBDApp/ContentView.swift` — PR link in toolbar
- `Sources/TBDApp/FileViewer/FileViewerPanel.swift` — click handler opens code viewer tab
- `Sources/TBDApp/Terminal/TBDTerminalView.swift` — Cmd+Click file path interception

---

## Task 1: Add Highlightr dependency to Package.swift

**Files:**
- Modify: `Package.swift:10-14` (dependencies array), `Package.swift:53-58` (TBDApp target)

- [ ] **Step 1: Add Highlightr to package dependencies**

In `Package.swift`, add to the `dependencies` array:
```swift
.package(url: "https://github.com/raspu/Highlightr", from: "2.2.1"),
```

And add to the TBDApp target's `dependencies`:
```swift
.product(name: "Highlightr", package: "Highlightr"),
```

- [ ] **Step 2: Verify it resolves**

Run: `swift package resolve`
Expected: resolves without errors

- [ ] **Step 3: Verify it builds**

Run: `swift build`
Expected: builds successfully

- [ ] **Step 4: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "feat: add Highlightr dependency for syntax highlighting"
```

---

## Task 2: PaneContent enum and Tab model

**Files:**
- Create: `Sources/TBDApp/Terminal/PaneContent.swift`
- Create: `Tests/TBDAppTests/PaneContentTests.swift`

- [ ] **Step 1: Write tests for PaneContent**

Create `Tests/TBDAppTests/PaneContentTests.swift`:
```swift
import Testing
import Foundation
@testable import TBDApp

@Suite("PaneContent")
struct PaneContentTests {
    @Test("paneID returns correct ID for each variant")
    func paneID() {
        let termID = UUID()
        let webID = UUID()
        let codeID = UUID()

        #expect(PaneContent.terminal(terminalID: termID).paneID == termID)
        #expect(PaneContent.webview(id: webID, url: URL(string: "https://github.com")!).paneID == webID)
        #expect(PaneContent.codeViewer(id: codeID, path: "/tmp/test.swift").paneID == codeID)
    }

    @Test("PaneContent roundtrips through Codable")
    func codableRoundtrip() throws {
        let cases: [PaneContent] = [
            .terminal(terminalID: UUID()),
            .webview(id: UUID(), url: URL(string: "https://github.com/foo/bar/pull/42")!),
            .codeViewer(id: UUID(), path: "/Users/test/project/main.swift"),
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for original in cases {
            let data = try encoder.encode(original)
            let decoded = try decoder.decode(PaneContent.self, from: data)
            #expect(decoded == original)
        }
    }

    @Test("Tab model stores PaneContent")
    func tabModel() {
        let id = UUID()
        let content = PaneContent.terminal(terminalID: UUID())
        let tab = Tab(id: id, content: content, label: "My Tab")
        #expect(tab.id == id)
        #expect(tab.content == content)
        #expect(tab.label == "My Tab")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PaneContentTests`
Expected: FAIL — `PaneContent` and `Tab` not defined

- [ ] **Step 3: Implement PaneContent and Tab**

Create `Sources/TBDApp/Terminal/PaneContent.swift`:
```swift
import Foundation

// MARK: - PaneContent

enum PaneContent: Codable, Equatable, Sendable {
    case terminal(terminalID: UUID)
    case webview(id: UUID, url: URL)
    case codeViewer(id: UUID, path: String)

    var paneID: UUID {
        switch self {
        case .terminal(let id): return id
        case .webview(let id, _): return id
        case .codeViewer(let id, _): return id
        }
    }
}

// MARK: - Tab

struct Tab: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var content: PaneContent
    var label: String?
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PaneContentTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDApp/Terminal/PaneContent.swift Tests/TBDAppTests/PaneContentTests.swift
git commit -m "feat: add PaneContent enum and Tab model"
```

---

## Task 3: Migrate LayoutNode from .terminal to .pane(PaneContent)

**Files:**
- Modify: `Sources/TBDApp/Terminal/LayoutNode.swift`
- Create: `Tests/TBDAppTests/LayoutNodeTests.swift`

- [ ] **Step 1: Write tests for migrated LayoutNode**

Create `Tests/TBDAppTests/LayoutNodeTests.swift`:
```swift
import Testing
import Foundation
import CoreGraphics
@testable import TBDApp

@Suite("LayoutNode")
struct LayoutNodeTests {
    @Test("splitPane replaces target pane with a split containing original + new")
    func splitPane() {
        let id1 = UUID()
        let id2 = UUID()
        let node = LayoutNode.pane(.terminal(terminalID: id1))
        let newContent = PaneContent.codeViewer(id: id2, path: "/tmp/test.swift")
        let result = node.splitPane(paneID: id1, direction: .horizontal, newContent: newContent)

        if case .split(let dir, let children, let ratios) = result {
            #expect(dir == .horizontal)
            #expect(children.count == 2)
            #expect(ratios == [0.5, 0.5])
            #expect(children[0] == .pane(.terminal(terminalID: id1)))
            #expect(children[1] == .pane(newContent))
        } else {
            Issue.record("Expected split node")
        }
    }

    @Test("removePane removes target and simplifies tree")
    func removePane() {
        let id1 = UUID()
        let id2 = UUID()
        let node = LayoutNode.split(
            direction: .horizontal,
            children: [.pane(.terminal(terminalID: id1)), .pane(.terminal(terminalID: id2))],
            ratios: [0.5, 0.5]
        )
        let result = node.removePane(paneID: id1)
        #expect(result == .pane(.terminal(terminalID: id2)))
    }

    @Test("allPaneIDs returns all leaf IDs")
    func allPaneIDs() {
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        let node = LayoutNode.split(
            direction: .horizontal,
            children: [
                .pane(.terminal(terminalID: id1)),
                .split(direction: .vertical, children: [
                    .pane(.webview(id: id2, url: URL(string: "https://github.com")!)),
                    .pane(.codeViewer(id: id3, path: "/tmp/test.swift")),
                ], ratios: [0.5, 0.5]),
            ],
            ratios: [0.5, 0.5]
        )
        let ids = node.allPaneIDs()
        #expect(Set(ids) == Set([id1, id2, id3]))
    }

    @Test("Codable backward compat: old terminal format decodes to .pane(.terminal())")
    func codableBackwardCompat() throws {
        // Simulates the old on-disk format
        let termID = UUID()
        let oldJSON = """
        {"type":"terminal","terminalID":"\(termID.uuidString)"}
        """
        let decoded = try JSONDecoder().decode(LayoutNode.self, from: oldJSON.data(using: .utf8)!)
        #expect(decoded == .pane(.terminal(terminalID: termID)))
    }

    @Test("Codable roundtrip for all pane types")
    func codableRoundtrip() throws {
        let nodes: [LayoutNode] = [
            .pane(.terminal(terminalID: UUID())),
            .pane(.webview(id: UUID(), url: URL(string: "https://github.com")!)),
            .pane(.codeViewer(id: UUID(), path: "/tmp/test.swift")),
            .split(direction: .horizontal, children: [
                .pane(.terminal(terminalID: UUID())),
                .pane(.webview(id: UUID(), url: URL(string: "https://example.com")!)),
            ], ratios: [0.5, 0.5]),
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for original in nodes {
            let data = try encoder.encode(original)
            let decoded = try decoder.decode(LayoutNode.self, from: data)
            #expect(decoded == original)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LayoutNodeTests`
Expected: FAIL — `.pane()` case doesn't exist, `splitPane` method doesn't exist

- [ ] **Step 3: Rewrite LayoutNode.swift**

Replace the entire contents of `Sources/TBDApp/Terminal/LayoutNode.swift` with:

```swift
import Foundation
import CoreGraphics

// MARK: - SplitDirection

enum SplitDirection: String, Codable, Sendable {
    case horizontal, vertical
}

// MARK: - LayoutNode

indirect enum LayoutNode: Equatable, Sendable {
    case pane(PaneContent)
    case split(direction: SplitDirection, children: [LayoutNode], ratios: [CGFloat])

    // MARK: - Helpers

    /// Finds the pane with the given ID and replaces it with a split
    /// containing the original + new pane at 50/50 ratio.
    func splitPane(paneID: UUID, direction: SplitDirection, newContent: PaneContent) -> LayoutNode {
        switch self {
        case .pane(let content):
            if content.paneID == paneID {
                return .split(
                    direction: direction,
                    children: [
                        .pane(content),
                        .pane(newContent),
                    ],
                    ratios: [0.5, 0.5]
                )
            }
            return self

        case .split(let dir, let children, let ratios):
            let newChildren = children.map { child in
                child.splitPane(paneID: paneID, direction: direction, newContent: newContent)
            }
            return .split(direction: dir, children: newChildren, ratios: ratios)
        }
    }

    /// Removes a pane, simplifying the tree. If a split has one child left,
    /// unwrap it. Returns nil if the last pane is removed.
    func removePane(paneID: UUID) -> LayoutNode? {
        switch self {
        case .pane(let content):
            if content.paneID == paneID {
                return nil
            }
            return self

        case .split(let direction, let children, let ratios):
            var newChildren: [LayoutNode] = []
            var newRatios: [CGFloat] = []

            for (index, child) in children.enumerated() {
                if let remaining = child.removePane(paneID: paneID) {
                    newChildren.append(remaining)
                    newRatios.append(ratios[index])
                }
            }

            if newChildren.isEmpty {
                return nil
            }

            if newChildren.count == 1 {
                return newChildren[0]
            }

            // Renormalize ratios so they sum to 1.0
            let total = newRatios.reduce(0, +)
            if total > 0 {
                newRatios = newRatios.map { $0 / total }
            }

            return .split(direction: direction, children: newChildren, ratios: newRatios)
        }
    }

    /// Flat list of all pane IDs in the tree.
    func allPaneIDs() -> [UUID] {
        switch self {
        case .pane(let content):
            return [content.paneID]
        case .split(_, let children, _):
            return children.flatMap { $0.allPaneIDs() }
        }
    }
}

// MARK: - Codable (manual conformance for indirect enum)

extension LayoutNode: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case terminalID  // backward compat for old terminal format
        case paneContent  // new: encoded PaneContent
        case direction
        case children
        case ratios
    }

    private enum NodeType: String, Codable {
        case terminal  // backward compat
        case pane      // new generic pane
        case split
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(NodeType.self, forKey: .type)

        switch type {
        case .terminal:
            // Backward compat: old format had type:"terminal" + terminalID
            let terminalID = try container.decode(UUID.self, forKey: .terminalID)
            self = .pane(.terminal(terminalID: terminalID))
        case .pane:
            let content = try container.decode(PaneContent.self, forKey: .paneContent)
            self = .pane(content)
        case .split:
            let direction = try container.decode(SplitDirection.self, forKey: .direction)
            let children = try container.decode([LayoutNode].self, forKey: .children)
            let ratios = try container.decode([CGFloat].self, forKey: .ratios)
            self = .split(direction: direction, children: children, ratios: ratios)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .pane(let content):
            try container.encode(NodeType.pane, forKey: .type)
            try container.encode(content, forKey: .paneContent)
        case .split(let direction, let children, let ratios):
            try container.encode(NodeType.split, forKey: .type)
            try container.encode(direction, forKey: .direction)
            try container.encode(children, forKey: .children)
            try container.encode(ratios, forKey: .ratios)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LayoutNodeTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDApp/Terminal/LayoutNode.swift Tests/TBDAppTests/LayoutNodeTests.swift
git commit -m "feat: migrate LayoutNode from .terminal to .pane(PaneContent)"
```

---

## Task 4: Update SplitLayoutView — extract TerminalPanelPlaceholder, wire PanePlaceholder

**Files:**
- Create: `Sources/TBDApp/Panes/PanePlaceholder.swift`
- Modify: `Sources/TBDApp/Terminal/SplitLayoutView.swift`

This task depends on Tasks 2 and 3.

- [ ] **Step 1: Create PanePlaceholder**

Create `Sources/TBDApp/Panes/PanePlaceholder.swift`:
```swift
import SwiftUI
import TBDShared

/// Universal leaf wrapper for the split layout tree.
/// Renders the appropriate view based on PaneContent type.
struct PanePlaceholder: View {
    let content: PaneContent
    let worktree: Worktree
    @Binding var layout: LayoutNode
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            paneToolbar
            Divider()
            paneContent
        }
    }

    @ViewBuilder
    private var paneToolbar: some View {
        HStack(spacing: 8) {
            paneLabel
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            // Webview: back/forward buttons
            if case .webview = content {
                // Note: WebviewToolbarContent needs a reference to the WKWebView.
                // This will be wired via a @State var in the full implementation.
                // For now, stub with disabled buttons.
                Button { } label: {
                    Image(systemName: "chevron.left").font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(true)

                Button { } label: {
                    Image(systemName: "chevron.right").font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(true)
            }

            // Split buttons for terminal panes only
            if case .terminal = content {
                Button(action: { splitRight() }) {
                    HStack(spacing: 2) {
                        Image(systemName: "rectangle.split.1x2")
                            .rotationEffect(.degrees(90))
                        Text("Split Right")
                    }
                    .font(.caption)
                }
                .buttonStyle(.borderless)

                Button(action: { splitDown() }) {
                    HStack(spacing: 2) {
                        Image(systemName: "rectangle.split.1x2")
                        Text("Split Down")
                    }
                    .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var paneLabel: some View {
        switch content {
        case .terminal(let terminalID):
            Text("Terminal: \(terminalID.uuidString.prefix(8))")
        case .webview(_, let url):
            HStack(spacing: 4) {
                Image(systemName: "globe")
                Text(url.host ?? url.absoluteString)
            }
        case .codeViewer(_, let path):
            HStack(spacing: 4) {
                Image(systemName: "doc.text")
                Text(URL(fileURLWithPath: path).lastPathComponent)
            }
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch content {
        case .terminal(let terminalID):
            terminalContent(terminalID: terminalID)
        case .webview(_, let url):
            WebviewPaneView(url: url)
        case .codeViewer(_, let path):
            CodeViewerPaneView(path: path, worktreePath: worktree.path)
        }
    }

    @ViewBuilder
    private func terminalContent(terminalID: UUID) -> some View {
        let terminal: Terminal? = {
            for (_, terms) in appState.terminals {
                if let t = terms.first(where: { $0.id == terminalID }) {
                    return t
                }
            }
            return nil
        }()

        if let terminal {
            TerminalPanelView(
                terminalID: terminalID,
                tmuxServer: worktree.tmuxServer,
                tmuxWindowID: terminal.tmuxWindowID,
                tmuxBridge: appState.tmuxBridge
            )
            .id(terminalID)
        } else {
            ZStack {
                Color(nsColor: .black)
                VStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(worktree.displayName)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(worktree.branch)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func splitRight() {
        let newContent = PaneContent.terminal(terminalID: UUID())
        layout = layout.splitPane(paneID: content.paneID, direction: .horizontal, newContent: newContent)
    }

    private func splitDown() {
        let newContent = PaneContent.terminal(terminalID: UUID())
        layout = layout.splitPane(paneID: content.paneID, direction: .vertical, newContent: newContent)
    }
}
```

- [ ] **Step 2: Update SplitLayoutView to use .pane() and PanePlaceholder**

In `Sources/TBDApp/Terminal/SplitLayoutView.swift`:
- Change `SplitLayoutView.body` switch from `.terminal(let id)` → `.pane(let content)` rendering `PanePlaceholder`
- Remove `TerminalPanelPlaceholder` entirely (it's replaced by `PanePlaceholder`)
- Update `updateRatios` switch to use `.pane` instead of `.terminal`

The full `SplitLayoutView` body becomes:
```swift
var body: some View {
    switch node {
    case .pane(let content):
        PanePlaceholder(
            content: content,
            worktree: worktree,
            layout: $layout
        )
    case .split(let direction, let children, let ratios):
        SplitContainer(
            direction: direction,
            children: children,
            ratios: ratios,
            worktree: worktree,
            layout: $layout
        )
    }
}
```

In `SplitContainer.updateRatios`, change `case .terminal:` to `case .pane:`.

- [ ] **Step 3: Build to verify compilation**

Run: `swift build`
Expected: May have compile errors for `WebviewPaneView` and `CodeViewerPaneView` — add stub implementations:

Create temporary stubs if needed:
```swift
// In WebviewPaneView.swift
import SwiftUI
struct WebviewPaneView: View {
    let url: URL
    var body: some View { Text("Webview: \(url.absoluteString)") }
}

// In CodeViewerPaneView.swift
import SwiftUI
struct CodeViewerPaneView: View {
    let path: String
    let worktreePath: String
    var body: some View { Text("Code: \(path)") }
}
```

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDApp/Panes/ Sources/TBDApp/Terminal/SplitLayoutView.swift
git commit -m "feat: add PanePlaceholder, wire SplitLayoutView to .pane(PaneContent)"
```

---

## Task 5: Generic TabBar and tab system in AppState

**Files:**
- Create: `Sources/TBDApp/TabBar.swift`
- Modify: `Sources/TBDApp/AppState.swift:16` (add tabs property)
- Modify: `Sources/TBDApp/AppState+Terminals.swift` (update createTerminal to also append tab)
- Modify: `Sources/TBDApp/Terminal/TerminalContainerView.swift` (read from tabs, use TabBar)

- [ ] **Step 1: Create generic TabBar**

Create `Sources/TBDApp/TabBar.swift`:
```swift
import SwiftUI

// MARK: - TabBar

struct TabBar: View {
    let tabs: [Tab]
    @Binding var activeTabIndex: Int
    var onAddTab: () -> Void
    var onCloseTab: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                if index > 0 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 1, height: 18)
                }

                TabItem(
                    tab: tab,
                    index: index,
                    isSelected: index == activeTabIndex,
                    onSelect: { activeTabIndex = index },
                    onClose: { onCloseTab(index) }
                )
            }

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1, height: 18)

            Button(action: onAddTab) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Terminal Tab")

            Spacer()
        }
        .padding(.horizontal, 0)
        .frame(height: 30)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - TabItem

private struct TabItem: View {
    let tab: Tab
    let index: Int
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false
    @State private var isHoveringClose = false

    private var showClose: Bool {
        isSelected || isHovering
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isHoveringClose ? .primary : .secondary)
                    .frame(width: 16, height: 16)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(isHoveringClose ? 0.12 : 0))
                    )
                    .onHover { hovering in
                        isHoveringClose = hovering
                    }
            }
            .buttonStyle(.plain)
            .opacity(showClose ? 1 : 0)
            .animation(.easeInOut(duration: 0.12), value: showClose)

            tabIcon
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.trailing, 3)

            Text(tabLabel)
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(maxWidth: .infinity)

            Color.clear
                .frame(width: 16, height: 16)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .frame(minWidth: 80, maxWidth: 180, minHeight: 28)
        .background(
            isSelected
                ? Color(nsColor: .controlBackgroundColor)
                : (isHovering ? Color.primary.opacity(0.04) : Color.clear)
        )
        .animation(.easeInOut(duration: 0.1), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            onSelect()
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var tabIcon: some View {
        switch tab.content {
        case .terminal:
            Image(systemName: "terminal")
        case .webview:
            Image(systemName: "globe")
        case .codeViewer:
            Image(systemName: "doc.text")
        }
    }

    private var tabLabel: String {
        if let label = tab.label, !label.isEmpty {
            return label
        }
        switch tab.content {
        case .terminal:
            return "Terminal \(index + 1)"
        case .webview(_, let url):
            return url.host ?? "Web"
        case .codeViewer(_, let path):
            return URL(fileURLWithPath: path).lastPathComponent
        }
    }
}
```

- [ ] **Step 2: Add `tabs` property to AppState**

In `Sources/TBDApp/AppState.swift`, add after line 16 (`@Published var layouts`):
```swift
@Published var tabs: [UUID: [Tab]] = [:]
```

- [ ] **Step 3: Update createTerminal to also append a Tab**

In `Sources/TBDApp/AppState+Terminals.swift`, update `createTerminal`:
```swift
func createTerminal(worktreeID: UUID, cmd: String? = nil) async {
    do {
        let terminal = try await daemonClient.createTerminal(worktreeID: worktreeID, cmd: cmd)
        terminals[worktreeID, default: []].append(terminal)
        // Also create a tab for this terminal
        let tab = Tab(id: terminal.id, content: .terminal(terminalID: terminal.id))
        tabs[worktreeID, default: []].append(tab)
    } catch {
        logger.error("Failed to create terminal: \(error)")
        handleConnectionError(error)
    }
}
```

- [ ] **Step 4: Update refreshTerminals to reconcile tabs**

In `Sources/TBDApp/AppState.swift`, update `refreshTerminals(worktreeID:)` to reconcile tabs after updating terminals:
```swift
func refreshTerminals(worktreeID: UUID) async {
    do {
        let fetched = try await daemonClient.listTerminals(worktreeID: worktreeID)
        let existing = terminals[worktreeID] ?? []
        if fetched != existing {
            terminals[worktreeID] = fetched
            reconcileTabs(worktreeID: worktreeID, terminals: fetched)
        }
    } catch {
        logger.error("Failed to list terminals for worktree \(worktreeID): \(error)")
        handleConnectionError(error)
    }
}

/// Ensure tabs stay in sync with daemon-managed terminals.
/// Adds tabs for new terminals, removes tabs for deleted terminals.
/// Preserves non-terminal tabs (webview, code viewer).
private func reconcileTabs(worktreeID: UUID, terminals: [Terminal]) {
    var currentTabs = tabs[worktreeID] ?? []
    let terminalIDs = Set(terminals.map(\.id))
    let existingTerminalTabIDs = Set(currentTabs.compactMap { tab -> UUID? in
        if case .terminal(let id) = tab.content { return id }
        return nil
    })

    // Remove tabs for terminals that no longer exist
    currentTabs.removeAll { tab in
        if case .terminal(let id) = tab.content {
            return !terminalIDs.contains(id)
        }
        return false
    }

    // Add tabs for new terminals
    for terminal in terminals where !existingTerminalTabIDs.contains(terminal.id) {
        currentTabs.append(Tab(id: terminal.id, content: .terminal(terminalID: terminal.id)))
    }

    tabs[worktreeID] = currentTabs
}
```

- [ ] **Step 5: Rewrite TerminalContainerView to use tabs**

Rewrite `Sources/TBDApp/Terminal/TerminalContainerView.swift` `SingleWorktreeView` to read from `appState.tabs[worktreeID]` instead of `appState.terminals[worktreeID]`:

Key changes in `SingleWorktreeView`:
- Replace `private var terminals: [Terminal]` with `private var tabs: [Tab]`
- Replace `TerminalTabBar` with `TabBar`
- `layoutContent` reads layout keyed by `tab.id`
- Default layout is `.pane(tab.content)`
- `closeTab` removes from `appState.tabs` (and for terminal tabs, also removes from `appState.terminals`)
- `activeTerminal` logic replaced with `activeTab`
- The "+" button still calls `createTerminal()` which now handles both

Similarly update `MultiWorktreeCell` to use `.pane()` for default layout.

- [ ] **Step 6: Delete old TerminalTabBar.swift**

Delete `Sources/TBDApp/Terminal/TerminalTabBar.swift` — replaced by `Sources/TBDApp/TabBar.swift`.

- [ ] **Step 7: Build to verify**

Run: `swift build`
Expected: builds successfully

- [ ] **Step 8: Commit**

```bash
git add Sources/TBDApp/TabBar.swift Sources/TBDApp/AppState.swift Sources/TBDApp/AppState+Terminals.swift Sources/TBDApp/Terminal/TerminalContainerView.swift
git rm Sources/TBDApp/Terminal/TerminalTabBar.swift
git commit -m "feat: generic tab system with Tab model as single source of truth"
```

---

## Task 6: WebviewPaneView — WKWebView wrapper

**Files:**
- Create: `Sources/TBDApp/Panes/WebviewPaneView.swift` (replace stub)

- [ ] **Step 1: Implement WebviewPaneView**

Replace the stub `Sources/TBDApp/Panes/WebviewPaneView.swift` with:
```swift
import SwiftUI
import WebKit

/// Wraps WKWebView for displaying web content in a pane.
/// All instances share WKWebsiteDataStore.default() for persistent cookies.
struct WebviewPaneView: NSViewRepresentable {
    let url: URL
    @State private var currentURL: URL?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Only reload if the initial URL changed (not navigation)
        if webView.url == nil {
            webView.load(URLRequest(url: url))
        }
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // URL tracking handled by the webview itself via webView.url
        }
    }
}

/// Toolbar content for a webview pane — back/forward buttons + URL display.
struct WebviewToolbarContent: View {
    let webView: WKWebView?

    var body: some View {
        HStack(spacing: 4) {
            Button { webView?.goBack() } label: {
                Image(systemName: "chevron.left")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(!(webView?.canGoBack ?? false))

            Button { webView?.goForward() } label: {
                Image(systemName: "chevron.right")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(!(webView?.canGoForward ?? false))
        }
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `swift build`
Expected: builds successfully

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDApp/Panes/WebviewPaneView.swift
git commit -m "feat: WebviewPaneView with shared cookie store"
```

---

## Task 7: CodeViewerPaneView — syntax-highlighted code viewer

**Files:**
- Create: `Sources/TBDApp/Panes/CodeViewerPaneView.swift` (replace stub)

- [ ] **Step 1: Implement CodeViewerPaneView**

Replace the stub `Sources/TBDApp/Panes/CodeViewerPaneView.swift` with a complete implementation:

```swift
import SwiftUI
import AppKit
import Highlightr

// MARK: - CodeViewerPaneView

struct CodeViewerPaneView: View {
    let path: String
    let worktreePath: String

    @State private var selectedFiles: [String] = []
    @State private var fileTree: [FileTreeNode] = []

    var body: some View {
        HStack(spacing: 0) {
            // File sidebar
            CodeViewerSidebar(
                worktreePath: worktreePath,
                selectedFiles: $selectedFiles
            )
            .frame(width: 200)

            Divider()

            // Code preview
            if selectedFiles.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(selectedFiles, id: \.self) { filePath in
                            if selectedFiles.count > 1 {
                                fileHeader(filePath)
                            }
                            HighlightedCodeView(filePath: filePath)
                        }
                    }
                }
            }
        }
        .onAppear {
            if !path.isEmpty && FileManager.default.fileExists(atPath: path) {
                selectedFiles = [path]
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Select a file to view")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fileHeader(_ path: String) -> some View {
        HStack {
            Image(systemName: "doc.text")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(URL(fileURLWithPath: path).lastPathComponent)
                .font(.caption)
                .fontWeight(.medium)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - HighlightedCodeView

private struct HighlightedCodeView: View {
    let filePath: String
    @State private var attributedContent: NSAttributedString?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let error = loadError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else if let content = attributedContent {
                Text(AttributedString(content))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 100)
            }
        }
        .task(id: filePath) {
            await loadAndHighlight()
        }
    }

    private func loadAndHighlight() async {
        do {
            let content = try String(contentsOfFile: filePath, encoding: .utf8)
            let highlighted = highlightCode(content, filename: filePath)
            attributedContent = highlighted
        } catch {
            loadError = "Could not read file"
        }
    }
}

// MARK: - Syntax Highlighting

private let sharedHighlightr: Highlightr? = {
    let h = Highlightr()
    h?.setTheme(to: "atom-one-dark")
    return h
}()

private func highlightCode(_ code: String, filename: String) -> NSAttributedString {
    let lang = languageForFilename(filename)
    let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    guard let highlightr = sharedHighlightr,
          let highlighted = highlightr.highlight(code, as: lang) else {
        return NSAttributedString(string: code, attributes: [.font: monoFont])
    }

    let mutable = NSMutableAttributedString(attributedString: highlighted)
    let fullRange = NSRange(location: 0, length: mutable.length)

    // Override font to consistent monospace
    mutable.addAttribute(.font, value: monoFont, range: fullRange)

    // Legibility fix: replace too-pale foreground colors
    mutable.enumerateAttribute(.foregroundColor, in: fullRange) { value, attrRange, _ in
        if let color = value as? NSColor, colorIsTooPale(color) {
            mutable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: attrRange)
        }
    }

    return mutable
}

private func colorIsTooPale(_ color: NSColor) -> Bool {
    guard let rgb = color.usingColorSpace(.sRGB) else { return false }
    let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    return luminance > 0.6
}

private func languageForFilename(_ filename: String) -> String? {
    let ext = (filename as NSString).pathExtension.lowercased()
    let map: [String: String] = [
        "swift": "swift", "ts": "typescript", "tsx": "typescript", "js": "javascript",
        "jsx": "javascript", "py": "python", "rb": "ruby", "go": "go", "rs": "rust",
        "java": "java", "kt": "kotlin", "cpp": "cpp", "c": "c", "h": "c", "hpp": "cpp",
        "cs": "csharp", "css": "css", "scss": "scss", "html": "xml", "xml": "xml",
        "json": "json", "yaml": "yaml", "yml": "yaml", "toml": "ini", "sql": "sql",
        "sh": "bash", "bash": "bash", "zsh": "bash", "md": "markdown",
        "graphql": "graphql", "gql": "graphql",
    ]
    return map[ext]
}

// MARK: - CodeViewerSidebar

struct CodeViewerSidebar: View {
    let worktreePath: String
    @Binding var selectedFiles: [String]
    @State private var expandedDirs: Set<String> = []
    @State private var entries: [FileEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Files")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries, id: \.path) { entry in
                        FileEntryRow(
                            entry: entry,
                            isExpanded: expandedDirs.contains(entry.path),
                            isSelected: selectedFiles.contains(entry.path),
                            onToggleDir: { toggleDir(entry.path) },
                            onSelectFile: { selectFile(entry.path, event: NSApp.currentEvent) }
                        )
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .task(id: worktreePath) {
            loadTopLevel()
        }
    }

    private func loadTopLevel() {
        guard !worktreePath.isEmpty else { return }
        entries = listDirectory(worktreePath, depth: 0)
    }

    private func toggleDir(_ path: String) {
        if expandedDirs.contains(path) {
            expandedDirs.remove(path)
            entries.removeAll { $0.path.hasPrefix(path + "/") }
        } else {
            expandedDirs.insert(path)
            let children = listDirectory(path, depth: depthOf(path) + 1)
            if let idx = entries.firstIndex(where: { $0.path == path }) {
                entries.insert(contentsOf: children, at: idx + 1)
            }
        }
    }

    private func selectFile(_ path: String, event: NSEvent?) {
        if event?.modifierFlags.contains(.command) == true {
            if selectedFiles.contains(path) {
                selectedFiles.removeAll { $0 == path }
            } else {
                selectedFiles.append(path)
            }
        } else {
            selectedFiles = [path]
        }
    }

    private func depthOf(_ path: String) -> Int {
        let relative = path.replacingOccurrences(of: worktreePath + "/", with: "")
        return relative.components(separatedBy: "/").count - 1
    }

    private func listDirectory(_ dir: String, depth: Int) -> [FileEntry] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        return items
            .filter { !$0.hasPrefix(".") }
            .sorted { a, b in
                let aIsDir = isDirectory(dir + "/" + a)
                let bIsDir = isDirectory(dir + "/" + b)
                if aIsDir != bIsDir { return aIsDir }
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
            .map { name in
                let fullPath = dir + "/" + name
                return FileEntry(path: fullPath, name: name, isDirectory: isDirectory(fullPath), depth: depth)
            }
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return isDir.boolValue
    }
}

struct FileEntry {
    let path: String
    let name: String
    let isDirectory: Bool
    let depth: Int
}

private struct FileEntryRow: View {
    let entry: FileEntry
    let isExpanded: Bool
    let isSelected: Bool
    let onToggleDir: () -> Void
    let onSelectFile: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            if entry.isDirectory {
                onToggleDir()
            } else {
                onSelectFile()
            }
        } label: {
            HStack(spacing: 4) {
                if entry.isDirectory {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                } else {
                    Color.clear.frame(width: 10)
                }

                Image(systemName: entry.isDirectory ? "folder" : "doc")
                    .font(.caption2)
                    .foregroundStyle(entry.isDirectory ? .blue : .secondary)

                Text(entry.name)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()
            }
            .padding(.leading, CGFloat(entry.depth) * 16 + 8)
            .padding(.vertical, 3)
            .background(
                isSelected ? Color.accentColor.opacity(0.2) :
                (isHovered ? Color.primary.opacity(0.05) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `swift build`
Expected: builds successfully

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDApp/Panes/CodeViewerPaneView.swift
git commit -m "feat: CodeViewerPaneView with Highlightr syntax highlighting and file sidebar"
```

---

## Task 8: PR link in toolbar → webview tab

**Files:**
- Modify: `Sources/TBDApp/ContentView.swift:43-67` (toolbar section)

- [ ] **Step 1: Add PR link to toolbar**

In `Sources/TBDApp/ContentView.swift`, in the `ToolbarItemGroup`, add a PR link button. After the filter picker and before the file panel toggle, add:

```swift
if let worktreeID = appState.selectedWorktreeIDs.first,
   appState.selectedWorktreeIDs.count == 1,
   let prStatus = appState.prStatuses[worktreeID],
   let prURL = URL(string: prStatus.url) {
    Button {
        let tab = Tab(id: UUID(), content: .webview(id: UUID(), url: prURL), label: "PR #\(prStatus.number)")
        appState.tabs[worktreeID, default: []].append(tab)
    } label: {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.pull")
                .font(.caption)
            Text("#\(prStatus.number)")
                .font(.caption)
                .fontWeight(.medium)
        }
    }
    .help("Open PR in browser pane")
}
```

- [ ] **Step 2: Build to verify**

Run: `swift build`
Expected: builds successfully

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDApp/ContentView.swift
git commit -m "feat: PR link in toolbar opens webview tab"
```

---

## Task 9: FileViewerPanel click → code viewer tab

**Files:**
- Modify: `Sources/TBDApp/FileViewer/FileViewerPanel.swift:191-222` (GitFileRow)

- [ ] **Step 1: Update GitFileRow to open code viewer tab**

In `Sources/TBDApp/FileViewer/FileViewerPanel.swift`, update `GitFileRow` to open a code viewer tab instead of calling `NSWorkspace.shared.open`. The row needs access to `appState` and `worktreeID`:

Add `@EnvironmentObject var appState: AppState` and a `worktreeID: UUID` parameter to `FileStatusSection` and `GitFileRow`.

Update the button action in `GitFileRow`:
```swift
Button {
    let fullPath = URL(fileURLWithPath: worktreePath).appendingPathComponent(file.path).path
    openInCodeViewer(fullPath)
} label: { /* existing label */ }
```

Add helper:
```swift
private func openInCodeViewer(_ path: String) {
    // Find or create a code viewer tab for this worktree
    let worktreeID = worktree.id  // passed through from FileViewerPanel
    var worktreeTabs = appState.tabs[worktreeID] ?? []

    // Look for existing code viewer tab to reuse
    if let existingIndex = worktreeTabs.firstIndex(where: {
        if case .codeViewer = $0.content { return true }
        return false
    }) {
        // Check if Cmd is held for multi-select
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            // Don't replace — add a new tab
        } else {
            // Replace existing code viewer tab's content
            worktreeTabs[existingIndex] = Tab(
                id: worktreeTabs[existingIndex].id,
                content: .codeViewer(id: worktreeTabs[existingIndex].content.paneID, path: path),
                label: URL(fileURLWithPath: path).lastPathComponent
            )
            appState.tabs[worktreeID] = worktreeTabs
            return
        }
    }

    // Create new code viewer tab
    let tab = Tab(
        id: UUID(),
        content: .codeViewer(id: UUID(), path: path),
        label: URL(fileURLWithPath: path).lastPathComponent
    )
    appState.tabs[worktreeID, default: []].append(tab)
}
```

- [ ] **Step 2: Build to verify**

Run: `swift build`
Expected: builds successfully

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDApp/FileViewer/FileViewerPanel.swift
git commit -m "feat: FileViewerPanel click opens code viewer tab"
```

---

## Task 10: Cmd+Click file path in terminal → code viewer split

**Files:**
- Modify: `Sources/TBDApp/Terminal/TBDTerminalView.swift`
- Modify: `Sources/TBDApp/Terminal/TerminalPanelView.swift` (pass callback)

- [ ] **Step 1: Add Cmd+Click handler to TBDTerminalView**

In `Sources/TBDApp/Terminal/TBDTerminalView.swift`, add a callback and mouse handler:

```swift
/// Called when user Cmd+Clicks a file path in the terminal.
/// The callback receives the resolved absolute file path.
var onFilePathClicked: ((String) -> Void)?

/// The worktree path for resolving relative file paths.
var worktreePath: String = ""

override func mouseDown(with event: NSEvent) {
    // Cmd+Click: try to extract a file path
    if event.modifierFlags.contains(.command) {
        if let filePath = extractFilePath(at: event) {
            onFilePathClicked?(filePath)
            return
        }
    }
    super.mouseDown(with: event)
}

private func extractFilePath(at event: NSEvent) -> String? {
    let localPoint = convert(event.locationInWindow, from: nil)
    let terminal = getTerminal()
    let cellWidth = frame.width / CGFloat(terminal.cols)
    let cellHeight = frame.height / CGFloat(terminal.rows)

    let col = Int(localPoint.x / cellWidth)
    // Terminal Y is flipped — 0 is top
    let row = Int((frame.height - localPoint.y) / cellHeight)

    guard row >= 0, row < terminal.rows else { return nil }

    // Get the line text
    let line = terminal.getLine(row: row)
    let lineText = line?.translateToString() ?? ""
    guard !lineText.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

    // Extract word around the click position
    let chars = Array(lineText)
    guard col >= 0, col < chars.count else { return nil }

    // Expand outward from click position to find path-like text
    var start = col
    var end = col
    let pathChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-~"))
    while start > 0 && chars[start - 1].unicodeScalars.allSatisfy({ pathChars.contains($0) }) {
        start -= 1
    }
    while end < chars.count - 1 && chars[end + 1].unicodeScalars.allSatisfy({ pathChars.contains($0) }) {
        end += 1
    }

    var candidate = String(chars[start...end])

    // Strip trailing :line:col suffix (e.g., "file.swift:42:10")
    if let colonRange = candidate.range(of: #":\d+.*$"#, options: .regularExpression) {
        candidate = String(candidate[candidate.startIndex..<colonRange.lowerBound])
    }

    guard !candidate.isEmpty else { return nil }

    // Resolve relative paths against worktree
    let resolved: String
    if candidate.hasPrefix("/") || candidate.hasPrefix("~") {
        resolved = NSString(string: candidate).expandingTildeInPath
    } else {
        resolved = URL(fileURLWithPath: worktreePath).appendingPathComponent(candidate).path
    }

    // Validate it exists
    if FileManager.default.fileExists(atPath: resolved) {
        return resolved
    }

    return nil
}
```

- [ ] **Step 2: Wire callback in TerminalPanelView / PanePlaceholder**

In `PanePlaceholder.swift`, when rendering terminal content, set the callback on the `TBDTerminalView` via the coordinator. This requires passing a closure through `TerminalPanelView` that mutates the layout binding to add a code viewer split.

In the `TerminalPanelView` coordinator's `makeNSView`, after creating the `TBDTerminalView`:
```swift
tv.worktreePath = worktreePath  // new parameter
tv.onFilePathClicked = { [weak tv] path in
    onFilePathClicked?(path)
}
```

Add `worktreePath: String` and `onFilePathClicked: ((String) -> Void)?` parameters to `TerminalPanelView`.

In `PanePlaceholder`, when rendering terminal content:
```swift
TerminalPanelView(
    terminalID: terminalID,
    tmuxServer: worktree.tmuxServer,
    tmuxWindowID: terminal.tmuxWindowID,
    tmuxBridge: appState.tmuxBridge,
    worktreePath: worktree.path,
    onFilePathClicked: { path in
        let newContent = PaneContent.codeViewer(id: UUID(), path: path)
        layout = layout.splitPane(paneID: terminalID, direction: .horizontal, newContent: newContent)
    }
)
```

- [ ] **Step 3: Build to verify**

Run: `swift build`
Expected: builds successfully

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDApp/Terminal/TBDTerminalView.swift Sources/TBDApp/Panes/PanePlaceholder.swift Sources/TBDApp/Terminal/TerminalPanelView.swift
git commit -m "feat: Cmd+Click file path in terminal opens code viewer split"
```

---

## Task 11: Final integration test and cleanup

- [ ] **Step 1: Run full test suite**

Run: `swift test`
Expected: all tests pass

- [ ] **Step 2: Run full build**

Run: `swift build`
Expected: builds with no warnings related to our changes

- [ ] **Step 3: Manual smoke test checklist**

Test with `scripts/restart.sh`:
1. Terminal tabs work as before (create, close, split)
2. PR link appears in toolbar when worktree has a PR → clicking opens webview tab
3. Webview loads GitHub and retains login across tabs
4. Clicking a file in FileViewerPanel opens code viewer tab with syntax highlighting
5. Clicking another file replaces content in same code viewer tab
6. Cmd+Click on a file path in terminal opens code viewer split to the right
7. Split/resize between terminal and code viewer works

- [ ] **Step 4: Commit any final fixes**

```bash
git add -A
git commit -m "fix: final integration fixes for multi-format panes"
```
