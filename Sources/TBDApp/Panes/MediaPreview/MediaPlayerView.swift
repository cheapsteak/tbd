import AppKit
import AVFoundation
import AVKit
import os
import SwiftUI

private let logger = os.Logger(subsystem: "com.tbd.app", category: "media-preview")

/// The AppKit view behind `MediaPlayerView`: one `AVPlayerView` with inline
/// controls over the one `AVPlayer` this view keeps for its whole life.
///
/// It never starts playback itself. It pauses when it leaves its window and
/// when it or an ancestor is hidden, which covers switching worktree or tab,
/// pointing the pane at another file, and closing the pane. When its player
/// starts, it tells the coordinator, which pauses every other player. For an
/// audio file it hides AVKit's grey audio-only backdrop
/// (`hideAudioOnlyIndicator()`).
@MainActor
final class MediaPlayerHostView: NSView, MediaPlaybackParticipant {
    /// The class name of AVKit's private view that paints an audio-only
    /// item's backdrop. See `hideAudioOnlyIndicator()`.
    static let audioOnlyIndicatorClassName = "AVAudioOnlyIndicatorView"

    let playerView: AVPlayerView
    private(set) var player: AVPlayer?
    /// Called when the loaded file turns out not to be playable: the asset
    /// says so, or the player item fails. Called at most once per load.
    var onLoadFailure: (@MainActor () -> Void)?
    /// The running check of the current asset's `isPlayable`. Exposed so a
    /// test can await it.
    private(set) var playabilityCheck: Task<Void, Never>?

    private struct LoadKey: Equatable {
        let url: URL
        let revision: Int
    }

    private let coordinator: MediaPlaybackCoordinator
    private var loadedKey: LoadKey?
    private var failureReported = false
    private var rateObservation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?

