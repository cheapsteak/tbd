# Retiring SwiftTerm

TBD parses terminal output with two emulators. The app's viewer runs on SwiftTerm by
default, or on libghostty-vt when the Experimental engine setting is on
([design](2026-11-07-libghostty-terminal-engine-design.md)). The daemon keeps every
pty-holder session in a headless SwiftTerm, and tmux control-mode panels draw through
SwiftTerm. This design moves all of it onto libghostty-vt, then deletes SwiftTerm and TBD's
fork of it. The work runs in four streams:

- **A** – libghostty becomes the app's default engine.
- **B** – the tmux transport leaves, as issue #851 plans.
- **C** – the daemon's emulator moves to libghostty-vt behind a default-off flag.
- **D** – the SwiftTerm code and the fork are deleted.

## Goal

- **Goal** – one terminal parser, libghostty-vt, in both the viewer and the daemon, and no
  SwiftTerm product in `Package.swift`.
- **Not goals:**
  - recovering the screen and the terminal modes that re-adoption loses after a daemon
    restart. That has its own design. Both designs change `HolderReader`, so whichever
    lands second rebases. The resize jiggle that one relies on works the same with either
    emulator.
  - a new terminal identity. TBD keeps its DA1, DA2 and XTVERSION answers byte for byte
    ("Device identity").
  - ligatures and BiDi, which stay unsupported
  - porting tmux control mode, which issue #851 deletes together with tmux

## Why

- **The viewer is ready.** The engine design's graduation rule asks for a clear win, a soak
  with no crash, and no open daily-use gap.
  - **Win** – after the frame-timing work
    ([design](2026-11-08-libghostty-frame-timing-design.md)), the draw-wait p90 for typed
    echo under load was 0.55–0.73× SwiftTerm's in both A/B/B/A runs of
    `terminal-latency-probe.py`. While Claude Code streams, app CPU was about 0.35× that of
    SwiftTerm on CoreGraphics. #1443 removed the frame drops under bulk output.
  - **Soak** – the maintainer has used the engine daily since it shipped, and no app crash
    report from that time has libghostty frames.
  - **Gaps** – the maintainer ruled that the remaining gaps (listed under A) are not
    daily-use gaps.
- **Two engines cost more than one.** Each change to the viewer contract lands twice: the
  contract suites run against both engines, the handback has two writers, and the fork
  carries patches that upstream SwiftTerm lacks (public saved modes, a parser-boundary
  query, and API that SwiftTerm 2.0 removed).
- **One parser for both pictures.** The holder transport design chose a headless SwiftTerm
  for the daemon over a third-party VT because it "gives one parser for both pictures"
  ([design](2026-08-30-pty-holder-session-transport-design.md), rejected alternatives). With
  the viewer on libghostty, the same reason points the other way: a SwiftTerm daemon is now
  the second interpretation of the stream.

## Order of work

- **A, B and C start together.** They change mostly different files.
- **D starts when three things are true:** A has merged, #851's Phases 4 and 5 have
  merged, and the daemon flag from C is on by default.
- **Each stream has its own plan, written when the stream starts.** A is one PR and needs
  none. B follows the phase list in issue #851. C's plan follows this design. D's plan is
  written when D starts, because C moves much of the code that D deletes.
- **Merging** – each PR merges when it is ready: the review bot approves, CI is green, and
  the review loop is clean. That includes the daemon flag's flip at the end of its soak.

## A – libghostty becomes the app's default

- **The change** – `AppState.ghosttyTerminalEngineDefault` becomes `true`. The
  `useGhosttyTerminalEngine` key has three states, so the change reaches every install
  that never chose, and an explicit `false` still holds. No migration.
- **Kept until D** – the Experimental toggle, Switch Terminal Engine (⌃⌘E) and the engine
  label on tabs. A person who meets a problem can go back to SwiftTerm for one terminal or
  for all of them.
