import Foundation
import os

/// Shared OSSignposter for `category: "perf-transcript"`. Use `signposter.beginInterval(_:)`
/// + `signposter.endInterval(_:_:)` to scope a region; the resulting intervals show up
/// in Xcode Instruments' "os_signpost" lane and (with the SwiftUI template) alongside
/// view-body / layout events.
///
/// Region names used today (see docs/superpowers/specs/2026-05-11-transcript-render-node-design.md):
/// - "transcript.swap"             — LiveTranscriptPaneView.pollOnce mainActor block
/// - "transcript.items.body"       — TranscriptItemsView.body (whole pass, pre-refactor)
/// - "transcript.markdown.segment" — MarkdownSegments.split
/// - "transcript.scrollTo"         — proxy.scrollTo call sites
enum TranscriptSignposts {
    nonisolated static let signposter = OSSignposter(subsystem: "com.tbd.app", category: "perf-transcript")
}
