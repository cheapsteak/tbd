import AppKit
import AVFoundation
import AVKit
import Foundation
import SwiftUI
import Testing
import TestSupport
@testable import TBDApp

/// A temporary directory of viewer fixtures, removed by `remove()`.
@MainActor
private final class PreviewFixtures {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilePreviewViewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// A one-second silent mono 44.1 kHz WAV.
    func silentWAV(named name: String = "silence.wav") throws -> URL {
        let url = directory.appendingPathComponent(name)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(44_100)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        let channels = try #require(buffer.floatChannelData)
        for channel in 0..<Int(file.processingFormat.channelCount) {
            channels[channel].update(repeating: 0, count: Int(frames))
        }
        try file.write(from: buffer)
        file.close()
        return url
    }

    /// A file named like audio that holds no audio. It carries NUL bytes, so
    /// the text sniff calls it binary and the viewer gives it a player, which
    /// then fails to load it.
    func garbageWAV() throws -> URL {
        let url = directory.appendingPathComponent("bad.wav")
        try (Data([0x00, 0xFF, 0x00, 0xFF]) + Data("not audio".utf8)).write(to: url)
        return url
    }

    func text(_ contents: String, named name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// One file in a viewer that fills the pane, with its own playback
/// coordinator so no test registers with the app-wide one.
private struct PreviewRoot: View {
    let path: String
    let worktreePath: String
    let coordinator: MediaPlaybackCoordinator

    var body: some View {
        FilePreviewView(
            filePath: path,
            worktreePath: worktreePath,
            showSourceCode: false,
            rendersMarkdown: false,
            onOpenFile: { _ in },
            fillsViewport: true
        )
        .environment(\.mediaPlaybackCoordinator, coordinator)
    }
}

/// One media file in a scroll view, as the viewer stacks files, with
/// `fillsViewport` chosen by the test. The test flips it by handing the
/// hosting view a new root of this same type, which updates the tree in place
/// the way a change in the viewer's selection count does.
private struct ViewportSwitchRoot: View {
    let path: String
    let isVideo: Bool
    let fillsViewport: Bool
    let coordinator: MediaPlaybackCoordinator

    var body: some View {
        ScrollView {
            MediaPreviewView(
                filePath: path,
                revision: 0,
                isVideo: isVideo,
                fillsViewport: fillsViewport
            )
        }
        .environment(\.mediaPlaybackCoordinator, coordinator)
    }
}

/// `FilePreviewView` mounted offscreen: a playable audio file gets one paused
/// player framed to its control bar, an audio file that does not load falls
/// back to the "Cannot preview" screen, and a player stays the same view when
/// the selection goes from one file to several. A source file whose extension
/// looks up as a playable type is covered by `FilePreviewTextTests`, which
/// reads the accessibility tree.
@MainActor
@Suite("FilePreviewView", .fastPassBounded)
struct FilePreviewViewTests {
    private static let paneSize = NSSize(width: 600, height: 400)

    @Test func aWavFileMountsOnePausedPlayer() async throws {
        let fixtures = try PreviewFixtures()
        defer { fixtures.remove() }
        let url = try fixtures.silentWAV()
        let coordinator = MediaPlaybackCoordinator()
        let host = OffscreenHost(
            root: PreviewRoot(path: url.path, worktreePath: fixtures.directory.path, coordinator: coordinator),
            size: Self.paneSize)
        defer { host.tearDown() }

        let mounted = await host.settle {
            let players = host.descendants(MediaPlayerHostView.self)
            return players.count == 1 && players[0].frame.height > 0
        }
        let players = host.descendants(MediaPlayerHostView.self)
        let heights = players.map { $0.frame.height }
        try #require(mounted, "expected one laid-out player; found \(players.count), heights \(heights)")
        let mediaHost = try #require(players.first)

        let rate = mediaHost.player?.rate
        #expect(rate == 0)
        let playerHeight = mediaHost.playerView.frame.height
        #expect(playerHeight == AudioPreviewCard.controlBarHeight)
        #expect(coordinator.registeredCount == 1)
    }

    @Test func anUnplayableWavFallsBack() async throws {
        let fixtures = try PreviewFixtures()
        defer { fixtures.remove() }
        let url = try fixtures.garbageWAV()
        let kind = await FilePreviewClassifier.shared.kind(forPath: url.path, rendersMarkdown: false)
        try #require(kind == .audio, "the fixture must reach the player, but it classified as \(kind)")
        let host = OffscreenHost(
            root: PreviewRoot(
                path: url.path, worktreePath: fixtures.directory.path,
                coordinator: MediaPlaybackCoordinator()),
            size: Self.paneSize)
        defer { host.tearDown() }

        var seen: MediaPlayerHostView?
        let mounted = await host.settle {
            seen = host.descendants(MediaPlayerHostView.self).first
            return seen != nil
        }
        try #require(mounted, "the player never mounted for an audio file")
        let mediaHost = try #require(seen)

        // The failure is reported from the playability check, which loads
        // the asset off the main thread; wait for it rather than for turns.
        if let check = mediaHost.playabilityCheck {
            await check.value
        }
        let fellBack = await host.settle {
            host.descendants(MediaPlayerHostView.self).isEmpty
        }
        let remaining = host.descendants(MediaPlayerHostView.self).count
        try #require(fellBack, "the player was still mounted after the load failed: \(remaining) player view(s)")
    }

    /// Selecting a second file while one plays flips `fillsViewport` from
    /// true to false. The player must stay the same view through the flip: a
    /// new one means SwiftUI dismantled the old, which stops and resets
    /// playback. The video layout is driven with the WAV too, since it plays
    /// in an `AVPlayerView` as readily as a movie does.
    @Test(arguments: [false, true])
    func changingFillsViewportKeepsThePlayer(isVideo: Bool) async throws {
        let fixtures = try PreviewFixtures()
        defer { fixtures.remove() }
        let url = try fixtures.silentWAV()
        let coordinator = MediaPlaybackCoordinator()
        let host = OffscreenHost(
            root: ViewportSwitchRoot(
                path: url.path, isVideo: isVideo, fillsViewport: true, coordinator: coordinator),
            size: Self.paneSize)
        defer { host.tearDown() }

        var seen: MediaPlayerHostView?
        let mounted = await host.settle {
            let players = host.descendants(MediaPlayerHostView.self)
            seen = players.first
            return players.count == 1 && players[0].frame.height > 0
        }
        try #require(mounted, "the player never mounted alone in the pane")
        let first = try #require(seen)
        let filledFrame = host.flippedWindowFrame(first)

        host.hostingView.rootView = ViewportSwitchRoot(
            path: url.path, isVideo: isVideo, fillsViewport: false, coordinator: coordinator)

        // The stack layout has landed once the one player sits somewhere
        // else: the video's height becomes 9/16 of the pane's width, and the
        // card moves from the middle of the pane to its top.
        var after: MediaPlayerHostView?
        var afterFrame = NSRect.zero
        let relaidOut = await host.settle {
            let players = host.descendants(MediaPlayerHostView.self)
            guard players.count == 1, let player = players.first else { return false }
            after = player
            afterFrame = host.flippedWindowFrame(player)
            return player.frame.height > 0 && afterFrame != filledFrame
        }
        try #require(
            relaidOut,
            "the stack layout never took effect: the player stayed at \(filledFrame), last seen at \(afterFrame)")
        let second = try #require(after)

        #expect(second === first, "the flip replaced the player view, so playback would stop and reset")
        let firstPlayer = first.player
        #expect(firstPlayer != nil, "the first player view was torn down by the flip")
        #expect(coordinator.registeredCount == 1)
    }

    @Test func durationReadsAsMinutesThenHours() {
        #expect(AudioPreviewCard.formattedDuration(seconds: 1) == "0:01")
        #expect(AudioPreviewCard.formattedDuration(seconds: 61) == "1:01")
        #expect(AudioPreviewCard.formattedDuration(seconds: 3599) == "59:59")
        #expect(AudioPreviewCard.formattedDuration(seconds: 3600) == "1:00:00")
        #expect(AudioPreviewCard.formattedDuration(seconds: 3725) == "1:02:05")
        #expect(AudioPreviewCard.formattedDuration(seconds: .nan) == "")
        #expect(AudioPreviewCard.formattedDuration(seconds: .infinity) == "")
    }
}

extension AccessibilityBridgeSerialized {
    /// A source file whose extension looks up as a playable type shows its
    /// text and no player. The evidence that the text rendered is the file's
    /// own words in the accessibility tree, which needs the process-global
    /// bridge switch, so this suite is nested here to run serialized with the
    /// others that flip it.
    @MainActor
    @Suite("FilePreviewView text", .fastPassBounded)
    struct FilePreviewTextTests {
        private static let paneSize = NSSize(width: 600, height: 400)

