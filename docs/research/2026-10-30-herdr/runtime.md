# herdr runtime architecture, read for TBD

*Researched 2026-10-30 as a read-only survey of the source of `herdrdev/herdr`
at ee5bfb50 (2026-10-29; 1,880 commits), `herdrdev/herdr-core` at 9edb39d (44
commits since its 2026-10-23 public initial commit) and `herdrdev/herdr-app`
at 8180cbe (146 commits since 2026-10-23), plus GitHub issues, PRs and
discussions. It covers herdr's runtime architecture (process model, live
upgrade, persistence, terminal engine, render protocol, remote machines) and
what it says about TBD's libghostty decision. Herdr paths are relative to the
root of the repo named alongside them. Nothing was built or run. TBD
references are against `5dce4c179`. [`README.md`](README.md) in this folder
is the index and synthesis.*

This builds on, and does not repeat,
`docs/research/2026-08-30-terminal-session-persistence/` (which had herdr as one
line: "persistent server owning all pty sessions … layout and cwd saved to a
JSON file") and `docs/research/2026-10-28-terminal-engine-libghostty.md`.

There are three products under one name. They make different choices, so this
report keeps them apart:

- **herdr** (v0.9.x, "Herdr 1"): one `herdr server` per named session owns every
  PTY and runs every emulator; TUI clients connect over a Unix socket. Live
  upgrade passes PTY masters to a successor server.
- **herdr-core** (`hc`, "core draws nothing"): a core process (parser, API,
  state) plus **holder** processes that own the PTYs. This is herdr's second
  attempt, and it is shaped much like TBD's holder design.
- **herdr-app**: a GPUI desktop client of herdr-core that runs its own
  libghostty-vt instance per pane.

---

## (a) How herdr does each thing

### 1. Process model

**herdr (v1).** One server process owns every pane's PTY master
(`PtyIoActor` per pane, `src/pty/actor/unix.rs`) and runs a libghostty-vt
emulator per pane inside the same process (`src/terminal/state.rs`). The server
renders a frame per client (`src/server/render_stream.rs`). Since #3487, the
client draws the shell chrome itself, and the server streams pane surfaces.

- **Startup on macOS.** Through launchd since #5236 (2026-10-15).
  `spawn_launchd_job` (`src/platform/macos/launchd_spawn.rs:31`) writes a
  one-shot plist into a `mkdtemp` directory and runs `launchctl bootstrap
  gui/<uid>`. The plist sets `RunAtLoad`, `KeepAlive=false`,
  `AbandonProcessGroup=true`, `ProcessType=Interactive` and the caller's umask
  (`:228-236`). The job process forks the real server, the child calls
  `setsid`, and the parent `_exit`s (`leave_launchd_job`, `:61`). Over SSH it
  keeps a direct spawn (`:32`). The reason for all this is in the module doc
  and in herdr#4920. A process started from a terminal stays in that terminal
  app's launchd job and **resource coalition**, even after `setsid` or a double
  fork. On some quit paths, loginwindow and launchd SIGTERM every process in
  the quitting app's coalition, so Cmd-Q of Ghostty killed the server and every
  pane.
- **macOS bootstrap context.** The server adopts the per-user bootstrap port
  (`src/platform/macos/bootstrap.rs`, PR #4202), so it keeps DNS and user
  lookup across logout. The changelog notes that "live handoff cannot repair
  their inherited service context".
- **When the server dies, every pane dies.** The masters close and the
  children get SIGHUP. Restore then brings back layout and fresh shells, and
  resumes agents from their saved session IDs (see 3). The field record:
  - SIGSEGV under multi-pane load (#2850).
  - An fd leak forced whole-session restarts. One user's log shows 218
    `server shutdown initiated` lines and 329 restarts (#3527).
  - Thread-spawn failure exited with code 101 and took every pane with it
    (#4958).
  - At least four libghostty crashes (see (c)).
- **Cost of sharing one process.** #2890 measured typing echo in a quiet pane.
  The bare-pty control stayed at 1.17 ms throughout, while herdr's echo moved
  as follows:
  - Idle: 1.65 ms p50.
  - With a *hidden* neighbour printing 400 lines/s: 15.96 ms p50.
  - With a *visible* neighbour doing the same: 85.9 ms p50, 163 ms p90.

  The cost sat in the server's output half. That is the tmux failure shape
  TBD's holder spec was written to escape.

**herdr-core.** The core is split from the PTY owners.

- **The holder** (`crates/herdr-core/src/holder.rs:1-4`): "owns every PTY, is
  every program's parent, always reads output. Spawn, pump, resize, signal,
  reap. No parsing, no policy. It keeps a ~1 MB tail per terminal so a core
  that crashed can rebuild screens, and restarts a crashed core itself."
  - There is **one holder per build**, not per terminal. A core of a different
  build starts a new holder for new terminals and sends the old one `DRAIN`:
  take no new terminals, exit when empty (`holder_proto.rs:22`,
  `runtime.rs` `take_over`). This is TBD's "old sessions run old holders",
  but at build granularity.
  - **Wire format.** Frames are `[kind u8][terminal u32][len u32][payload]`,
  with JSON control payloads and raw output bytes (`holder_proto.rs:1-3`).
  Ownership goes to the newest core: a new `Hello` evicts the current core
  (`holder.rs:150-156`). TBD's holder makes the opposite choice: it rejects a
  second client with a busy sentinel.
  - **Always reading.** `pump` (`holder.rs:311`) reads the PTY whether or not
    a core is connected, appends to the 1 MiB tail (`TAIL_BYTES`, `:14`), and
    forwards `OUTPUT` frames. No reader arbitration is needed. The price is
    that every output byte crosses a socket to the core, and every keystroke
    goes viewer → core → holder → PTY through an input thread per terminal.
  - **Exit status.** `reap` (`:335`) waits for the child, sweeps its scope
    (see idea 6), waits up to 200 ms (`EXIT_DRAIN`) for the reader to drain,
    then reports `EXITED`. The exit code always follows the last output.
  - **Crashed cores.** `supervise` (`:368`) restarts a crashed core: a 3 s
    grace, then exponential backoff capped at 60 s, counted over a 300 s
    window. The holder exits once it holds no terminals.
- **Startup.** `spawn_detached` (`client.rs:173`) starts the core. On Linux
  it runs as a systemd user service, to leave the terminal's cgroup. On macOS
  it is a plain detached spawn: herdr-core does **not** carry herdr's launchd
  coalition fix.
- **Host shutdown.** herdr-core watches the Darwin notify keys
  `com.apple.system.loginwindow.{restartinitiated,shutdownInitiated,likelyShutdown,logoutcancelled,logoutNoReturn,shutdownNoReturn}`
  (`platform/macos_shutdown.rs`), because "loginwindow can end agents well
  before launchd sends the core SIGTERM". Deaths after the point of no return
  are not recorded as exits, so `--keep` terminals come back after a reboot
  (commit `9d11d97`, 2026-10-30).

### 2. Live upgrade and handoff

**herdr (v1): fd passing between servers.** This is opt-in
(`herdr update --handoff`) and labelled experimental in the changelog. The
sequence is `src/server/headless/lifecycle.rs:25-225` with
`src/server/handoff.rs`:

1. The old server binds `herdr-handoff-<pid>.sock` (mode 0600) and mints a
   token from its pid and the time in nanoseconds.
2. It disconnects every client and rejects pending connections.
3. It quiesces each pane's PTY actor (`begin_handoff`,
   `pty/actor/unix.rs:737`):
   - It stops accepting user writes.
   - It defers until an in-flight "text, delay, then Enter" submission
     finishes.
   - It flushes pending writes for up to 2 s (`HANDOFF_DRAIN_TIMEOUT`).
   - Then it stops reading.
4. It captures the layout snapshot and, per pane, a `HandoffRuntimeState`
   (`src/handoff_runtime.rs`): child pid, rows and columns, cell pixel size,
   kitty keyboard flags and their ANSI, input modes, title, agent state, and up
   to 8 KiB of primary-screen history as ANSI (`MAX_REPLAY_BYTES_PER_PANE`,
   `handoff.rs:31`). It sends **no history for an alternate-screen pane, and
   none for a pane with a known agent session** (`lifecycle.rs:98`).
5. It spawns `herdr server --handoff-import <sock> <token>` and dups every
   master.
6. A line protocol runs, each step under a 30 s timeout:
   - The importer sends the token. The old server sends the manifest as one
     JSON line.
   - The importer checks the handoff version, expected protocol and expected
     version, then answers `validated`.
   - The old server sends the fds over `SCM_RIGHTS` in **batches of 64**
     (`:29`; one control message caps at 253 on Linux and 254 on macOS), and
     treats `MSG_CTRUNC` as fatal (`:508`).
   - The importer rebuilds the app and answers `restored`.
   - The old server removes its public sockets. The importer waits for them
     to close, binds its own, and answers `ready`.
   - The old server answers `committed`, and the importer answers `owned`
     within 500 ms.
7. Every step before the commit has a rollback: kill the import child, unpause
   the readers, re-bind the public sockets. After the commit the old server
   drops its runtimes with `preserve_processes_on_drop` and exits without
   saving the session.
8. The new server has blank emulators, apart from that 8 KiB. On the first
   client attach it **nudges** each pane: resize to rows − 1, sleep 30 ms,
   restore (`pty/actor/unix.rs:983-1025`).

The failure modes they hit, from issues:

- **Blank screens.** Agent panes come back as an empty input box, and every
  agent has to be relaunched with `--resume` (#3864, open). One cause: panes
  were cold-respawned headless at 24×80 before a client attached, and that
  blank screen was what got snapshotted.
- **Exit status is lost.** "Imported handoff panes have no child wait handle,
  so their exit cause is unknowable" (`src/pane.rs:2631`). The new server is
  not the children's parent.
- **TCC attribution.** Panes under a handed-off server lose macOS
  responsible-process attribution, so 1Password's "Always Allow" no longer
  sticks (#807). The Local Network effect of the same cause is #808, under 6
  below.
- **Smaller defects:**
  - The first client after a handoff ignores all keyboard input (#2644).
  - Named sessions failed to hand off (#1180).
  - `(deleted)` exe paths after an in-place package upgrade (#516), and a
    binary replaced by an update (#4397).
  - A 64-pane limit (#3393).
  - The plugin registry was dropped (#893).
  - Mouse forwarding broke (#3000).
  - Kitty keyboard flags went stale on the alt screen (#5291, open).
  - A duplicate agent session ID cleared `agent_session` on one pane (#5443,
    open).
  - Under a systemd user service, a handoff killed every pane (#4972, open).

**herdr-core: the core restarts and the holder keeps everything.**

- SIGTERM means a planned restart (`server.rs:64`). The core calls `handover()`
  (`runtime.rs:751`): it sends `Goodbye::Handover` to each holder, flushes
  each relay, writes every screen with libghostty-vt's native
  `ghostty_snapshot_encode_alloc` (`crates/ghostty-vt/src/lib.rs:692`) to
  `state/screens/<addr>.snap` atomically (write tmp, fsync, rename), and
  exits.
- On `Goodbye::Handover` the holder **clears its tails** (`holder.rs:239`):
  "The core saved screens up to here; the next one replays only what follows."
- The next core, started by a client or by the holder's `supervise`, sends
  `Hello`. It gets a `Welcome` (`previous: "handover" | "crash" | "none"`) and
  one `TAIL` frame per terminal. `adopt` (`runtime.rs:367`) then works as
  follows:
  - **After a handover**, it restores the snapshot and feeds the tail, which
    gives an **exact** screen. Terminal replies to queries in the tail are
    sent to the program, because nobody has answered them yet.
  - **After a crash**, it builds a blank screen, feeds the 1 MiB tail and
    gets an **inexact** screen. It **drops** the replies ("answered long ago
    and replies would be typed as garbage", `:405`). It reconciles status
    reports so that at most one turn is counted for the downtime, and nudges
    a redraw: rows − 1, 50 ms, restore (`:448-457`).
  - The screen's provenance is recorded per terminal (`rec.screen =
    "exact"|"inexact"`, `:434`).
  - Terminals a holder runs that the core never recorded are killed and
    released.
- `hc update` swaps the binary (staged beside the old one, checked with
  `--version`, renamed into place), then calls `server.restart`; the terminals
  keep running (`cli/update.rs`).
- CI builds the previous release tag, starts terminals with it, updates to the
  tree under test, and checks that every terminal and machine survives
  (`scripts/upgrade-test.sh`, `tests/upgrade.rs`).
- The holder binary itself is never replaced in place. A new build gets a new
  holder, and the old one drains.

### 3. Persistence and restore

**herdr (v1)** (`src/persist/`):

- **What is saved.** `session.json` (`snapshot.rs`): workspaces, tabs, the
  layout's binary split tree with ratios, focus and zoom, and per pane: cwd,
  label, agent name, an agent session ref (`{source, agent, kind: id|path,
  value}`), a resume argv the agent reported itself (#4687), and the launch
  argv.
- **Pane history.** An optional `session-history.json` holds ANSI scrollback
  per pane, bound to the layout by a `layout_fingerprint`. That binding came
  from #1156: the two files were written by separate renames, so a crash
  between them restored history under the wrong pane. #4400 made replay
  happen only on an exact layout match.
- **Cadence.** Saves are debounced 5 s (`app/mod.rs:44`) and run on a
  background thread.
- **Atomic writes.** Write a tmp file, `sync_all`, rename, then fsync the
  parent directory (`persist/io.rs:50-67`).
- **Recovery copies.** `session-backups/` keeps 3 copies, taken before the
  first overwrite of a file this run never loaded
  (`preserve_existing`, `writer.rs:122`). `session-snapshots/` keeps 48
  layout-only copies, at most one per 15 minutes, deduplicated by layout
  fingerprint (`writer.rs:78-79`). Recovery from them is manual.
- **Pane-exit checkpoint** (#3418). When panes die from a signal, the layout
  is saved *before* the panes are removed, and the following autosave keeps
  that checkpoint. A SIGHUP storm (terminal quit, server death) therefore
  cannot persist an emptied layout. On Linux, logind shutdown inhibitors
  give the same protection at shutdown (#4400).
- **Restore.** A fresh shell in the saved cwd, or a visible error pane that
  keeps the saved metadata when the cwd or shell is gone. Agent resume
  *types* the resume command into that shell, which is why `resume_argv`
  must start with a bare command name and may not contain apostrophes
  (`agent_resume.rs:56-80`). Duplicate agent session IDs across panes are
  deduplicated. Restored agents start 100 ms apart (#4102: restoring 25 or
  more agents at once starved the CPU, and MCP connections timed out).

**herdr-core:**

- `terminals.json` holds the registry (written with `save_soon`, debounced).
- Screen snapshots are written at planned restart and when a terminal
  finishes, so `hc read` works after exit.
- `--keep` terminals that are lost (holder gone, reboot) restart as a **fresh
  shell, never the task**, in the last cwd. Retries back off from 1.5 s to
  60 s and reset only after a program stays up 10 s (`kept.rs:9`).
- A disk cloned from another machine is detected by machine ID, and its
  terminals and screens are forgotten (`server.rs`, `CLONE_FORGETS`).

### 4. Terminal engine

See section (c). In short: herdr replaced the `vt100` crate with libghostty-vt
on 2026-04-05. It vendors a source tarball and builds it with Zig in `build.rs`,
keeps five local patches, and has bumped the vendored source four times. Herdr 2
(core and app) uses an **unpatched upstream submodule**.

### 5. Render protocol to clients

**herdr (v1).** The server owns the emulators and renders a semantic grid
(`PaneSurfaceFrame` cells) or ANSI diffs (`BlitEncoder`, `protocol/render_ansi.rs`,
wrapped in synchronized output, DEC 2026) per client. Three negotiated codecs
sit on top. Each falls back to the plain frame, and each is frozen by message
kind:

- **`surface_reuse`** (#4137) keeps cells when only metadata changed. 10 Hz
  title updates at 240×100 over SSH fell from 3.61 MB/s to 38 KB/s.
- **`surface_delta`** (#4209) sends sparse changed cell spans, and aborts to a
  full frame once the delta's lower bound reaches the full size
  (`protocol/surface_delta.rs:65-105`). A 120×40 popup over a 250 kb/s link
  fell from 35,553 to 494 bytes per update, and p95 latency from 306 to 97 ms.
  It costs 26–31% more encode CPU on checkerboard damage.
- **`surface_scroll`** (#4711) sends one vertical shift per pane plus only the
  rows that still differ, and is used only when it at least halves the
  patched cells. Over SSH at 320×85 with about 100 lines/s, traffic fell from
  1,278 KB/s to 59 KB/s.
- Moving chrome rendering into the client (#3487) cut 61–83% of total CPU on
  visible workloads.

Their method is useful: matched release builds, recorded agent output replayed
at identical timing into both builds, all final client grids compared, and
`just bench-render-scale` at 1 and 15 panes. AGENTS.md makes the scaling delta
mandatory for any change to a "multiplicative path".

**herdr-core.** A viewer's attach stream is a **first paint** (the current
screen as VT, optional history, the latest status and title), then raw program
bytes with the queries the core already answered stripped out
(`relay.rs:1-6`), so the viewer does not answer them a second time. Flow
control is credit-based: 256 KiB initial credit, and a viewer more than 4 MiB
behind gets a fresh repaint instead of the backlog (`schema/README.md`). The
last *active* viewer sets the size. herdr-app feeds those bytes into its own
libghostty-vt and draws with GPUI from the `render_state` dirty-row API
(`herdr-app/src/vt.rs`, `src/terminal.rs`, about 3,750 lines together).

### 6. Remote machines

- **herdr (v1)** (`src/remote/`, #3670) mirrors a remote server over SSH, using
  the same endpoint protocol (generation 1, frozen codecs).
  - Saved machines use strict host-key checking.
  - `restart_policy.rs` decides whether the remote server must restart
    (endpoint generation mismatch, a missing capability, a failed health
    check, not running as a daemon) and whether that can be a live handoff.
    Replacing a remote server asks before stopping its panes, defaulting to No
    (#3509).
  - **SSH agent forwarding.** Each attachment registers its `SSH_AUTH_SOCK`
    with the long-lived server (`server.ssh_agent.register`). Panes see a
    stable `<api socket>.agent` symlink that the server points at the newest
    live agent (`src/platform/ssh_agent.rs`).
  - High-latency handshakes (about 750 ms RTT) gave up on the first `EAGAIN`
    (#752, #753). Connections recover promptly after wake (#5249).
- **herdr-core** (`docs/machines.md`): `hc machine add host` runs `ssh host hc
  connect`, which carries the same JSON-RPC and framed protocol over
  stdin/stdout.
  - The remote core owns its programs, history and files. The local core
    aggregates lists and events and retries lost connections.
  - `--via '<cmd>'` substitutes any transport that passes bytes unchanged
    (Fly, Vercel Sandbox).
  - Adding a machine copies `hc` over when it is missing or too old.
    `hc machine update` restarts the remote core with its terminals kept.
  - "Do not request a remote PTY", and the remote login must print nothing to
    stdout.

### 7. History, briefly

- 2026-04-04/05: the libghostty-vt backend lands and `vt100` is removed.
- 2026-04-21: #40, persistence, the server split (33.6k lines added).
- 2026-05-24: #248, pane screen history.
- 2026-06 to 2026-08: handoff fixes.
- 2026-09-01: #3487, the client renders the shell (114k lines changed).
- 2026-09-05: #3670, multiple SSH machines.
- 2026-09-10: #3906, the libghostty upgrade (109k lines added).
- 2026-09-14 to 2026-09-28: the surface codecs.
- 2026-10-15: #5236, the launchd coalition fix.
- 2026-10-23: herdr-core and herdr-app published. Their changelog says
  "herdr-core updates with Herdr … your terminals keep running".

---

## (b) Ranked ideas for TBD

### 1. Save detached screens on a planned daemon restart, and seed the successor from them

- **TBD now.** "A daemon restart starts the emulator empty"
  (`docs/specs/2026-08-30-pty-holder-session-transport-design.md:506`), and
  the emulator "is **not persisted** to disk" (`:471`). A TBD field
  measurement of holder re-adoption found that re-adoption issues no jiggle, a blank emulator recovers nothing, and
  `contentObserved` stays false. Every `tbd update` and `scripts/restart.sh`
  goes through `DaemonHandover`, so this is the most common restart there is,
  and each one blanks every detached session's screen and scrollback until
  the program repaints. Shells never repaint.
- **herdr-core.** It treats a planned restart and a crash as different
  problems. A planned restart writes exact snapshots and marks the boundary.
  A crash replays a raw tail and labels the screen inexact
  (`runtime.rs:367-434`, `751-768`; `holder.rs:239`).
- **Why it fits TBD better than it fits herdr-core.**
  - TBD needs no tail. Between the old daemon releasing a reader and the
    successor taking it, nobody reads the PTY, so the kernel's tty buffer
    holds exactly "what follows". A program that fills the buffer blocks,
    which is fine for a handover lasting seconds.
  - TBD already has the serializer: `TerminalSnapshotWriter` writes the attach
    preamble, and every attach exercises it. Writing that preamble per session
    at `stop()` and ingesting it before the first drain would make planned
    restarts exact.
  - TBD's VT-preamble format is **better** than herdr-core's choice.
    herdr-core's native libghostty snapshot "doesn't decode (e.g. another
    Ghostty version)" (`ghostty-vt/src/lib.rs:696`), so an update that bumps
    the Ghostty pin degrades to an inexact screen exactly when it matters.
    A VT stream survives SwiftTerm upgrades.
- **Hazards to design for.**
  - **Read each snapshot once.** Delete or rename the file before decoding
    it. herdr#453 records a crash that "could … crash again after restore if
    the same saved pane output was replayed".
  - **Persist only sessions the daemon was reading.** An attached session's
    daemon emulator is frozen at attach time, and persisting it would bring
    back a stale screen as current. Skip those, or label them stale.
  - **Bound the size.** The ceiling is 5,000 lines per session (about 5 MB)
    across about 150 sessions.
  - **Record provenance.** "Restored from planned-restart snapshot" is a third
    value beside today's `contentObserved`, matching herdr-core's
    exact/inexact.
  - **Get a spec first.** This revises a stated design decision, so it starts
    with `/tbd-brainstorming`.

### 2. Find out whether TBD's holders and agents live in a terminal's, or TBD.app's, launchd coalition

- **TBD now.**
  - `scripts/restart-bundle-lib.sh:1011` launches the successor daemon as
    `TBD_HANDOVER_FROM_PID=… "$daemon_bin" … &` from whatever shell runs
    `restart.sh` or `tbd update`.
  - The app launches it as a Foundation `Process`
    (`Sources/TBDApp/DaemonClient.swift:246-262`).
  - Holders are `posix_spawn`ed and call `setsid`
    (`Sources/TBDHolder/Holder.swift:94`).

  Nothing in TBD leaves a coalition: `grep coalition|launchctl submit` finds
  nothing.
- **herdr's evidence** (#4920, two independent reproductions with signal
  tracing):
  - Coalition membership survives fork, `setsid` and double fork.
  - `launchctl submit` and `launchctl bootstrap` *from inside the terminal*
    stay attributed to the same coalition.
  - On Ghostty's fast Cmd-Q path, loginwindow logs `quitOrKillSubordinateProcesses`
    and launchd sends SIGTERM to everything in the coalition. A daemon at
    ppid 1 with `TTY=??` still died.
  - The maintainer could reproduce it only with force quit, so it depends on
    the quit path.
  - The fix that shipped is #5236: a one-shot job in `gui/<uid>` that forks
    out and exits.
- **Why this could matter more for TBD than for herdr.** SIGTERM reaches every
  process in the coalition, so the agents are killed **directly**. The holder
  surviving would not save them.
  - If the daemon was last started by `restart.sh` in Ghostty or iTerm, every
    session started since may share that terminal's coalition.
  - If the app launched it, every session shares TBD.app's coalition, and
    force-quitting TBD.app may end every agent.
- **Status.** Unverified for TBD, and cheap to check. Inspect a holder's
  coalition and responsible pid (`launchctl procinfo <pid>`, which may need
  root). Then repeat herdr's experiment: start the daemon through `restart.sh`
  in a throwaway Ghostty window, Cmd-Q or force-quit that window, and see
  whether agents receive SIGTERM.
- **This belongs with #1228**, the inherited QoS clamp TBD already fixed. The
  launching context's QoS, coalition, responsible process and bootstrap
  namespace all flow down to every agent. herdr's plist also sets
  `ProcessType=Interactive` for the same scheduling reason.

### 3. Check Local Network and TCC responsibility for agents in TBD sessions

- **herdr's evidence** (#808, still open, many reproductions):
  - macOS Local Network Privacy and TCC bind consent to the **responsible
    process** fixed at spawn.
  - Under a detached server with no grantable identity, non-Apple binaries in
    panes (Homebrew or nix `python3`, `node`, `bun`, `kubectl`, an ad-hoc
    signed copy) get `EHOSTUNREACH` to LAN hosts at once. Apple binaries
    (`/usr/bin/curl`, `/usr/bin/python3`) are exempt and pass.
  - It is triggered by a handoff, a remote attach that replaced the server, or
    any detached daemon.
  - The workaround that worked was to start the server from a small `.app`
    bundle and grant that app Local Network access. One reporter found that
    **ad-hoc re-signing the bundle invalidated a grant**.
  - herdr's own launchd fix warns that "privacy (TCC) prompts may now name
    herdr instead of the terminal": leaving the coalition this way also gives
    up the terminal's identity.
- **TBD now.** The responsible process for a session depends on how its daemon
  started: TBD.app, a terminal running `restart.sh`, or an agent inside a TBD
  terminal. `restart.sh` reassembles and re-signs `TBD.app` on every run.
  Agents in TBD routinely run Node binaries and MCP servers, some of which
  reach LAN hosts.
- **Suggestion.** First test non-Apple LAN reachability from a TBD terminal
  under each launch path. If any path fails, the coherent fix for 2 and 3
  together is a daemon launched by launchd from a program **inside the signed
  TBD.app bundle**. That gives:
  - its own coalition;
  - a responsible identity that can hold grants;
  - a home for crash restart (idea 5);
  - no inherited QoS.

  It conflicts with today's per-worktree daemon binaries and the
  pid-file handover, so it needs a spec.

### 4. Freeze the holder protocol's wire bytes, and test across builds

- **TBD now.** `Tests/TBDSharedTests/HolderProtocolTests.swift:25,36` only
  round-trip encode → decode with the same code on both sides. The spec
  requires the daemon to "interoperate with every holder version that has ever
  shipped". A renamed `HolderResponse` case or associated-value label, or a
  reordered `HolderChildStatus`, would pass these tests and break every
  long-lived session. Swift's synthesized enum `Codable` (`{"described":{"_0":…}}`)
  is especially easy to change by accident.
- **herdr.**
  - AGENTS.md: "Named core codecs are immutable … Frozen endpoint fixtures,
    bincode digests, wire-tag tests, and `endpoint-method-shapes-v1.json` are
    compatibility contracts. Never update a generation-1 expectation merely to
    [accept] a wire change."
  - Also: "Existing-value digests cannot detect an appended enum variant.
    Review every enum reachable from a frozen codec as append-closed."
  - herdr-core keeps `released.openrpc.json` with a test that fails on any
    breaking change, plus the previous-release upgrade test.
- **For TBD.** Commit literal v1 JSON for every request and response and assert
  both decode and byte-equal encode. Add a live test that spawns a `TBDHolder`
  built from an older commit and re-adopts it with the current daemon. Small,
  and it directly protects the holder design's hardest invariant.

### 5. A crashed daemon with the app closed leaves detached sessions stalled indefinitely

- **TBD now.** Holders never read. Only the daemon drains detached sessions,
  and only TBDApp relaunches a dead daemon. The spec accepts stalls as "visible
  and recoverable", but with the app closed nothing recovers them: agents
  block on a full tty buffer, and jobs that finish cannot complete their exit.
- **herdr-core.** The holder restarts a crashed core with backoff
  (`holder.rs:368`), and the holder always reads, so programs never stall
  anyway.
- **For TBD.** Restarting the daemon from the holder conflicts with TBD's rule
  that the holder stays near-featureless and frozen, and it would put the
  daemon under a holder's launch context. TBD's design is right to refuse
  that. The better home is launchd `KeepAlive`, which comes free with idea 3's
  launch agent. Without that, the gap should at least be stated in the spec.

### 6. Reap escaped descendants by an environment token, and re-test macOS's environment visibility

- **herdr-core** (`sweep.rs`). Each terminal's environment carries
  `HC_SCOPE=<mach_absolute_time>-<random>` (`:16`). Descendants inherit it even
  after leaving the session ("agents' tool shells do").
  - A sweep lists processes with `proc_listallpids`, skips any process that
    started before the token's timestamp, and reads each remaining
    environment through KERN_PROCARGS2. It adds the descendants of every match,
    because "macOS hides the environment of its own binaries (an agent's
    `/bin/bash` tool shell), but not their parents". It then sends SIGHUP,
    SIGTERM and SIGKILL, re-scanning before each one (`:75`).
  - The holder sweeps when a program exits, and the core sweeps the leftovers
    of lost holders at startup.
  - The test comment reads "Not macOS's own `sleep`: it hides its environment"
    (`:189`).
- **TBD now.** The escaped-process problem is documented
  (`docs/specs/2026-08-18-orphan-process-gc-design.md`: `& disown` and
  `nohup` survive). Several TBD docs and comments conclude that a pane
  process's environment cannot be read on macOS. **That was measured with
  `/bin/sleep`, an Apple platform binary** — the one class herdr-core says
  hides its environment.
- **Re-measured.** [`identity.md`](identity.md) section (b) shows `claude`,
  `node` and `pnpm` are readable, while Apple binaries and a few non-Apple
  apps are not. So a per-session token can be a stronger identity than cwd or
  pgid closure for `AgentReaper`. The stated limit: a process that
  both leaves the session and drops its environment escapes.

### 7. Use the host-shutdown signal to tell "lost to reboot" from "exited"

- **herdr.** herdr-core and herdr both watch loginwindow's restart, shutdown
  and logout notify keys and, past the point of no return, stop recording
  pane deaths as exits (herdr-core `platform/macos_shutdown.rs`, herdr #4400).
- **TBD now.** A grep for `shutdownInitiated`, `willPowerOff` and `notify_register`
  in `Sources` finds nothing. Reboot recovery goes through hibernation and
  wake. A distinct exit reason would let revive or resume logic act on it
  rather than infer it. Medium-low priority.

### 8. Jiggle by shrinking rows

- **TBD now.** `HolderReader.jiggle()` grows by one column
  (`Sources/TBDDaemon/Holder/HolderReader.swift:755`). A TBD field
  measurement of holder re-adoption found grow-by-one "transiently corrupt"
  and recommended shrinking.
- **herdr.** Both products shrink: herdr by rows − 1 with a 30 ms sleep
  (`pty/actor/unix.rs:983-1025`), herdr-core by rows − 1 with 50 ms
  (`runtime.rs:448-457`). herdr-core nudges only when the screen is inexact,
  never after an exact restore. That supports idea 1: jiggle on re-adoption
  only when no snapshot was restored.

### 9. Smaller items worth knowing, mostly no action

- **Query replies on replay.** If TBD ever replays raw bytes, replies are
  correct only for bytes nobody answered: send them after a planned boundary,
  drop them after a crash (herdr-core `runtime.rs:404-410`). A VT snapshot
  preamble contains no queries, so idea 1 is unaffected.
- **Quiesce before switching writers.** herdr waits for an in-flight
  "text, delay, then Enter" submission and flushes queued input before it
  stops a reader (`pty/actor/unix.rs:725-790`). It is worth checking that
  TBD's daemon `stop()` cannot cut a queued prompt between its text and its
  Enter. This report did not verify it either way.
- **Stagger mass agent restarts.** Restoring 25 or more agents at once
  starved the CPU and timed out MCP connections (#4102). TBD wakes worktrees
  lazily, so this probably does not apply, unless a reboot path wakes many
  at once.
- **Pane-exit checkpoint** (#3418). Never persist a layout shrunk by a death
  storm. TBD keeps its rows in SQLite, so the risk is smaller, but any code
  that deletes terminal rows on exit should not run in bulk during a
  coalition kill or a reboot.

### Where TBD's design is already better: don't adopt

- **A holder per session, not a server or a holder per build.** In herdr, one
  bad byte sequence or one leak ends every pane: #2850, #3527, #4958, and the
  libghostty crashes in (c). herdr-core moved toward TBD's shape but still has
  one holder per build. TBD's blast radius is one session.
- **The attached path.** herdr v1 parses everything in the server and
  re-renders it per client: typing echo went from 1.65 ms to 85.9 ms p50 with
  a busy neighbour (#2890). herdr-core relays every byte holder → core →
  viewer, and every keystroke back. TBD's viewer reads and writes the master
  directly: zero extra processes per keystroke. The price is real, and the
  spec pays it: reader arbitration, the two-store model, the handback. herdr-core
  avoids all of that by having the holder always read.
- **No fds move between daemons.** herdr v1's live handoff is a 30 s
  multi-step protocol with rollback at every step, 64-fd batches and a long
  list of defects (see 2). It also loses exit status, because the successor
  is not the children's parent. TBD's holders stay put and stay the parent,
  and `DaemonHandover` is a pid-file takeover. Simpler and stronger. The one
  thing herdr-core does better, saving screens, is idea 1.
- **Screen scraping.** herdr detects agent state from the screen
  (`src/detect/manifests/`), and `herdr-core/src/stitch.rs` reads a full-screen
  app's history by scrolling it and gluing the pages together. TBD bans both.
  herdr-core itself took status off the screen: "Status comes from the
  program … OSC 7501 … It does not guess from screen text" (README).
- **The surface codecs** (`surface_delta`, `surface_reuse`, `surface_scroll`)
  solve server-side rendering over SSH. TBD's local raw-PTY path has no such
  stream. They become relevant only if TBD streams screens to remote viewers.
  The measurement method (matched builds, replayed recordings, grid diffs) is
  still worth copying.
- **Remote machines over SSH.** TBD has no SSH host model; its "remote
  sessions" are Claude Code cloud sessions. If TBD ever adds hosts,
  herdr-core's shape is the template: the same protocol over
  `ssh host hc connect` on stdio, the remote daemon owning its processes, the
  local daemon aggregating. So is herdr's stable `SSH_AUTH_SOCK` symlink.

---

## (c) Evidence for TBD's libghostty decision

These are facts from herdr, herdr-core and herdr-app, with the TBD reading of
each.

- **Adoption timeline.** herdr built the libghostty-vt backend in late March
  2026 and made it the default on 2026-04-05, removing `vt100` (`b2e6929a`).
  It is a production `libghostty-vt` embedder with about six months in the
  field.
- **How herdr v1 builds it.** It vendors a source tarball
  (`vendor/libghostty-vt.vendor.json`: `libghostty-vt-1.3.2-HEAD-+44f2a44df`).
  `crates/ghostty-vt/build.rs` shells out to `zig build -Demit-lib-vt` (Zig
  0.16.0 is now required) and links statically. On Apple targets it copies
  `libghostty-vt.a` into a separate directory, because "Apple's linker prefers
  the sibling dylib". The binding layer is large: `lib.rs` is 178 KB and the
  generated `bindings.rs` is 465 KB.
- **Version churn.** The vendored source was bumped on 2026-05-07, 06-01,
  07-16 and 09-10. #3906 (2026-09-10) moved from `c5a21edf` to `44f2a44d` and
  Zig from 0.15.2 to 0.16.0. Its changes in brief:
  - It had to "adapt the changed constructor, mode, clipboard,
    temporary-file and render-color APIs; regenerate the C bindings".
  - It added 109,185 lines. Both review bots refused it (651 files against a
    500-file limit).
  - It measured "no blanket speedup": CPU moved from 1.10% to 1.20% and from
    3.00% to 2.77% on recorded agent output.
  - Its validation method was to replay recorded sessions into both builds
    and check that "all replayed final client grids matched". That is the
    "one check worth running sooner" in TBD's libghostty record.
- **Local patches that are still needed** (`vendor/libghostty-vt.patches.md`),
  each recording its reason and removal condition:
  - 0002, a modifyOtherKeys scalar query. Herdr's local enum value collided
    with one upstream later claimed.
  - 0004, Wuffs hosted builds. Allocator stubs "override the Rust
    executable's libc allocator, causing immediate allocation failures".
  - 0005, bounded wrap-aware word selection.
  - 0006, clear the screen while preserving the cursor line.
  - 0007, experimental PNG retention.
  - 0008, a **crash fix**: a cursor move carrying a hyperlink onto a full page
    "dereferences null and the server dies". The patch notes say it was
    "still present on upstream main … at 22fa134a0" on 2026-10-15
    (#5296/#5303).
- **Crashes attributed to libghostty, each fatal to every pane in herdr's
  single server:**
  - #453: SIGSEGV on emoji output, from a newly adopted upstream API that was
    then reverted.
  - #465: SIGABRT `integerOverflow` in `PageList.resizeCols` on resize. It
    needed a backport (`648afa1f`).
  - #276: invalid free while streaming frames, fixed by a vendor update.
  - `3cbe4ec7`: a UTF-8 grapheme buffer crash.
  - #5296: the hyperlink and page-replace crash above.
  - Under TBD's architecture an engine crash would take down the daemon or the
    app, not the sessions, because the holders keep the PTYs. TBD contains
    engine defects better than herdr does.
- **Build traps.**
  - A Release build in the Nix shell linked a Debug libghostty, and "every
    terminal resize freezes the server for seconds" (#3596).
  - Zig builds for the host CPU's newest instructions unless given
    `-Dcpu=baseline`, which "crash older CPUs" (herdr-core `ghostty-vt/build.rs`,
    herdr-app `ghostty-sys/build.rs`).
  - Windows needed extra libc plumbing (#1852).
  - None of these bite TBD's arm64-only xcframework route, but they show the
    cost of building from source.
- **The encoders count in its favour.** herdr #5017 moved all key encoding
  onto libghostty's encoder: "Most of our input bugs came from the gaps
  between those paths", and seven input issues were fixed and checked against
  real kitty, Ghostty, WezTerm and Alacritty. If TBD reopens the question,
  libghostty's key and mouse encoders are an argument independent of
  rendering.
- **Herdr 2 runs unpatched.** herdr-core and herdr-app, published 2026-10-23,
  use upstream `ghostty-org/ghostty` as a git submodule with no patches:
  - herdr-core is pinned to `1e5cdb865` (2026-10-11), with a 911-line
    hand-written binding.
  - herdr-app is pinned to `291fd050b` (2026-10-14), with a binding generated
    by `bindgen`.

  The same maintainer who needed five patches in v1 needed none in v2.
  That is evidence the C API reached embedding-complete in October 2026,
  still before 1.0.
- **Two emulators, both libghostty.** herdr-app runs a libghostty-vt instance
  per pane fed the core's relayed bytes, while the core runs its own headless
  instance. That is TBD's two-emulator shape. It supports TBD's rule that the
  engine changes on both sides or neither.
- **Renderer cost, one data point.** herdr-app draws with GPUI from
  libghostty-vt's `render_state` API (dirty-row iteration). Its whole view
  (`vt.rs` plus `terminal.rs`) is about 3,750 lines of Rust, with GPUI doing
  text shaping and the GPU work. There is still no Swift renderer: Herdr is
  all Rust, and nothing here moves TBD's second trigger.
- **The snapshot API exists but does not cross versions.** herdr-core uses
  `ghostty_snapshot_encode_alloc` and `ghostty_snapshot_decoder_*` for
  planned-restart screens, and returns `None` on a version mismatch. herdr v1
  "deliberately" did not adopt snapshot persistence in #3906. For TBD, the
  native snapshot is not a replacement for a VT preamble across upgrades.

**Net reading.** herdr does not change TBD's "not yet". Through 2026 it shows
real churn — four bumps, one ABI-adapting 109k-line upgrade, five patches, five
crash classes — while the October 2026 v2 products show an unpatched upstream
being usable. That fits TBD's 1.0 trigger. On the cost of a renderer it is
silent for Swift.

---

## (d) Notable issues and PRs

- **Launchd coalition kill and fix:** herdr#4920, herdrdev/herdr#5236.
- **TCC and Local Network responsibility:** herdr#807, herdr#808 (open, with
  measurements and the `.app` workaround), herdrdev/herdr#4202 (bootstrap
  context across logout, changelog #4100).
- **Handoff losing screens:** herdr#3864 (open), herdr#2644, herdr#5291,
  herdr#5443, herdr#4972, herdr#3393, herdr#516, herdr#4397.
- **Blast radius of one server:** herdr#2850, herdr#3527, herdrdev/herdr#4958,
  herdr#2890 (latency measurements).
- **Persistence races and hardening:** herdr#1156, herdrdev/herdr#3418,
  herdrdev/herdr#4400, herdr#4102.
- **libghostty:** herdrdev/herdr#3906, herdr#453, herdr#465, herdr#276,
  herdr#5296 / herdrdev/herdr#5303, herdr#3596, herdrdev/herdr#5017.
- **Render protocol:** herdrdev/herdr#3487, herdrdev/herdr#4137,
  herdrdev/herdr#4209, herdrdev/herdr#4711, herdrdev/herdr#3509 (stable
  endpoint generation 1).
- **Files to read first if picking up an idea:**
  - Idea 1: `herdr-core/crates/herdr-core/src/runtime.rs:367-457, 751-768` and
    `holder.rs:200-260`.
  - Idea 2: `herdr/src/platform/macos/launchd_spawn.rs`.
  - Idea 4: `herdr/AGENTS.md`, section "Stable client endpoint contract", and
    `herdr-core/scripts/upgrade-test.sh`.
  - Idea 6: `herdr-core/crates/herdr-core/src/sweep.rs`.
  - Idea 7: `herdr-core/crates/herdr-core/src/platform/macos_shutdown.rs`.