- **Release note** – the commit message carries a `Release note:` paragraph: new terminals
  draw with libghostty, and the Experimental toggle turns it off.
- **Gaps fixed after the flip,** each in its own PR, in this order:
  - A plain-text link (a path or URL without OSC 8) shows no underline while the pointer
    is over it with Command held.
  - Link detection runs at mouse-down, so a Command-drag that starts on a URL opens it.
  - Faint text draws at reduced alpha, where SwiftTerm blended it with the background.
  - libghostty leaves the kitty graphics query (`a=q`) unanswered. SwiftTerm answered it.

## B – tmux leaves

- **The work** – B continues issue #851 from where it stands: any Phase 2 item still open,
  then Phase 4, which deletes the tmux legs and control mode in one step, then Phase 5,
  which removes the test fence and the CI installs.
- **Sessions still on tmux** – Phase 4 waits until no tmux rows remain, which TBD cannot
  observe on other installs. The
  [migration design](2026-10-11-holder-transport-migration-design.md) covers that case: a
  person moves a session with the migrate action, and after the tmux path is gone a
  leftover row refuses to wake, with a reason that names the action.
- **What D needs from B** – `TmuxBridge` and the control-mode panels are gone. They are the
  last viewers that have to draw through SwiftTerm.

## C – the daemon's emulator moves to libghostty-vt

### A headless core target

The daemon must not link AppKit or Metal, and `TBDGhosttyTerminal` holds both. A new
target, `TBDGhosttyCore`, takes the headless half. It depends on `GhosttyVt` and
`TBDShared`, and `TBDGhosttyTerminal` depends on it.

- **Moved into the core:**
  - the terminal wrapper: `GhosttyTerminal`, `GhosttyTerminalCallbacks`,
    `GhosttyTerminalState`, `GhosttyScreenAccess`, `GhosttyVt+Swift`, `GhosttyError`
  - serialization: `GhosttyGrid`, `GhosttySnapshotWriter`, `GhosttyScreenProjection`
  - what `withScreenAccess` and the grid need: `InputBinding`, `KeyEncoder`,
    `MouseEncoder`, `SelectionController` and `ScrollMetrics`. None imports AppKit.
  - from the app target: `ProgramStatusProbeAnswer` and `ProgramStatusPayloadBuilder` from
    `GhosttyEngine.swift`, and `ProgramStatusGate` from `TBDTerminalView.swift`
- **Two moves come first:**
  - `GhosttyAppearance.RGB` leaves `GhosttyAppearance.swift`, which imports AppKit.
    `GhosttyTerminalState` uses `RGB`.
  - `ProjectedScreen` moves from `TBDTerminalSerialization`, which depends on SwiftTerm, to
    `TBDShared`, beside `TerminalScreen`. Both projections produce it.
- **Logging** – the core's logger takes its subsystem from the host, so daemon lines land
  under `com.tbd.daemon` and app lines stay under `com.tbd.app`.
- **What stays in `TBDGhosttyTerminal`** – the view, the input controller, the renderer and
  the appearance.

### The emulator seam

