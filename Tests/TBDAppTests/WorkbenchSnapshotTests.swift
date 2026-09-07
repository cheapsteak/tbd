import AppKit
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

/// Renders the Session Workbench transcript UI to PNG at various viewport
/// sizes and appearance settings for visual review.
///
/// Hosted offscreen through `OffscreenHost`, which captures in process rather
/// than through a screen recording — a screenshot API would want a permission
/// grant no CI machine has.
@Suite("Workbench snapshot rendering")
@MainActor
struct WorkbenchSnapshotTests {
    /// Absolute, so the PNGs land in the repo regardless of the test process's
    /// working directory (a relative path silently writes somewhere else).
    private static var outputDir: String {
        repoRoot.appendingPathComponent("artifacts/snapshots").path
    }

    /// A correctly-rendered 1240×760 capture is hundreds of KB. Anything this
    /// small means we captured an unlaid-out or empty view, which must fail
    /// loudly rather than pass and be mistaken for a rendering defect.
    private static let minPlausiblePNGBytes = 20_000

    /// Turns of the run loop between building the hierarchy and capturing it,
    /// and how long each one may block. Synchronous because the whole render
    /// happens inside a drawing-appearance closure, which cannot await.
    private static let settlePumps = 5
    private static let settleSpin: TimeInterval = 0.02

    /// Snapshot configurations: (name, width, height, appearance)
    private let configurations: [(String, CGFloat, CGFloat, NSAppearance?)] = [
        ("wb-wide-light", 1240, 760, NSAppearance(named: .aqua)),
        ("wb-wide-dark", 1240, 760, NSAppearance(named: .darkAqua)),
        ("wb-narrow-light", 820, 760, NSAppearance(named: .aqua)),
        ("wb-narrow-dark", 820, 760, NSAppearance(named: .darkAqua)),
        ("wb-wide-collapsed-light", 1240, 760, NSAppearance(named: .aqua)),
    ]

