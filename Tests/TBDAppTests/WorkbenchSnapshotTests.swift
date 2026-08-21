import AppKit
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

/// Renders the Session Workbench transcript UI to PNG at various viewport
/// sizes and appearance settings for visual review.
///
/// Uses in-process bitmap rendering (`bitmapImageRepForCachingDisplay`) to
/// avoid screen-capture permission issues.
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
    /// Appearance must be set BEFORE building views so NSAttributedString colors
    /// resolve in the correct context (text color does not update dynamically after creation).
    private func renderWorkbench(
        presentation: TranscriptPresentation,
        appState: AppState,
        size: NSSize,
        appearance: NSAppearance?,
        to path: String
    ) throws {
        let frame = NSRect(origin: .zero, size: size)

        // Set appearance context before building ANY views so text colors resolve correctly
        let renderWithAppearance = {
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

            // Set up the workbench view via NSHostingView
            let workbenchView = SessionWorkbenchView(
                sections: presentation.indexSections,
                onOpen: { _ in }
            ) {
                scrollView.asSwiftUIView()
            }

            let host = NSHostingView(rootView: AnyView(
                workbenchView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .environmentObject(appState)
            ))
            host.translatesAutoresizingMaskIntoConstraints = false
            if let appearance = appearance {
                host.appearance = appearance
            }

            let container = NSView(frame: frame)
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            if let appearance = appearance {
                container.appearance = appearance
            }
            container.addSubview(host)

            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                host.topAnchor.constraint(equalTo: container.topAnchor),
                host.widthAnchor.constraint(equalToConstant: size.width),
                host.heightAnchor.constraint(equalToConstant: size.height)
            ])

            // Layout and pump the run loop
            container.layoutSubtreeIfNeeded()
            host.layoutSubtreeIfNeeded()
            self.pump()
            tableCoordinator.precomputeBottomWindow()
            tableView.layoutSubtreeIfNeeded()
            self.pump()

            // Capture the bitmap DIRECTLY — deliberately no `NSImage.lockFocus()`
            // round-trip. `lockFocus` pushes a drawing context that does not
            // inherit `NSAppearance.current`, so a
            // `NSColor.controlBackgroundColor.setFill()` backdrop resolves LIGHT
            // even under darkAqua. That was harmless while assistant bubbles
            // painted their own background, but this design makes them `.clear`
            // — so the light backdrop showed through the prose region and the
            // correctly-resolved dark-mode (white) prose became invisible
            // against it, while opaque activity rows and the rail looked fine.
            // Writing the cached rep straight out keeps ONE appearance for the
            // whole capture; `container`'s layer supplies the opaque ground,
            // resolved inside this closure.
            guard let rep = container.bitmapImageRepForCachingDisplay(in: frame) else {
                throw RenderError.couldNotMakePNG
            }
            container.cacheDisplay(in: frame, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                throw RenderError.couldNotMakePNG
            }
            try png.write(to: URL(fileURLWithPath: path))
        }

        // Execute render inside appearance context so text colors resolve correctly
        if let appearance = appearance {
            var error: Error?
            appearance.performAsCurrentDrawingAppearance {
                do {
                    try renderWithAppearance()
                } catch let e {
                    error = e
                }
            }
            if let error = error {
                throw error
            }
        } else {
            try renderWithAppearance()
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

    /// Pump the run loop to allow deferred work to complete.
    private func pump() {
        for _ in 0..<5 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    enum RenderError: Error, CustomStringConvertible {
        case couldNotMakePNG
        case implausiblySmallPNG(name: String, bytes: Int)

        var description: String {
            switch self {
            case .couldNotMakePNG:
                return "could not build a PNG representation of the rendered view"
            case let .implausiblySmallPNG(name, bytes):
                return "\(name).png is only \(bytes) bytes — the view almost certainly "
                    + "rendered blank rather than being captured correctly"
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
