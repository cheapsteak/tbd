import AppKit

/// The Go menu's Previous Prompt and Next Prompt commands.
///
/// SwiftUI menu commands cannot observe the first responder, so the items stay
/// enabled and `perform` does nothing when no transcript pane is focused. The
/// pane is found from the first responder: a view inside the transcript (the
/// table) reaches its `TranscriptContainerView` by walking up, and a composer
/// reaches its table through the composer and transcript focus registries.
enum PromptRailCommand {
    /// The coordinator of the transcript pane `responder` belongs to, or nil.
    @MainActor
    static func coordinator(
        forResponder responder: NSResponder?,
        composerViews: [ComposerKey: NSView],
        transcriptViews: [ComposerKey: NSView]
    ) -> TableTranscriptView.Coordinator? {
        guard let view = responder as? NSView else { return nil }
        if let container = container(above: view) { return container.coordinator }
        for (key, composer) in composerViews where view === composer || view.isDescendant(of: composer) {
            if let table = transcriptViews[key], let container = container(above: table) {
                return container.coordinator
            }
        }
        return nil
    }

    @MainActor
    static func perform(_ step: TableTranscriptView.Coordinator.PromptStep, appState: AppState) {
        let composers = appState.composerFocusTargets.compactMapValues { $0.view }
        let transcripts = appState.transcriptFocusTargets.compactMapValues { $0.view }
        guard let coordinator = coordinator(
            forResponder: NSApp.keyWindow?.firstResponder,
            composerViews: composers,
            transcriptViews: transcripts
        ) else { return }
        coordinator.jumpToPrompt(step)
    }

    @MainActor
    private static func container(above view: NSView) -> TranscriptContainerView? {
        var current: NSView? = view
        while let candidate = current {
            if let container = candidate as? TranscriptContainerView { return container }
            current = candidate.superview
        }
        return nil
    }
}