    @Test("render workbench at multiple viewport sizes and appearances")
    func renderWorkbenchSnapshots() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: Self.outputDir, withIntermediateDirectories: true)

        // Load the fixture JSONL
        let fixtureItems = try loadWorkbenchFixture()
        #expect(!fixtureItems.isEmpty, "fixture produced no items")

        let suiteName = "workbench-harness-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(userDefaults: defaults)

        // Build the presentation
        var expansionOverrides: [String: Bool] = [:]
        // Force the first activity group collapsed for the collapsed-light variant
        if let firstGroupID = findFirstActivityGroupID(in: fixtureItems) {
            expansionOverrides[firstGroupID] = false
        }
        let basePresentation = TranscriptPresentation.build(items: fixtureItems)
        let collapsedPresentation = TranscriptPresentation.build(
            items: fixtureItems,
            expansionOverrides: expansionOverrides
        )

        // Render each configuration
        for (index, (name, width, height, appearance)) in configurations.enumerated() {
            let presentation = (index == 4) ? collapsedPresentation : basePresentation
            let path = "\(Self.outputDir)/\(name).png"
            try renderWorkbench(
                presentation: presentation,
                appState: appState,
                size: NSSize(width: width, height: height),
                appearance: appearance,
                to: path
            )
            let fileSize = try fm.attributesOfItem(atPath: path)[.size] as? Int ?? 0
            // A blank capture is the failure mode that matters here: it looks
            // like a rendering defect in the app when it is really an
            // unlaid-out view. Throwing carries the diagnostic onto the primary
            // failure line (see Tests/CLAUDE.md, assertion hygiene rule 4).
            if fileSize < Self.minPlausiblePNGBytes {
                throw RenderError.implausiblySmallPNG(name: name, bytes: fileSize)
            }
            print("✓ \(name): \(fileSize) bytes")
        }
    }

    /// Repo root, derived from this file's own location rather than an absolute
    /// path — this repository is public and must carry no machine-specific paths.
    /// `#filePath` is `<root>/Tests/TBDAppTests/WorkbenchSnapshotTests.swift`.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TBDAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <root>
    }

    /// Load the workbench.jsonl fixture and parse it into TranscriptItem.
    private func loadWorkbenchFixture() throws -> [TranscriptItem] {
        let fixture = Self.repoRoot
            .appendingPathComponent("Tests/Fixtures/mock-state/transcripts/workbench.jsonl")
        return TranscriptCompareRealSessions.parse(filePath: fixture.path)
    }

    /// Find the first activity group ID in the presentation for forcing expansion.
    private func findFirstActivityGroupID(in items: [TranscriptItem]) -> String? {
        let presentation = TranscriptPresentation.build(items: items)
        for node in presentation.nodes {
            if case .activityGroupSummary(let summary) = node.kind {
                return summary.id
            }
        }
        return nil
    }

    /// Render the SessionWorkbenchView to a PNG file.
    ///
    /// **Everything is built inside the appearance**, not merely captured inside
    /// it: `NSAttributedString` colors resolve in the context that is current
    /// when they are created and do not update afterwards, so a dark render
    /// assembled outside `withDrawingAppearance` comes out with light text
    /// colors. The host's opaque ground is resolved in there too, which is what
    /// keeps a light backdrop from showing through a dark capture's prose region
    /// — the defect that made correctly-resolved white prose invisible while
    /// opaque activity rows and the rail looked fine.
    private func renderWorkbench(
        presentation: TranscriptPresentation,
        appState: AppState,
        size: NSSize,
        appearance: NSAppearance?,
        to path: String
    ) throws {
        try withDrawingAppearance(appearance) {
            // Build the table transcript view
            let context = TranscriptCardContext(
                terminalID: nil,
                openTranscriptOverlay: { _ in },
                appState: appState,
                linkResolver: nil,
                onLinkClicked: nil
            )
            let tableCoordinator = self.buildTableCoordinator(
                context: context,
                nodes: presentation.nodes,
                viewportWidth: size.width
            )

            let tableView = NSTableView()
            tableView.headerView = nil
            tableView.gridStyleMask = []
            tableView.backgroundColor = .clear
            tableView.usesAutomaticRowHeights = false
            tableView.selectionHighlightStyle = .none
            tableView.intercellSpacing = NSSize(width: 0, height: 4)
            tableView.rowSizeStyle = .custom
            if let appearance = appearance {
                tableView.appearance = appearance
            }
            let column = NSTableColumn(identifier: TableTranscriptView.Coordinator.columnID)
            column.resizingMask = .autoresizingMask
            tableView.addTableColumn(column)
            tableView.dataSource = tableCoordinator
            tableView.delegate = tableCoordinator

            let scrollView = NSScrollView()
            scrollView.documentView = tableView
            scrollView.hasVerticalScroller = true
            scrollView.drawsBackground = false
            if let appearance = appearance {
                scrollView.appearance = appearance
            }

            tableCoordinator.tableView = tableView
            tableCoordinator.scrollView = scrollView

            // Set up the workbench view in an offscreen host
            let workbenchView = SessionWorkbenchView(
                sections: presentation.indexSections,
                onOpen: { _ in }
            ) {
                scrollView.asSwiftUIView()
            }

            let host = OffscreenHost(
                root: AnyView(
                    workbenchView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .environment(appState)),
                size: size,
                appearance: appearance)
            let window = host.window
            // Guarantee teardown on every exit, including the `throw` below —
            // a `defer` after this point would run before the assertion that
            // follows it in this same scope could observe the result, so
            // teardown and the assertion both happen explicitly instead.
            defer {
                host.tearDown()
                // `tearDown()` must actually release the window rather than
                // merely hide it — with `isReleasedWhenClosed = false` and no
                // `close()`, every mounted window otherwise stays in
                // `NSApp.windows` for the process lifetime (see
                // `OffscreenHost.tearDown()` and the same trap at
                // `TabBarHitAreaTests.keyViewProxyMaxWidth`). This suite
                // mounts five of these per run, so a regression here would
                // leave five orphaned windows behind every `swift test`
                // invocation.
                #expect(
                    !NSApp.windows.contains(window),
                    "OffscreenHost.tearDown() left its window in NSApp.windows")
            }

            // Layout and pump the run loop
            host.contentView.layoutSubtreeIfNeeded()
            host.hostingView.layoutSubtreeIfNeeded()
            host.pumpSynchronously(times: Self.settlePumps, spin: Self.settleSpin)
            tableCoordinator.precomputeBottomWindow()
            tableView.layoutSubtreeIfNeeded()
            host.pumpSynchronously(times: Self.settlePumps, spin: Self.settleSpin)

            let shot = try host.capture()
            let variance = shot.luminanceVariance()
            if variance < OffscreenHostDefaults.minLuminanceVariance {
                throw RenderError.blankRender(path: path, variance: variance)
            }
            try shot.writePNG(to: URL(fileURLWithPath: path))
        }
    }

    /// Build a table coordinator over the presentation nodes.
    private func buildTableCoordinator(
        context: TranscriptCardContext,
        nodes: [TranscriptRenderNode],
        viewportWidth: CGFloat
    ) -> TableTranscriptView.Coordinator {
        let coordinator = TableTranscriptView.Coordinator(context: context)
        coordinator.nodes = nodes
        coordinator.previousNodes = nodes
        return coordinator
    }

    enum RenderError: Error, CustomStringConvertible {
        case implausiblySmallPNG(name: String, bytes: Int)
        case blankRender(path: String, variance: Double)

        var description: String {
            switch self {
            case let .implausiblySmallPNG(name, bytes):
                return "\(name).png is only \(bytes) bytes — the view almost certainly "
                    + "rendered blank rather than being captured correctly"
            case let .blankRender(path, variance):
                return "the capture for \(path) has luminance variance \(variance) — "
                    + "it is a flat field, i.e. the view never rendered"
            }
        }
    }
}

/// Bridge an NSScrollView to a SwiftUI view for embedding in the workbench.
private extension NSScrollView {
    func asSwiftUIView() -> some View {
        return NSScrollViewRepresentable(scrollView: self)
    }
}

private struct NSScrollViewRepresentable: NSViewRepresentable {
    let scrollView: NSScrollView

    func makeNSView(context: Context) -> NSScrollView {
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
    }
}