`HolderReader` talks to its emulator through a protocol, `HolderEmulator`, with two
implementations: `SwiftTermHolderEmulator` (today's code, moved behind the seam) and
`GhosttyHolderEmulator`.

- **Duties** – the protocol covers what the reader needs: feeding output, resizing, the
  size, the parser-boundary query, cursor visibility, the mode capture, the screen
  projection for `tbd terminal output`, the styled capture, the viewport lines, the attach
  snapshot, the handback feed, the replies to the child and the OSC 7501 reports.
- **One lock** – the emulator's bookkeeping lives in one type, `HolderEmulatorLedger`,
  that both emulators use: when the emulator began, when it last took in bytes, and
  whether it watched its child from birth. Each emulator keeps its own ledger, and stamps
  it and parses a chunk in one hold of its terminal's own lock. It reads the screen and the
  ledger in one hold too. The SwiftTerm emulator holds `terminalLock`. `GhosttyTerminal`
  takes its lock itself, so the core adds `feed(_:muted:underLock:)`, which runs the stamp
  inside the same hold as the parse. `GhosttySnapshotWriter` also takes the lock itself, so
  the emulator calls it outside any hold.
- **Choice at creation** – the reader reads the flag when it is created: for a new session,
  or for every session at re-adoption when the daemon starts. A running session never
  changes emulator.
- **Viewport lines** – libghostty has no twin of SwiftTerm's `viewportLines`. The core adds
  one, built on `lineText(_:)`.

### Device identity

`SwiftTermDeviceIdentity.rawAnswers()` builds a SwiftTerm terminal and asks it for its DA1,
DA2 and XTVERSION answers, and the libghostty engine sends those. C freezes the current
bytes as constants in the core. A test pins the constants to `rawAnswers()` while SwiftTerm
exists, and D deletes `rawAnswers()` and keeps the constants. The app engine and the
daemon's libghostty emulator both answer with the constants. Claude Code turns on DEC 2026
frames only when XTVERSION is answered, so the answer must not disappear.

### OSC 7501

The daemon's OSC 7501 tap is TBD's only source of agent state. libghostty has no raw OSC
hook: it parses OSC 7501 itself, reports the parsed fields, and answers the probe in a form
TBD does not use. The daemon takes the app engine's approach:

- `ProgramStatusPayloadBuilder` rebuilds the payload that TBD's tap expects from the parsed
  fields.
- `ProgramStatusProbeAnswer` replaces libghostty's probe answer with TBD's in the reply
  bytes. libghostty has no "probe seen" event, so the daemon logs the probe at this swap.
- While the reader feeds a handback preamble, the program-status callback is muted, as the
  SwiftTerm handler is silenced today. A replayed report must never read as the child
  speaking.

### Replies to the child

libghostty sends device-status, cursor-position and mode replies through `writePty`, after
its lock drops and before `feed` returns. The daemon forwards them to the child, as the
SwiftTerm delegate's `send` does. The emulator feeds a handback preamble with
`feed(_:muted:underLock:)` and `muted` set, which drops them for that one parse.

The mode capture reads modes with `mode(_:ansi:)`, so the libghostty emulator feeds no
DECRQM queries into the live terminal. The SwiftTerm emulator's queries could cut a
program's unfinished sequence, which is why the parser-boundary wait exists. That wait
stays for the SwiftTerm emulator until D.

### Attach snapshot and handback

- **VT text in both directions** – the daemon writes the attach snapshot with
  `GhosttySnapshotWriter`, and it feeds the viewer's handback VT text into its libghostty
  terminal with replies and OSC 7501 muted.
- **No binary snapshot** – libghostty's own snapshot format is outside its 1.0 ABI promise,
  and an update hands over between a daemon and an app built from different commits.
- **Receivers** – until D, a person who turned the app engine off still views with
  SwiftTerm. The writer's output must restore on that viewer too. The handover corpus
  already checks libghostty-to-SwiftTerm handovers.

### Mode differences

libghostty keeps one value of wraparound (DECAWM), reverse wraparound and left/right margin
mode (DECLRMM) for both screens. Its saved cursor (DECSC) carries only origin mode. SwiftTerm
keeps these per screen. A session that sets them differently on the two screens therefore
comes back with one value for both. Each such case is an expected miss in the parity gate,
with its reason. The libghostty viewer already behaves this way, so after C the daemon and
the viewer agree.

### Scrollback

The daemon keeps 5,000 lines per session. `GhosttyTerminal` also sets a byte cap of lines ×
4,096, which at 5,000 lines is a ceiling of about 20 MB per session. Real use depends on
content. The daemon keeps both caps as they are. At the end of the soak, the daemon's
footprint at the maintainer's usual session count goes into the migration record
([`docs/research/2026-10-28-terminal-engine-libghostty.md`](../research/2026-10-28-terminal-engine-libghostty.md))
for information. It is not a gate.

### The flag

- **Storage** – a new `.sql` migration adds `ghostty_daemon_emulator_enabled INTEGER` with
  no SQL default. The GRDB record and the Codable model gain the field, and
  `ConfigRecord.toModel()` resolves it as `?? Config.ghosttyDaemonEmulatorDefault`, which
  is `false`. All of this is one commit.
- **Toggle** – Settings ▸ Terminal ▸ Experimental gains a toggle beside the engine toggle.
- **When it applies** – new sessions take the new setting at once. Every session takes it at
  the next daemon start, because re-adoption builds every reader fresh.
- **Rollback** – turn the toggle off, then restart the daemon.

### Gates and the flip

- **Corpus parity in CI.** A suite feeds recorded byte streams through both daemon
  emulators and compares the results:
  - the `tbd terminal output` text and the styled capture
  - the OSC 7501 reports delivered and the replies sent to the child
  - the modes and the screen that the attach snapshot restores in a fresh libghostty viewer

  The results must be equal, except for a listed set of expected misses, each with its
  reason in the test file, as `HandoverCorpusTests` already does. The streams are the
  handover corpus (`Tests/TBDGhosttyTerminalTests/Handover/Corpus/HandoverCorpus.swift`,
  111 states) plus new recordings: Claude Code against the fake model API
  (`scripts/claude-stub.py`), and scripted shell sessions in `vim`, `less` and a colour log.
  The repository is public, so no recording comes from a real session, and every recording
  must be deterministic.
- **One week of soak.** The flag is on on the maintainer's machine for one week. The soak
  passes when no daemon crash report from that week has libghostty frames, and the daemon's
  logs show no attach failure and no handback error.
- **The flip** – `Config.ghosttyDaemonEmulatorDefault` becomes `true`. The column has no SQL
  default, so the change reaches every install that never chose, keeps explicit choices,
  and needs no reset migration. The flip merges when the crash reports for the week are
  clean. Its commit carries a `Release note:` paragraph.

## D – SwiftTerm goes

Three PRs, in order. Each leaves the build green.

- **D1, the app:**
  - **Deleted** – `SwiftTermEngine`, `TBDTerminalView`, the engine toggle with its key and
    its three-state reading, Switch Terminal Engine, the engine label, the
    `useMetalTerminalRenderer` setting and its toggle, the SwiftTerm half of
    `TerminalCommitLatencyProbe`, and `SwiftTermDeviceIdentity`.
  - **Replaced:**
    - `SwiftTermLinkDetector`, which copies rows into a headless SwiftTerm, by URL and path
      detection over libghostty rows
    - `SwiftTerm.Color` in the themes (`AppearanceSettings`, `ColorSchemes`,
      `UserTerminalTheme`, the theme editor, `GhosttyAppearance+AppearanceSettings`) by a
      TBD-owned RGB type, and `CursorStyle` by a TBD-owned enum. User theme files keep
      their format on disk.
    - SwiftTerm's `LocalProcess`, which starts the pty for remote-attach and sign-in
      terminals, by a TBD-owned pty spawner
    - `TBDTerminalView.defaultMonospaceFont` and `cellDimensions`, which `AppState` uses,
      by the libghostty engine's font set and cell metrics
    - SwiftTerm's bracketed-paste constants by TBD-owned ones
    - the app engine's scrollback, today SwiftTerm's default of 500 lines, by a TBD
      constant with the same value
  - The engine contract suites keep running, now against one engine.
- **D2, the daemon** – `SwiftTermHolderEmulator` goes, with the toggle. The flag's column
  is retired by "Retiring a column" in
  [`Sources/TBDDaemon/Database/CLAUDE.md`](../../Sources/TBDDaemon/Database/CLAUDE.md).
- **D3, the rest:**
  - the SwiftTerm half of `TBDTerminalSerialization` (`SGREncoder`, `TerminalCellWalk`,
    `TerminalModeCapture`, `TerminalScreenProjection`, `TerminalSnapshotWriter`), and the
    target itself if nothing is left in it
  - the SwiftTerm-only tests. Tests that use SwiftTerm as an oracle move to libghostty
    or go.
  - the fork, from `Package.swift` and `Package.resolved` (with its `originHash`), and the
    `Package.swift` comments that explain it
- **Done test** – `git grep -i swiftterm -- Sources Tests Package.swift` finds only the
  frozen identity constants and the comment that explains them.
- **Rollback after D** – the previous app bundle that `tbd update` keeps at
  `~/tbd/updates/previous/TBD.app`, or a revert.

## Size and order of work

Each item is one PR.

- **A:** the flip, then one PR per gap.
- **B:** issue #851's remaining phases.
- **C:**
  1. **The core** – the `RGB` and `ProjectedScreen` moves, the `TBDGhosttyCore` target
     with the injected logger, the OSC 7501 helpers and `ProgramStatusGate`, and the
     frozen identity constants with their pin test. No behaviour changes.
  2. **The seam** – `HolderEmulator` with the SwiftTerm implementation only. No behaviour
     changes.
  3. **The flag and the libghostty emulator** – the migration, the record, the model and
     the toggle, and `GhosttyHolderEmulator` chosen by the flag.
  4. **The parity suite** – the comparison and the new recordings.
  5. **The flip,** after the week of soak.
- **D:** D1, D2, D3.

## Testing

- **A** – the three-state tests stay: an unset key follows the default, and an explicit
  `false` holds. The test that pins the default's value changes with it.
- **C:**
  - **The flag** – each branch has a test: off gives the SwiftTerm emulator, on gives the
    libghostty one, and unset follows the default. A pre-migration row reads NULL rather
    than `0`, and an explicit `false` survives a change of the default constant.
  - **The seam** – the reader's unit tests run against both emulators.
  - **Live tests** – `HolderAttachHandoff`, `HolderAttachViewerGrid` and
    `HolderDetachHandback` in `TBDDaemonLiveTests` run with both emulators.
  - **Parity** – the suite under "Gates and the flip".
- **D** – the contract suites run against libghostty alone, and the done test's grep is a
  CI step.

## Durable resources

This design creates no new kind of durable resource. The daemon's emulator is memory that
its reader owns, and the flag is a column on an existing row. No reconciler is needed.

## Rejected alternatives

- **Keep SwiftTerm in the daemon only.** The viewer and the daemon would read the stream
  with two parsers, and the long tail of escape sequences is where they disagree. The fork
  would stay.
- **Send the fork's patches upstream and use stock SwiftTerm in the daemon.** This removes
  the fork but keeps two parsers. It also depends on upstream accepting patches that TBD
  needs now.
- **Port the control-mode panels to libghostty.** Control mode exists only to drive tmux,
  which is leaving. Issue #851 deletes the two together.
- **Move the daemon without a flag.** A regression would reach every install at once, and
  the only way back would be the whole previous app. Replacing a load-bearing path needs a
  default-off flag.
- **Delete without first flipping the app's default.** People who never tried libghostty
  would meet it with no way back.
- **Use libghostty's binary snapshot for attach and handback.** Its format is outside the
  ABI promise, and a handover can pair builds from different commits.
- **Answer as TBD, or let libghostty answer as Ghostty.** A program that keys features off
  the terminal's name could change behaviour under a new name. Ghostty's name could invite
  features that TBD's input layer does not support, such as the kitty keyboard protocol.
  Frozen bytes change nothing, and a later design can still choose a new identity.
- **Gate the daemon flag on footprint and CPU too.** Parity and the soak catch what can go
  wrong for a person. The footprint is recorded for information.
