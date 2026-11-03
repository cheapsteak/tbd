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

/// `FilePreviewView` mounted offscreen: a playable audio file gets one paused
/// player framed to its control bar, a source file whose extension looks up
/// as a playable type gets none, and an audio file that does not load falls
/// back to the "Cannot preview" screen.
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

    /// `ts` looks up as an MPEG transport stream, a playable movie type, so
    /// only the text-first order keeps this file off the player.
    @Test func aTypeScriptFileMountsNoPlayer() async throws {
        let fixtures = try PreviewFixtures()
        defer { fixtures.remove() }
        let url = try fixtures.text("export const x = 1\n", named: "index.ts")
        let kind = FilePreviewClassifier.shared.kind(forPath: url.path, rendersMarkdown: false)
        #expect(kind == .text)
        let host = OffscreenHost(
            root: PreviewRoot(
                path: url.path, worktreePath: fixtures.directory.path,
                coordinator: MediaPlaybackCoordinator()),
            size: Self.paneSize)
        defer { host.tearDown() }

        // Highlighted text is a SwiftUI `Text`, which puts no AppKit view in
        // the tree to wait on. So this spends the whole window that
        // `aWavFileMountsOnePausedPlayer`, the positive control, mounts its
        // player within: a player this file was given would be up by now.
        await host.pump(times: OffscreenHostDefaults.maxPumps)

        let avPlayers = host.descendants(AVPlayerView.self).count
        let mediaHosts = host.descendants(MediaPlayerHostView.self).count
        #expect(avPlayers == 0, "a TypeScript file mounted \(avPlayers) AVPlayerView(s)")
        #expect(mediaHosts == 0)
    }

    @Test func anUnplayableWavFallsBack() async throws {
        let fixtures = try PreviewFixtures()
        defer { fixtures.remove() }
        let url = try fixtures.garbageWAV()
        let kind = FilePreviewClassifier.shared.kind(forPath: url.path, rendersMarkdown: false)
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