    init(coordinator: MediaPlaybackCoordinator) {
        self.coordinator = coordinator
        playerView = AVPlayerView(frame: .zero)
        super.init(frame: .zero)
        playerView.controlsStyle = .inline
        // Autoresizing rather than constraints, so the player view's own
        // intrinsic size never reaches the size SwiftUI gives this view.
        playerView.frame = bounds
        playerView.autoresizingMask = [.width, .height]
        addSubview(playerView)
        coordinator.register(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows `url` at `revision`, paused at the start. The same pair as the
    /// last load does nothing, so SwiftUI updates leave playback alone; a new
    /// path or a new revision (the file was rewritten) replaces the item.
    func load(url: URL, revision: Int) {
        let key = LoadKey(url: url, revision: revision)
        guard key != loadedKey else { return }
        loadedKey = key
        failureReported = false

        let player = currentOrNewPlayer()
        player.pause()
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        observeStatus(of: item)
        player.replaceCurrentItem(with: item)
        logger.debug("Media preview loaded \(url.lastPathComponent, privacy: .public) at revision \(revision, privacy: .public)")

        playabilityCheck?.cancel()
        let name = url.lastPathComponent
        playabilityCheck = Task { [weak self] in
            let playable: Bool
            do {
                playable = try await asset.load(.isPlayable)
            } catch {
                guard !Task.isCancelled else { return }
                self?.reportLoadFailure(name: name, reason: error.localizedDescription)
                return
            }
            guard !Task.isCancelled, !playable else { return }
            self?.reportLoadFailure(name: name, reason: "the asset is not playable")
        }
    }

    func pausePlayback() {
        player?.pause()
    }

    /// Stops playback and lets go of the player, for when the view is
    /// dismantled.
    func tearDown() {
        pausePlayback()
        playabilityCheck?.cancel()
        playabilityCheck = nil
        rateObservation?.invalidate()
        rateObservation = nil
        statusObservation?.invalidate()
        statusObservation = nil
        coordinator.unregister(self)
        playerView.player = nil
        player = nil
        loadedKey = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            pausePlayback()
        } else {
            hideAudioOnlyIndicator()
        }
    }

    /// Hides every `AVAudioOnlyIndicatorView` under `playerView`.
    ///
    /// For an item with no video track, AVKit adds this private view when the
    /// item becomes ready to play. It fills the player's whole frame with
    /// opaque grey (measured on macOS 27 as sRGB 0.26, 0.26, 0.27) and holds
    /// the QuickTime placeholder image, so left alone it puts the play bar in
    /// a grey box. `AVPlayerView` has no public switch for it. Once hidden it
    /// stays hidden through a new item, an appearance change, playback, a
    /// resize and a move to another superview, and the play bar, which sits
    /// on a sibling branch, is untouched. The match is by class name, so if a
    /// later macOS renames the view the grey box comes back and nothing else
    /// breaks. A video item has no such view, so this does nothing there.
    func hideAudioOnlyIndicator() {
        Self.hideAudioOnlyIndicators(in: playerView)
    }

    /// AppKit calls this when this view or one of its ancestors is hidden.
    override func viewDidHide() {
        super.viewDidHide()
        pausePlayback()
    }

    // MARK: Private

    private func currentOrNewPlayer() -> AVPlayer {
        if let player { return player }
        let player = AVPlayer()
        self.player = player
        playerView.player = player
        // `play()` sets `rate` at once, whereas `timeControlStatus` waits on
        // the audio output device, which a machine without one never reports.
        // The handler is `@Sendable`; only the `Float` crosses to the main
        // actor.
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] _, change in
            guard let rate = change.newValue, rate != 0 else { return }
            MediaPlayerHostView.performOnMain { self?.playerDidStart() }
        }
        return player
    }

    private func observeStatus(of item: AVPlayerItem) {
        statusObservation?.invalidate()
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            switch observedItem.status {
            case .failed:
                let itemID = ObjectIdentifier(observedItem)
                MediaPlayerHostView.performOnMain { self?.itemDidFail(itemID) }
            case .readyToPlay:
                MediaPlayerHostView.performOnMain { self?.itemBecameReady() }
            default:
                break
            }
        }
    }

    /// AVKit adds its audio-only indicator in its own reaction to this same
    /// status change, which may run after this one, so this hides it now and
    /// again on the next main-queue turn, once AVKit's reaction has run.
    private func itemBecameReady() {
        hideAudioOnlyIndicator()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hideAudioOnlyIndicator()
            }
        }
    }

    private static func hideAudioOnlyIndicators(in view: NSView) {
        for subview in view.subviews {
            if !subview.isHidden,
               String(describing: type(of: subview)) == audioOnlyIndicatorClassName {
                subview.isHidden = true
            }
            hideAudioOnlyIndicators(in: subview)
        }
    }

    private func playerDidStart() {
        guard let player, player.rate != 0 else { return }
        coordinator.participantDidStartPlaying(self)
    }

    private func itemDidFail(_ itemID: ObjectIdentifier) {
        // A report from an item that has since been replaced is stale.
        guard let item = player?.currentItem, ObjectIdentifier(item) == itemID else { return }
        let name = loadedKey?.url.lastPathComponent ?? ""
        reportLoadFailure(name: name, reason: item.error?.localizedDescription ?? "the player item failed")
    }

    private func reportLoadFailure(name: String, reason: String) {
        guard !failureReported else { return }
        failureReported = true
        logger.debug("Media preview cannot play \(name, privacy: .public): \(reason, privacy: .public)")
        onLoadFailure?()
    }

    /// KVO handlers are `@Sendable` and AVFoundation may call them off the
    /// main thread, so this runs `body` on the main actor: at once when
    /// already on the main thread, otherwise on the next main-queue turn.
    nonisolated private static func performOnMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
        }
    }
}

/// Plays one audio or video file with AVKit's inline controls. Never starts by
/// itself; reloads paused when `revision` changes; pauses when removed or
/// hidden; and pauses any other player when it starts.
struct MediaPlayerView: NSViewRepresentable {
    let url: URL
    let revision: Int
    var onLoadFailure: @MainActor () -> Void = {}

    @Environment(\.mediaPlaybackCoordinator) private var playbackCoordinator

    func makeNSView(context: Context) -> MediaPlayerHostView {
        let host = MediaPlayerHostView(coordinator: playbackCoordinator)
        host.onLoadFailure = onLoadFailure
        host.load(url: url, revision: revision)
        return host
    }

    func updateNSView(_ host: MediaPlayerHostView, context: Context) {
        host.onLoadFailure = onLoadFailure
        host.load(url: url, revision: revision)
    }

    static func dismantleNSView(_ host: MediaPlayerHostView, coordinator: ()) {
        host.tearDown()
    }
}