        /// `ts` looks up as an MPEG transport stream, a playable movie type,
        /// so only the text-first order keeps this file off the player.
        @Test func aTypeScriptFileShowsItsTextAndMountsNoPlayer() async throws {
            try await withAccessibilityBridge {
                let fixtures = try PreviewFixtures()
                defer { fixtures.remove() }
                let url = try fixtures.text("export const x = 1\n", named: "index.ts")
                let kind = await FilePreviewClassifier.shared.kind(forPath: url.path, rendersMarkdown: false)
                #expect(kind == .text)
                let host = OffscreenHost(
                    root: PreviewRoot(
                        path: url.path, worktreePath: fixtures.directory.path,
                        coordinator: MediaPlaybackCoordinator()),
                    size: Self.paneSize)
                defer { host.tearDown() }

                // Until classification lands the view is a 1 pt placeholder,
                // which holds no player either, so the assertions below would
                // pass on a blank view. Wait for the file's own text first.
                // Highlighting runs on its own queue and can take seconds on a
                // loaded runner, so the wait is bounded in time, not in pumps.
                let rendered = await pollUntilTrue(
                    timeout: TestDeadlines.saturatedPass, pollInterval: .milliseconds(20)
                ) { @Sendable in
                    await host.pump()
                    return await accessibilityTree(of: host, contains: "export const")
                }
                let tree = host.accessibilityTreeDescription()
                try #require(
                    rendered == .satisfied,
                    Comment(rawValue: "the file's text never rendered (\(rendered)); accessibility tree:\n\(tree)"))

                let avPlayers = host.descendants(AVPlayerView.self).count
                let mediaHosts = host.descendants(MediaPlayerHostView.self).count
                #expect(avPlayers == 0, "a TypeScript file mounted \(avPlayers) AVPlayerView(s)")
                #expect(mediaHosts == 0)
            }
        }
    }
}

