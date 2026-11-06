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

    /// For an item with no video track, AVKit adds a private view that fills
    /// the player with opaque grey once the item is ready to play, and the
    /// host hides it. The wait needs the view present as well as hidden,
    /// because "none visible" also holds before AVKit has added it.
    @Test func hidesAVKitsAudioOnlyIndicator() async throws {
        let fixtures = try MediaFixtures()
        defer { fixtures.remove() }
        let scene = PlayerScene()
        defer { scene.tearDown() }
        let host = scene.addHost()
        let url = try fixtures.silentWAV()

        host.load(url: url, revision: 0)
        host.player?.isMuted = true

        let start = ContinuousClock.now
        let outcome = await pollUntilTrue(
            timeout: TestDeadlines.saturatedPass, pollInterval: .milliseconds(20)
        ) { @Sendable in
            await MainActor.run {
                RunLoopPump.turn()
                let indicators = audioOnlyIndicators(under: host.playerView)
                return !indicators.isEmpty && indicators.allSatisfy { $0.isHidden }
            }
        }
        if outcome == .timedOut {
            let indicators = audioOnlyIndicators(under: host.playerView)
            Issue.record(AudioOnlyIndicatorTimeout(
                found: indicators.count,
                visible: indicators.filter { !$0.isHidden }.count,
                itemStatus: statusName(of: host.player?.currentItem),
                viewClasses: viewClassNames(under: host.playerView),
                elapsed: ContinuousClock.now - start))
        }
    }
}

/// Every view under `view` whose class is AVKit's audio-only indicator,
/// matched by name as `MediaPlayerHostView` matches it.
@MainActor
private func audioOnlyIndicators(under view: NSView) -> [NSView] {
    var found: [NSView] = []
    for subview in view.subviews {
        if String(describing: type(of: subview)) == MediaPlayerHostView.audioOnlyIndicatorClassName {
            found.append(subview)
        }
        found.append(contentsOf: audioOnlyIndicators(under: subview))
    }
    return found
}

/// The class names of every view under `view`, depth first, so a timeout
/// shows what AVKit built if the indicator went by another name.
@MainActor
private func viewClassNames(under view: NSView) -> [String] {
    var names: [String] = []
    for subview in view.subviews {
        names.append(String(describing: type(of: subview)))
        names.append(contentsOf: viewClassNames(under: subview))
    }
    return names
}

@MainActor
private func statusName(of item: AVPlayerItem?) -> String {
    guard let item else { return "no item" }
    switch item.status {
    case .unknown: return "unknown"
    case .readyToPlay: return "readyToPlay"
    case .failed: return "failed"
    @unknown default: return "status \(item.status.rawValue)"
    }
}

/// What the audio-only indicator wait last saw, recorded as an error so the
/// diagnostic lands on the failure's primary line.
private struct AudioOnlyIndicatorTimeout: Error, CustomStringConvertible {
    let found: Int
    let visible: Int
    let itemStatus: String
    let viewClasses: [String]
    let elapsed: Duration

    var description: String {
        "audio-only indicator: found \(found), \(visible) still visible, item \(itemStatus), "
            + "after \(elapsed); views under the player: \(viewClasses.joined(separator: ", "))"
    }
}
