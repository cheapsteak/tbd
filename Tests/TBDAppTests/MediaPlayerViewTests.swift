import AppKit
import AVFoundation
import AVKit
import CoreMedia
import Foundation
import Testing
import TestSupport
@testable import TBDApp

/// A temporary directory of media fixtures, removed by `remove()`.
@MainActor
private final class MediaFixtures {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaPlayerViewTests-\(UUID().uuidString)", isDirectory: true)
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

    /// A file named like audio that holds no audio.
    func garbageWAV() throws -> URL {
        let url = directory.appendingPathComponent("bad.wav")
        try Data("not audio".utf8).write(to: url)
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// A borderless window far off every display, never ordered front, whose
/// content view holds a plain `container` that holds the hosts.
@MainActor
private final class PlayerScene {
    let coordinator = MediaPlaybackCoordinator()
    let window: NSWindow
    let container: NSView
    private var hosts: [MediaPlayerHostView] = []

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView = content
        let container = NSView(frame: content.bounds)
        content.addSubview(container)
        self.window = window
        self.container = container
    }

    func addHost() -> MediaPlayerHostView {
        let host = MediaPlayerHostView(coordinator: coordinator)
        host.frame = container.bounds
        container.addSubview(host)
        hosts.append(host)
        return host
    }

    func tearDown() {
        for host in hosts {
            host.tearDown()
        }
        window.contentView = nil
        window.close()
    }
}

/// The class a failure callback flips, so the test can read it afterwards.
@MainActor
private final class FailureFlag {
    var fired = false
}

/// `MediaPlayerHostView` with a real, muted `AVPlayer`: it never starts by
/// itself, pauses when removed or hidden, reloads paused at the start, and
/// lets only one player run at a time.
@MainActor
@Suite("MediaPlayerView", .fastPassBounded)
struct MediaPlayerViewTests {
    @Test func loadLeavesItPaused() throws {
        let fixtures = try MediaFixtures()
        defer { fixtures.remove() }
        let scene = PlayerScene()
        defer { scene.tearDown() }
        let host = scene.addHost()
        let url = try fixtures.silentWAV()

        host.load(url: url, revision: 0)
        host.player?.isMuted = true

        #expect(host.player?.rate == 0)
        #expect(host.player?.currentItem != nil)
    }

    @Test func removingFromTheWindowPauses() throws {
        let fixtures = try MediaFixtures()
        defer { fixtures.remove() }
        let scene = PlayerScene()
        defer { scene.tearDown() }
        let host = scene.addHost()
        let url = try fixtures.silentWAV()
        host.load(url: url, revision: 0)
        host.player?.isMuted = true

        host.player?.play()
        #expect(host.player?.rate == 1)
        host.removeFromSuperview()

        #expect(host.player?.rate == 0)
    }

    @Test func hidingAnAncestorPauses() throws {
        let fixtures = try MediaFixtures()
        defer { fixtures.remove() }
        let scene = PlayerScene()
        defer { scene.tearDown() }
        let host = scene.addHost()
        let url = try fixtures.silentWAV()
        host.load(url: url, revision: 0)
        host.player?.isMuted = true

        host.player?.play()
        #expect(host.player?.rate == 1)
        scene.container.isHidden = true

        #expect(host.player?.rate == 0)
    }

    @Test func newRevisionReloadsPausedAtTheStart() throws {
        let fixtures = try MediaFixtures()
        defer { fixtures.remove() }
        let scene = PlayerScene()
        defer { scene.tearDown() }
        let host = scene.addHost()
        let url = try fixtures.silentWAV()
        host.load(url: url, revision: 0)
        host.player?.isMuted = true
        let first = host.player?.currentItem

        host.player?.play()
        host.load(url: url, revision: 1)

        let second = host.player?.currentItem
        #expect(second != nil)
        #expect(second !== first)
        #expect(host.player?.rate == 0)
        let time = host.player?.currentTime()
        #expect(time == CMTime.zero)
    }

    @Test func sameRevisionKeepsTheItem() throws {
        let fixtures = try MediaFixtures()
        defer { fixtures.remove() }
        let scene = PlayerScene()
        defer { scene.tearDown() }
        let host = scene.addHost()
        let url = try fixtures.silentWAV()
        host.load(url: url, revision: 0)
        host.player?.isMuted = true
        let first = host.player?.currentItem

        host.load(url: url, revision: 0)

        let second = host.player?.currentItem
        #expect(first != nil)
        #expect(second === first)
    }

    @Test func pointingAtAnotherFileLoadsItPaused() throws {
        let fixtures = try MediaFixtures()
        defer { fixtures.remove() }
        let scene = PlayerScene()
        defer { scene.tearDown() }
        let host = scene.addHost()
        let fileA = try fixtures.silentWAV(named: "a.wav")
        let fileB = try fixtures.silentWAV(named: "b.wav")
        host.load(url: fileA, revision: 0)
        host.player?.isMuted = true
        let first = host.player?.currentItem

        host.player?.play()
        host.load(url: fileB, revision: 0)

        let item = host.player?.currentItem
        #expect(item != nil)
        #expect(item !== first)
        let loadedURL = (item?.asset as? AVURLAsset)?.url.resolvingSymlinksInPath()
        #expect(loadedURL == fileB.resolvingSymlinksInPath())
        #expect(host.player?.rate == 0)
    }

    @Test func startingOnePlayerPausesTheOther() throws {
        let fixtures = try MediaFixtures()
        defer { fixtures.remove() }
        let scene = PlayerScene()
        defer { scene.tearDown() }
        let a = scene.addHost()
        let b = scene.addHost()
        let fileA = try fixtures.silentWAV(named: "a.wav")
        let fileB = try fixtures.silentWAV(named: "b.wav")
        a.load(url: fileA, revision: 0)
        a.player?.isMuted = true
        b.load(url: fileB, revision: 0)
        b.player?.isMuted = true

        // AVPlayer reports a rate change set on the main thread synchronously,
        // so the coordinator has acted by the time `play()` returns.
        a.player?.play()
        b.player?.play()

        #expect(a.player?.rate == 0)
        #expect(b.player?.rate == 1)
    }

    @Test func tearDownStopsAndReleases() throws {
        let fixtures = try MediaFixtures()
        defer { fixtures.remove() }
        let scene = PlayerScene()
        defer { scene.tearDown() }
        let host = scene.addHost()
        let url = try fixtures.silentWAV()
        host.load(url: url, revision: 0)
        host.player?.isMuted = true
        host.player?.play()
        let player = host.player

        host.tearDown()

        #expect(player != nil)
        #expect(player?.rate == 0)
        #expect(host.player == nil)
        #expect(host.playerView.player == nil)
        #expect(scene.coordinator.registeredCount == 0)
    }

    @Test func unplayableFileReportsFailure() async throws {
        let fixtures = try MediaFixtures()
        defer { fixtures.remove() }
        let scene = PlayerScene()
        defer { scene.tearDown() }
        let host = scene.addHost()
        let flag = FailureFlag()
        host.onLoadFailure = { flag.fired = true }

        let bad = try fixtures.garbageWAV()
        host.load(url: bad, revision: 0)
        host.player?.isMuted = true
        let check = try #require(host.playabilityCheck)
        await check.value

        #expect(flag.fired)
    }
}