/// Whether any accessibility label or value in `host`'s tree contains
/// `needle`. Reads both, because `accessibilityTreeDescription()` prints only
/// labels and a SwiftUI `Text` may carry its string in either. Walks the tree
/// the way `OffscreenHost` does, by selector and over declared children plus
/// subviews. Meaningful only inside `withAccessibilityBridge`.
@MainActor
private func accessibilityTree<Root: View>(of host: OffscreenHost<Root>, contains needle: String) -> Bool {
    var seen = Set<ObjectIdentifier>()

    func attribute(_ node: NSObject, _ name: String) -> Any? {
        guard node.responds(to: Selector((name))) else { return nil }
        return node.value(forKey: name)
    }

    func string(_ value: Any?) -> String? {
        (value as? String) ?? (value as? NSAttributedString)?.string
    }

    func search(_ element: Any) -> Bool {
        guard let node = element as? NSObject, seen.insert(ObjectIdentifier(node)).inserted else {
            return false
        }
        for name in ["accessibilityLabel", "accessibilityValue"] {
            if let text = string(attribute(node, name)), text.contains(needle) { return true }
        }
        let declared = attribute(node, "accessibilityChildren") as? [Any] ?? []
        for child in declared + ((node as? NSView)?.subviews ?? []) where search(child) {
            return true
        }
        return false
    }

    return search(host.contentView)
}
