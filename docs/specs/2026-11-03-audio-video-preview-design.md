# Audio and video preview in the file viewer

## Summary

The file viewer pane plays audio and video files with the macOS system player
(AVKit's `AVPlayerView`). Which files qualify comes from the system at run
time, not from a list in TBD: a file is media when its type is audio or video
and AVFoundation says it can play that type.

The player never starts by itself, pauses whenever its view is removed or
hidden, and only one file plays at a time across the app. Audio shows as a compact card
with the system play bar; video fills the pane.

The "Cannot preview binary file" screen, which every other non-text file still
reaches, gets two buttons: **Quick Look**, which opens the floating Quick Look
panel TBD already drives for transcript images, and **Reveal in Finder**. The
second replaces an "Open in Finder" button that opened the file in its default
app instead.

## What the system supports

Measured on macOS 27.0.1 (26A434) on 2026-11-03.

- **AVFoundation's playable types** (`AVURLAsset.audiovisualTypes()`) include
  these audio extensions: mp3, m4a, aac, wav, aiff, caf, flac, ogg, oga and
  opus. They also include these video extensions: mp4, m4v, mov, avi, 3gp and
  the MPEG transport and program streams. `AVURLAsset.isPlayableExtendedMIMEType`
  answers true for `audio/ogg`, `audio/ogg; codecs=opus` and `audio/flac`.
- **Not playable:** webm and mkv, in either API.
- **The list includes text formats**: playlists (m3u, m3u8, pls) and captions
  (vtt, webvtt, ttml, scc, itt). These are not audio or video content, so the
  type check below keeps them on the text view.
- **Hidden worktrees stay alive.** `WorktreePager` is an `NSTabViewController`,
  so the views of a worktree the user switched away from are detached from the
  window but not destroyed. An `AVPlayerView` detached while playing kept
  playing for more than nine seconds, so the player has to pause itself.
- **Tabs do not stay alive.** Within a worktree, the primary leaf is keyed by
  tab ID (`.id(tab.id)` in `PanelSurfaceWorkspaceView`), so switching tabs
  dismantles the old tab's view.

## Behavior

### Which files get the player

The viewer decides a file's view in this order: rendered markdown, image,
**media**, text, then the "Cannot preview" screen.

A file is media when both hold:

- its `UTType`, looked up from the file extension, conforms to `.audio` or
  `.movie`
- that type is in `AVURLAsset.audiovisualTypes()`

Playlists and captions fail the first test and reach the text view. A webm or
mkv file can pass the first test, through a type another app registers, but
fails the second, so it reaches the "Cannot preview" screen.

### Audio

A compact card centered in the pane, with these parts:

- a music symbol
- the file name
- the duration
- an `AVPlayerView` with `controlsStyle = .inline`, framed to the height of its
  control bar: play and pause, scrubbing, volume

The card does not show `AVPlayerView`'s audio-only placeholder, a large
QuickTime logo over an empty area.

### Video

An `AVPlayerView` with inline controls fills the pane, the way an image does
today.

### Multi-file selection

When the viewer's sidebar selects several files, they stack in the pane's
scroll view. An audio file shows its card at the card's own height. A video
shows in a 16:9 frame as wide as the pane.

### Playback rules

- **Never starts by itself.** Loading a file leaves it paused. Playback starts
  only when the user presses play.
- **Pauses when its view is removed or hidden.** That covers four gestures:
  switching to another worktree, switching to another tab, pointing the pane at
  another file, and closing the pane. Coming back does not resume. Minimizing
  the window removes nothing, so playback continues, as in other Mac apps.
- **Reloads when the file changes on disk.** When an agent rewrites the file,
  the player loads the new contents, paused, at the start.
- **One at a time.** Starting a file pauses whichever file was playing,
  anywhere in the app.

### The "Cannot preview" screen

Files with no view of their own keep this screen, with two buttons:

- **Quick Look** opens the floating Quick Look panel on the file. Through it
  the user reaches PDF, office documents and anything else Quick Look can show,
  without TBD embedding Quick Look.
- **Reveal in Finder** selects the file in a Finder window, as "Reveal in
  Finder" in the pane header's menu already does.

The button it replaces was labelled "Open in Finder" but called
`NSWorkspace.shared.open` on the file, which hands it to its default app. An
audio file opened in Music; a zip goes to its default app, normally Archive
Utility, which unpacks it into the worktree.
Every other Finder button in the app already reveals.

## Design

### Units

New files live in `Sources/TBDApp/Panes/MediaPreview/`, so
`CodeViewerPaneView.swift` does not grow.

- **`FilePreviewKind`**
  - **What it does:** decides which view a path gets: rendered markdown,
    image, audio, video, text or unpreviewable.
  - **Inputs:** the path, the set of playable type identifiers, and a text
    sniff. The playable set defaults to `AVURLAsset.audiovisualTypes()`; tests
    pass their own.
  - **Caching:** `UTType(filenameExtension:)` queries Launch Services, which
    the app's rules keep out of SwiftUI bodies. So the media decision is cached
    per lowercased extension, and the whole classification runs when the path
    or revision changes, never in `body`.
- **`MediaPlayerView`**
  - **What it is:** an `NSViewRepresentable` around a plain `NSView` subclass
    that owns one `AVPlayerView` and its `AVPlayer`.
  - **Pausing:** the host view pauses the player in `viewDidMoveToWindow` when
    its window becomes nil, and in `viewDidHide`, which AppKit calls when the
    view or an ancestor is hidden. `dismantleNSView` pauses the player and
    releases it.
  - **Reloading:** a new path or revision replaces the player item with one
    built from a fresh `AVURLAsset` and leaves playback paused.
  - **Error state:** it reports load failure upward, as described under
    "Errors" below.
- **`AudioPreviewCard`**
  - **What it is:** the SwiftUI card that lays out the symbol, name and
    duration around a `MediaPlayerView`.
  - **Duration:** loaded with `asset.load(.duration)` in a task, never in
    `body`.
- **`MediaPlaybackCoordinator`**
  - **What it does:** enforces "one at a time".
  - **How:** each `MediaPlayerView` registers its player. The coordinator
    observes each player's `timeControlStatus`, and when one starts playing it
    pauses the rest. It holds players weakly.
  - **How views get it:** through the SwiftUI environment, with an app-wide
    default instance, so a test can supply its own.

### Changes to existing code

- **`FilePreviewView`** routes through `FilePreviewKind`. The UTF-8 sniff that
  today reads 8 KB from disk inside `body` moves into the existing
  `.task(id: path#revision)` alongside the rest of the classification.
- **`BinaryFallbackView`** gets the two buttons above. Reveal in Finder calls
  the existing `revealInFinder(path:)` helper in `HeaderFileActions.swift`.
- **`TranscriptQuickLook`** becomes `QuickLookPresenter` and moves out of
  `Panes/Transcript/`, because the viewer now uses it too. Its `showPanel` test
  seam and the `AppDelegate` responder-chain wiring stay as they are.

### Errors

- **A file that does not load.** It can be on the playable list and still fail
  to load: corrupt, or a codec inside the container the system cannot decode.
  When the asset reports it is not playable, or the player item fails, the pane
  shows the "Cannot preview" screen with both buttons.
- **No size limit.** The player streams from disk, unlike the 1 MB cap on
  rendered markdown.
- **A missing file** behaves as it does today.

### What this change does not need

- **No feature flag.** The change is new UI beside what is there. It starts
  nothing without a click, and it moves no existing item. A media file used to
  reach a dead-end screen and now shows a player.
- **No daemon, database or RPC change.** Rendering a file is app-only, and no
  user-land surface can draw into a pane.
- **No reconciler.** The change creates no durable resource: no file, process,
  git ref or tmux object outlives the view.

## Testing

Unit tests use Swift Testing and run through `scripts/test.sh`.

- **`FilePreviewKind`**, with an injected playable set:
  - m4a, mp3, wav and flac classify as audio
  - mov and mp4 classify as video
  - mkv, absent from the set, classifies as unpreviewable
  - m3u and vtt classify as text
  - png classifies as an image
  - md classifies as rendered markdown
- **`FilePreviewKind` against the real system list**: m4a, wav and mov classify
  as media. This guards the conformance assumption if the system renames a
  type.
- **`MediaPlayerView`**, in an offscreen window, with a short wav the test
  writes with `AVAudioFile`:
  - after load, `rate == 0`
  - play, then remove from the window: paused
  - play, then hide an ancestor: paused
  - a revision bump: a new item, paused, at time zero
- **`MediaPlaybackCoordinator`**: starting B pauses A. The test uses a stub
  behind a small protocol, not real `AVPlayer`s.
- **`BinaryFallbackView`**:
  - Reveal in Finder reveals and never opens. Its actions are injectable, so
    the test sees which was called.
  - Quick Look reaches `QuickLookPresenter` through its `showPanel` seam, so no
    panel appears during the run.

Live verification after `scripts/restart.sh`, with cua-driver window captures:

1. m4a, wav and mov files opened from a terminal link start paused and play on
   click.
2. Audio playing, then a switch to another worktree, stops. Switching back
   finds it still paused.
3. With file A playing in one pane, starting file B in another pauses A.
4. On a zip, Quick Look opens the floating panel, and Reveal in Finder selects
   the zip in Finder. Neither Music nor Archive Utility opens.
5. An agent rewriting an open audio file reloads it.
6. The audio card's `AVPlayerView` draws its whole control bar at the card's
   height.

Playback state comes from the player, not from listening. A ten-second listen
by a person confirms that a worktree switch silences the audio.

## Out of scope

- Waveforms, and metadata beyond duration (sample rate, channels, codec).
- The transcript overlay's file frame (`OverlayFileView`), which shows text
  only. The transcript's Preview File button opens the viewer pane, so it gets
  the player.
- Quick Look or PDF rendered inside the pane. PDFKit's `PDFView` is the route
  for an in-pane PDF if it is wanted later.

## Rejected alternatives

### Quick Look embedded in the pane

`QLPreviewView` in the pane, for every file TBD cannot show itself, would cover
the most formats with one view. A probe measured it in a bare executable
without a bundle, the way TBDApp runs
([`docs/research/2026-11-03-quicklook-in-pane/`](../research/2026-11-03-quicklook-in-pane/)).

- **It renders.** The subtree is `QLPreviewView` › `QLPreviewContainerView` ›
  `NSRemoteView`. An out-of-process `QuickLookUIService` draws the preview,
  starts on the first preview, and lives until the host exits.
- **Two misuses abort the host process.** Each is a `_QLRaiseAssert` →
  `abort()`, which code cannot catch:
  - setting a non-nil `previewItem` on a deactivated view
    (`item == nil || internalState != QLPreviewDeactivatedInternalState`)
  - calling `close()` on a view that is not active
    (`internalState == QLPreviewActivatedInternalState`)
- **The state changes behind the caller's back.** With the default
  `shouldCloseWithWindow = YES`:
  - closing the window deactivates the view for good
  - `removeFromSuperview` deactivates it until it is added back
  - a re-added view stays blank, and `refreshPreviewItem` does not restore it
  
  No public API reports the state; `displayState` is opaque. TBD detaches the
  views of hidden worktrees from the window, so an unguarded update after a
  worktree switch would abort the whole app.
- **The safe configuration needs bookkeeping.** With
  `shouldCloseWithWindow = NO`, detaching or hiding pauses instead, but TBD
  would then have to track activation itself, close every view exactly once to
  avoid leaks, and build a new view after every close.
- **Playback is invisible.** Audio plays in `QuickLookUIService`, and no public
  API reports whether it is playing, so "one at a time" could not be enforced.
- **The gain beyond media is small.** It plays exactly the formats
  AVFoundation plays. It rendered PDF. It showed only an icon for webm, mkv,
  zip and random bytes. Office and iWork documents were not tried.

The floating `QLPreviewPanel` behind the Quick Look button keeps most of the
coverage. AppKit manages its lifecycle, and TBD already ships it.

### A hard-coded extension list

The viewer's image check uses a fixed `imageExtensions` set. A media set built
the same way would go stale as the system gains formats, and could claim a
format the running system cannot play. AVFoundation's own list is the
authority on what will play.

### SwiftUI's `VideoPlayer`

AVKit's SwiftUI view wraps the same player but gives no hook for the view
leaving its window. That event is how a hidden worktree's player knows to
pause.

### Custom controls

A SwiftUI play button and slider would match TBD's styling more closely. It
would also reimplement scrubbing, volume and the rest that `AVPlayerView`
already provides and keeps current with the system.
