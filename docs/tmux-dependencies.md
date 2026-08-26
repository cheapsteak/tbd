# TBD's tmux dependencies

Status of this document: an **inventory of a moving target**, derived by reading
the tree on 2026-08-26. It answers three questions nobody had written down —
what invokes tmux, which user-visible capability each invocation backs, and what
would break without it. Every claim is cited to `file:line` in this worktree. If
the code and this document disagree, the code wins; then fix the document.

It is an inventory, not a proposal. It does not argue for or against any change
to how terminals are driven.

Two moving parts make the snapshot date load-bearing. The control-mode subsystem
under `Sources/TBDDaemon/Tmux/ControlMode/` is built but shipped off, so half the
surface below is code that exists and does not run. And the fleet-supervision
subsystem is being replaced (root `CLAUDE.md`, "Nightwatch is being replaced"),
so some of what is inventoried here is scheduled to be deleted rather than
maintained.

## How to read this

**Two live paths.** Every dependency below is tagged with the path it belongs
to.

- **Default path** — the app owns a pty running `tmux attach`, hand-copies the
  bytes into SwiftTerm, and the daemon reaches tmux by spawning
  `tmux -L <server> …` subprocesses. This is what runs today.
- **Control-mode path** — the daemon holds one long-lived `tmux -CC attach`
  connection per server, and the app renders bytes vended over a file
  descriptor instead of owning a pty. Built, gated off. The shipped default
  is `false` (`ConfigStore.swift:143`), the gate additionally requires
  tmux ≥ 3.2 (`ControlModeGate.swift:28-36`), and both the daemon
  (`Daemon.swift:557`) and the app (`TerminalPanelView.swift:299`) read the
  same flag. A dependency that exists only on this path is inert in every
  install that has not opted in.
- **Both** — a dependency the two paths share.

**Five seams reach tmux.** Nothing else in `Sources/` spawns it.

- **`TmuxManager`** (`Sources/TBDDaemon/Tmux/TmuxManager.swift`) — the daemon's
  plain-subprocess seam. Static functions build argv; `runTmux` (`:1223`) execs
  through a bounded runner. Everything daemon-side goes through here.
- **`TmuxBridge`** (`Sources/TBDApp/Terminal/TmuxBridge.swift`) — the app's
  plain-subprocess seam, used only to set up and tear down the per-panel viewer
  session (`runTmux`, `:483`).
- **The viewer pty** — `TerminalPanelView.swift:724-729` spawns
  `tmux -u -L <server> attach -t <view-session>`
  (`TmuxBridge.viewerAttachCommand`, `:161-167`) under SwiftTerm's
  `LocalProcess`. This is the one invocation that is a long-lived process rather
  than a command.
- **`TmuxControlConnection`** (`ControlMode/TmuxControlConnection.swift:76`) —
  `tmux -L <server> -CC attach -t main`, one per server. Control-mode only;
  every control-mode command below rides this connection as command text rather
  than as a subprocess.
- **Seeded user-land Python** — the supervision tick script embedded in
  `Sources/TBDShared/NightwatchSkillContent.swift:954` shells out to
  `tmux -L <srv> capture-pane -p -e -t <pane>` itself, outside every seam above.

Plus one binary-location concern: `TmuxExecutableResolver`
(`Sources/TBDShared/TmuxExecutableResolver.swift`) finds tmux on `PATH` or falls
back to a saved path, and `TmuxVersion.detect` (`ControlMode/TmuxVersion.swift:53-72`)
runs `tmux -V` once at daemon start to decide whether the control-mode gate may
open. When resolution fails the app raises a "tmux Not Found" prompt
(`ContentView.swift:331-365`) and terminals do not work at all.

**Nothing in `Sources/TBDCLI` invokes tmux.** The CLI reaches the daemon over
the RPC socket, and the daemon does the tmux work. That is a load-bearing fact
for two of the questions below, so it is stated plainly rather than left implied.

## The inventory, by capability

### Making a session exist

- **`new-session`** — `TmuxManager.newServerCommand` (`:274-291`) issues
  `set-option -g history-limit 50000 ; new-session -d -s <session> -c <cwd>
  [-x N -y M] -PF '#{window_id}'` as one command list, so window 0 inherits the
  full history ceiling. Path: **both**. Called by `ensureServer` (`:737`), whose
  callers are worktree creation (`WorktreeLifecycle+Create.swift:1298`), the
  pre-session hook spawn (`WorktreeLifecycle+PreSession.swift:153`), terminal
  creation and every respawn-adjacent handler
  (`RPCRouter+TerminalHandlers.swift:233, 454, 963, 1180, 1275, 1928`), the
  "continue in Codex" handler (`RPCRouter+ContinueInCodexHandlers.swift:125`),
  and the hibernation wake path (`HibernationCoordinator.swift:913`).
  Capability: a worktree gets a terminal at all.
- **`has-session`** — `hasSessionCommand` (`:309-311`), the existence check
  `ensureServer` runs first so it does not recreate a live server. Path: **both**.
- **`new-window`** — `newWindowCommand` (`:389-434`):
  `new-window -t <session> -c <cwd> [-e KEY=VALUE …] -PF '#{window_id} #{pane_id}'
  <shell> -i -l -c <command>`. Path: **both**. `createWindow` (`:800`) is the
  single spawn primitive; its twelve call sites are the terminal-creation,
  revive, recreate, fork-swap, hook-terminal, Codex-continue and wake paths
  listed above. Capability: every agent and shell session TBD runs.
- **`respawn-window -k`** — `respawnWindowCommand` (`:453-467`), replacing a
  pane's program in place while keeping the window and pane ids. Path: **both**.
  Four callers: parking a session (`HibernationCoordinator.swift:414`), waking one
  (`:885`), the in-place model-profile swap
  (`RPCRouter+TerminalHandlers.swift:2040`), and window recreation (`:1217`).
  Capability: hibernate/wake and the seamless account switch keep the same tab.
- **Server-wide options** — `ensureServer` sets nine options on a
  freshly created server: `status off`, `pane-border-style`,
  `pane-border-indicators`, `default-terminal`, `mouse`, `xterm-keys`,
  `extended-keys`, `extended-keys-format kitty`
  (`TmuxManager.swift:762-776`), plus
  `set -ga terminal-features xterm-256color:hyperlinks` (`:305-307`, re-applied
  on every `ensureServer` at `:750` so servers predating the option get it).
  Path: **both**. Capability: no tmux chrome inside TBD's own UI, scroll-wheel
  scrollback, Shift+Enter reaching agent TUIs, and OSC 8 hyperlinks surviving to
  the viewer.

### Delivering environment into a session

- **`-e KEY=VALUE` flags** — `sensitiveEnvFlags` (`:333-341`), emitted by both
  spawn builders. Values land in the process environment *before* the shell's
  startup files run, and stay out of `ps aux`. Path: **both**.
- **`export KEY='value'; ` inlining** — `envExportPrefixed` (`:322-330`), the
  other half of the same mechanism, applied after startup files.
- **`setenv -g`** — `setGlobalEnv` (`:784-788`). Two uses: `SSH_AUTH_SOCK`
  pinned to a stable symlink at server creation (`:778`), and `COLORFGBG`
  pushed when the app's appearance changes
  (`RPCRouter+AppearanceHandlers.swift:39`). Path: **both**.

This is quieter than it looks and is easy to under-count. `TBD_TERMINAL_ID`
and `TBD_WORKTREE_ID` reach a session *only* through these two mechanisms, and
every Claude/Codex hook identifies itself by reading them back out of its own
environment — `SessionEventCommand.swift:37`, `SessionEndCommand.swift:21`,
`TerminalActivityEventCommand.swift:71`, `NotificationHookCommand.swift:84`,
`AskUserQuestionEventCommand.swift:43`, `NotifyCommand.swift:69`. The entire
hook rail — which is what supplies working/idle/awaiting-input state — rides on
tmux's environment plumbing.

### Typing into a session

- **`send-keys -l`** (literal text) — `sendKeysCommand` (`:487-489`). Path:
  **default**. Two callers: the rate-limit auto-continue rail
  (`LimitResumeActuator.swift:424`) and the auto-`/login` pump
  (`RPCRouter+TerminalHandlers.swift:535`).
- **`send-keys`** (key names) — `sendKeyCommand` (`:492-494`). Path: **default**.
  Callers: the auto-continue rail's Escape/Enter bracket
  (`LimitResumeActuator.swift:422, 426`), the graceful pane interrupt used before
  parking (`HibernationCoordinator.swift:1162-1166` and the twin at
  `RPCRouter+TerminalHandlers.swift:2103-2108`), the trailing Enter after a
  `terminal.send` paste (`:2392, 2405`) and after a verified re-delivery
  (`:2554`), the login pump's Enter (`:536`), and the supervision desk's nudge
  and wrap-up Enters (`DeskSessionManager.swift:565, 702`).
- **`send-keys … Enter`** (command form) — `sendCommandArgs` (`:727-729`), one
  caller: typing `/exit` when parking a Claude session politely
  (`HibernationCoordinator.swift:1129`).
- **`load-buffer` + `paste-buffer -d -p` + `delete-buffer`** — `pasteText`
  (`:950-996`), building on `loadBufferCommand` (`:498-500`),
  `pasteBufferCommand` (`:512-514`) and `deleteBufferCommand` (`:518-520`).
  Path: **default**. tmux is the sole bracketed-paste authority here: `-p` wraps
  the payload in `ESC[200~`/`ESC[201~` only if the pane enabled DECSET 2004, so
  the separate trailing Enter provably lands outside the paste. Callers: the
  `terminal.send` handler (`RPCRouter+TerminalHandlers.swift:2383`), verified
  re-delivery (`:2549`), and the supervision desk (`DeskSessionManager.swift:558,
  695`).

The ultimate consumers of the send capability are: the CLI (`tbd terminal send`,
`tbd terminal keys` — `TerminalCommands.swift:137, 167`), which is how one agent
session messages another (`docs/cross-session-messaging.md`); the app's own UI
send paths; the supervision desk's unattended nudges; and the rate-limit rail.

### Reading a pane's text

Four capture shapes exist. Under the "No TUI screen-scraping" rule, only two of
them classify what they read, and both are named exceptions.

- **`capture-pane -p`** — `capturePaneCommand` (`:526-528`). Path: **default**.
  Two callers, and they are on opposite sides of the rule. `handleTerminalOutput`
  (`:1324-1344`) passes the text through verbatim as the result of the
  `terminal.output` RPC, which is what `tbd terminal output` prints — sanctioned
  pass-through. The auto-`/login` pump (`:531`) feeds it to
  `LoginSessionCoordinator.classifyPane` (`:94`), which reads the rendered TUI to
  decide when Claude is ready for `/login` — **sanctioned scraper #1**, exempted
  in `.swiftlint.yml:327` because no machine interface exists before login.
- **`capture-pane -p -e -J`** — `capturePaneWithAnsiCommand` (`:531-533`). Path:
  **default**. One caller: `performHibernate`
  (`HibernationCoordinator.swift:375`), which uses it twice over. The capture is
  stored as the parked pane's display snapshot (verbatim), *and* it is fed to
  `HibernationSafetyChecks.hasPendingInput` (`:379`) — **sanctioned scraper #2**,
  exempted at `.swiftlint.yml:329`, the rail that refuses to park a session with
  unsent text in its composer. The `-e` is load-bearing: dimness is the only
  thing distinguishing a ghost suggestion from typed input.
- **`capture-pane -p -e -J -S -10000`** — `capturePaneScrollbackCommand`
  (`:541-546`). Path: **default**. Archival, verbatim, never parsed. Three
  callers, all snapshotting a pane into closed-terminal history immediately
  before its window dies: `captureThenKillWindow` (`WorktreeLifecycle.swift:252`),
  the hook-terminal close (`WorktreeLifecycle+PreSession.swift:462`), and
  `terminal.delete` (`RPCRouter+TerminalHandlers.swift:735`).
- **The supervision tick's own capture** — `NightwatchSkillContent.swift:954`
  runs `capture-pane -p -e` per fleet pane and regex-classifies the result.
  **Sanctioned scraper #3**, exempted at `.swiftlint.yml:332` with an explicit
  debt marker. Path: **default** (it shells out directly; control mode is
  irrelevant to it).

### Asking what is alive, and who it belongs to

This is the largest read surface and the one with the most consumers.

- **`list-sessions`** — `serverExists` (`:1192-1203`). Path: **both**. Callers:
  the reconcile sweep (`WorktreeLifecycle+Reconcile.swift:454, 572, 666`) and
  startup hibernation reconciliation (`HibernationCoordinator.swift:1095`).
- **`list-panes -t <window>`** — `windowExists` (`:1177-1189`). Path: **both**.
  Nine callers: the reconcile sweep (`Reconcile.swift:583, 669`), pre-session
  completion polling (`PreSession.swift:247`), wake (`HibernationCoordinator.swift:883`)
  and startup reconciliation (`:1098`), `terminal.delete` (`:700`), window
  recreation (`:1071`), the rate-limit rail's eligibility check
  (`LimitResumeActuator.swift:265`), and the supervision desk's live-terminal
  resolution (`DeskSessionManager.swift:299`).
- **`list-panes -F '#{pane_current_command}'`** — `paneCurrentCommandQuery`
  (`:552-554`). Path: **both**. Answers "is an agent in the foreground of this
  pane". Callers: reconcile (`Reconcile.swift:622`), hibernation's
  took-effect verification (`HibernationCoordinator.swift:468`), startup
  reconciliation (`:1102`), the polite-exit poll (`:1144`), and the supervision
  desk (`DeskSessionManager.swift:308`). The classification itself is
  `ClaudeStateDetector.isClaudeProcess` (`:10-12`), a version-string regex over
  the command name — a process fact, not screen text.
- **`list-panes -F '#{pane_pid}'`** — `panePIDQuery` (`:705-707`). Path: **both**.
  Callers: session-ID recapture (`ClaudeStateDetector.swift:69`), the rate-limit
  rail (`LimitResumeActuator.swift:317`), the two graceful-interrupt paths
  (`HibernationCoordinator.swift:1169`, `RPCRouter+TerminalHandlers.swift:2112`),
  and `killWindowAndReap` (`WorktreeLifecycle.swift:228`).
- **`list-panes -a -F '#{pane_pid}'`** — `listAllPanePIDsCommand` (`:722-724`),
  paired with **`display-message -p '#{pid}'`** (`serverPIDQuery`, `:718-720`).
  Path: **both**. One consumer, `AgentReaper` (`:37-39`, `:118`): everything
  whose parent is the tmux server but whose pid is not a live pane is a
  structural orphan and gets reaped. This is one of the three named reconcilers.
- **`list-panes -F '#{pane_current_path}'`** — `paneCurrentPathQuery`
  (`:709-712`). Path: **both**. One caller: wake asserts the pane's cwd matches
  the worktree before issuing a cwd-scoped `claude --resume`
  (`HibernationCoordinator.swift:637`).
- **`display-message -p '#{pane_in_mode}'`** — `paneInModeQuery` (`:714-716`).
  Path: **both**. One caller: the rate-limit rail refuses to type into a pane
  sitting in copy-mode (`LimitResumeActuator.swift:326`).
- **`list-windows -t <session> -F '#{window_id} #{pane_id}'`** —
  `listWindowsCommand` (`:522-524`). Path: **both**. One caller:
  `reconcileTmuxResources` (`Reconcile.swift:492`) kills every window on a
  server that no terminal row claims.
- **`list-panes -t <pane> -F '#{pane_id}\t#{pane_dead}\t#{@tbd_terminal_id}\t#{pane_start_command}'`**
  — `paneSendTargetQuery` (`:600-607`). Path: **both**. The single read that
  answers everything a send needs: does the pane exist, is its process alive, and
  which TBD terminal does the pane itself claim to be. Five callers, and they are
  the whole "do not type into a stranger" story: `terminal.send`'s pre-typing
  consultation (`RPCRouter+TerminalHandlers.swift:2456`), the reconcile sweep
  (`Reconcile.swift:589`), the wake path's disagreement check
  (`HibernationCoordinator.swift:561`), the rate-limit rail
  (`LimitResumeActuator.swift:358`), and the supervision desk
  (`DeskSessionManager.swift:352`).

### Pane identity

Its own section because it is the answer to one of the questions this document
was written for.

- **The stamp** — `set-option -p -t <target> @tbd_terminal_id <uuid>`
  (`setPaneTerminalIDCommand`, `:570-575`), written centrally by
  `stampTerminalID` (`:1086-1109`) from `createWindow` and `respawnWindow`, so
  every spawn path is covered by one rule. `@`-prefixed names are tmux's user
  namespace and the value dies with the pane — which is exactly what makes a
  *reused* pane id answer empty rather than with its predecessor's identity.
  Deliberately never backfilled from the DB (`:1075-1084`).
- **The fallback** — `resolvePaneTerminalID` (`:687-703`) reads the same UUID
  back out of `#{pane_start_command}`, anchored on the literal
  `export TBD_TERMINAL_ID='` that `envExportPrefixed` emits, and requires the
  extracted value to parse as a UUID. macOS forbids reading another process's
  environment under SIP, so the start command — not `ps eww` — is where the
  planted value stays legible.

**How widely identity is relied on.** Four places, at three layers.

- **The send path.** `terminal.send` consults the pane before typing and refuses
  on a positive disagreement (`RPCRouter+TerminalHandlers.swift:2456`). The
  fleet-supervision design states the reason as a requirement rather than a
  nicety: "pane IDs are reused, and keys sent to a stale coordinate land in a
  different live session … so target identity is verified by deliberate
  comparison before typing"
  (`docs/specs/2026-07-26-fleet-supervision-design.md:2762-2765`).
- **Reconciliation.** The sweep uses the same query to tell an owned dead pane
  (preserve) from a recycled coordinate now belonging to someone else (repair) —
  `Reconcile.swift:589`, and the `PaneSendTarget.dead(terminalID:)` doc comment
  at `TmuxManager.swift:13-17`.
- **The supervision desk.** `liveAgentTerminals` (`DeskSessionManager.swift:248-317`)
  documents the incident that forced it: one desk carried three terminal rows,
  both dead ones had been assigned `%1`, and a stale row started resolving to a
  live pane owned by an unrelated session — which would then have been pasted a
  judge prompt plus Enter.
- **Cross-session identification, outside TBD's own code.** TBD prints each
  terminal's tmux server, window and pane (`TerminalCommands.swift:61-62,
  114-115`), and the shipped skill content instructs an agent to recover a
  session whose display name has drifted by joining Claude's own peer-registry
  rows to TBD's rows on the tmux window and pane
  (`TBDSkillContent.swift:111, 122-123`; `docs/cross-session-messaging.md:169-178`).
  The pane is described there as "the field that ties a row to a specific
  directory" (`:93`).

The last of those is the widest claim and the least enforced: it is a documented
convention taught to agents, not a code path, so nothing breaks loudly if the
coordinate stops being printed — sessions simply become harder to identify. That
distinction is worth keeping.

### Sizing

- **`resize-window`** paired with **`set-option -wt <window> window-size latest`**
  — `resizeWindowCommand` (`:470-472`) and `setWindowSizeLatestCommand`
  (`:479-481`), always issued together by `resizeWindow` (`:901-915`). The
  pairing exists because `resize-window` implicitly pins the window to manual
  size mode, which would stop an attached client shrinking it back. Path:
  **default** (control mode has its own resize path). Callers: after every
  `createWindow` and `respawnWindow`, and `handleSetMainAreaSize` (`:2704-2733`),
  which broadcasts the app's main-area size across every window on active
  worktrees so detached panes do not sit at 80x24.
- **`set-option -wt <window> remain-on-exit on`** — `setRemainOnExitCommand`
  (`:548-550`). Path: **default**. Daemon-side caller: the auto-close hook spawn
  (`WorktreeLifecycle+Create.swift:1613`), which needs the pane to survive its
  process so teardown can capture the scrollback. The app sets the same option,
  plus `remain-on-exit-format ''`, on every viewer attach
  (`TmuxBridge.swift:108-114`, applied at `:262-292`) — that is what makes an
  exited pane keep its output instead of vanishing.

### Viewing (the app's attach path)

All **default path**, all in `TmuxBridge`, all in service of one capability:
showing a specific tmux window in a specific SwiftUI panel without letting
panels fight over the same client.

- **`kill-session`** (`:128-130`) — run first to clear a stale view session
  (`:202`), and again on panel teardown (`cleanupSession`, `:327`),
  server-wide teardown (`cleanupAllSessions`, `:346`), and every preparation
  failure (`:468`).
- **`new-session -d -s tbd-view-<8 hex> -c /tmp`** (`:92-94`) — the isolated
  per-panel session.
- **`link-window -s <windowID> -t <view>:`** (`:96-98`) — links only the
  requested window in.
- **`kill-window -t <view>:0`** (`:100-102`) — removes the placeholder window
  `new-session` created.
- **`select-window`** (`:104-106`) — makes the linked window active.
- **`display-message -p -t <view> '#{window_id}'`** (`:116-118`) — verifies the
  selection actually took before a pty is spawned.
- **`list-windows -a -F '#{window_id}'`** (`:120-122`) — the failure probe. Only
  a *successful* server-wide inventory that omits the requested window is
  treated as affirmative evidence the window is gone
  (`classifyPreparationFailure`, `:420-442`); that verdict is what triggers
  automatic terminal recreation.
- **`list-clients -F '#{client_session}'`** (`:124-126`) — the attachment
  confirmation (`hasAttachedClient`, `:406-418`). See the byte-stream section
  below: this is the one tmux call whose *trigger* is the app seeing bytes.
- **`tmux -u -L <server> attach -t <view>`** — the pty command itself
  (`:161-167`). `-u` is required even under a UTF-8 locale or tmux may classify
  the bare pty client as non-UTF-8 and mangle Unicode punctuation.

### Reclaiming what nobody owns

Three reconcilers, per the "Every durable external resource needs a named
reconciler" doctrine, and all three consume tmux.

- **`WorktreeLifecycle+Reconcile`** — the sweep that compares DB rows against
  reality. `kill-server` for a server no live row references
  (`:469`, via `killServer`, `TmuxManager.swift:791-799`); `kill-window` for
  untracked windows (`:492` onward); and the per-terminal liveness and identity
  checks at `:572-624`. Capability: orphaned worktrees, windows and servers stop
  accumulating after a crash or a cancelled create.
- **`AgentReaper`** — `serverPID` + `livePanePIDs` as described above.
- **`OrphanGC`** — does not invoke tmux; it reasons about worktrees, scratchpads
  and profile dirs on the filesystem (`OrphanGC.swift:673` only mentions tmux in
  passing).

`kill-window` itself (`killWindowCommand`, `:483-485`) has the widest call list
in the file — 27 sites across creation rollback, terminal delete, recreate,
fork-swap, hook-terminal close, scratch close, forget, wake failure, and the
supervision desk's close.

### Control-mode-only surface

Everything here is built and inert. Listed so the classification is complete,
not because it is currently load-bearing.

- **`tmux -CC attach -t main`** — `TmuxControlConnection.swift:76`, one
  long-lived connection per server, supervised by `TmuxControlSupervisor`.
- **`send-keys -H`** — `SendKeysEncoder.swift:33`, hex-encoded keystroke
  chunks, routed by `ControlModeInputRouter`.
- **`load-buffer` + `paste-buffer -d -p`** — `PasteExecutor.swift:62-65`, the
  control-mode twin of `TmuxManager.pasteText`.
- **Six-command capture batch** — `PaneCaptureReplay.captureCommands`
  (`:31-55`): four `capture-pane -peqJN` variants, a `list-panes -F`
  (`PaneStateCapture.swift:147`), and `capture-pane -p -P -C`. Used to rebuild a
  pane's exact display state on attach and on queue-overflow repair. This is
  capture-for-replay — bytes, never parsed for state.
- **`refresh-client -A '<pane>:pause'` / `:continue`** —
  `AttachReplayOrchestrator.swift:245, 312, 433` and
  `PaneRepairCoordinator.swift:164-165`, the flow-control primitive that makes
  the replay atomic.
- **`resize-window` + `list-windows -F` as an echo fence** —
  `ControlModeResizeCoordinator.swift:107-141`.

## Which capabilities exist only to serve supervision

The careful answer is **very few**, and none of the primitives.

Supervision is a heavy *user* of tmux, but almost everything it uses is
load-bearing elsewhere. `pasteText`, `sendKey`, `windowExists`,
`paneCurrentCommand`, `paneSendTarget` and `killWindow` are all reached by the
desk (`DeskSessionManager.swift:299, 308, 352, 558, 565, 695, 702, 782`) and all
also reached by `terminal.send`, the reconcile sweep, hibernation, or terminal
teardown. Retiring supervision would remove call sites, not capabilities.

What is **exclusively** supervision's:

- **The tick script's own `capture-pane -p -e`** (`NightwatchSkillContent.swift:954`)
  and the regex classifier it feeds. This is the only tmux invocation in the tree
  that exists solely to babysit the fleet, it is the only one that lives outside
  every seam, and it is one of the three sanctioned screen-scrapers. It goes when
  the tick script goes.
- **The desk's unattended paste-plus-Enter rail** — the *shape*, not the
  primitives. `nudgeDeskSession` and `postShiftWrapUp` paste and then send Enter
  unconditionally, with no composer check (`docs/nightwatch.md:213-215` records
  the 2026-07-25 incident where this spliced a nudge into the middle of a word a
  human was typing). The replacement design names this explicitly as work to
  close, by routing it through the same `terminal.send` actuation the public verb
  uses (`2026-07-26-fleet-supervision-design.md:878-895`) — so the outcome is one
  fewer *caller* of `pasteText`/`sendKey`, not one fewer capability.

And the direction the replacement is heading matters more than either. The new
supervision fact surface is specified to make **zero** tmux calls per agent:
"Per agent this costs at most what `session.states` already costs: database reads
plus byte-bounded transcript tails, and zero subprocesses, tmux calls, pane reads
and model calls. That is a constraint, not an aspiration"
(`SupervisionReadoutBuilder.swift:11-16`). `SessionStateResolver` refuses to add
a liveness probe for the same reason and takes liveness as an input instead
(`:233-248`).

But the replacement does **not** shed tmux. It still needs exactly two things
from it, both named in its own spec: pane and process liveness to identify gone
agents (`design.md:139-140`), and act-time pane liveness plus identity
verification on the send path (`design.md:2757-2766`). Those are
`paneSendTarget`, `windowExists` and `serverExists` — the queries the existing
send path and the reconcile sweep already depend on. So the honest summary is
that supervision's replacement retires supervision's *reads of the screen*, and
keeps supervision's *writes* and its liveness queries, both of which it shares
with paths that have nothing to do with supervision.

## What breaks if the app stops seeing the byte stream

The premise under test: if the emulator owned the pty and ran `tmux attach`
itself, so the app only rendered, what would stop working?

**The broad claim holds.** Every daemon-side dependency above is unaffected.
`TmuxManager` spawns `tmux -L <server> …` subprocesses that reach the tmux
server directly; the app is not in that path and never has been. `send-keys`,
`capture-pane`, `list-panes`, `list-windows`, `list-sessions`, the reconcilers,
the hook rail, `tbd terminal send` and `tbd terminal output` all continue to
work with no app involvement whatsoever. The CLI in particular never touches
tmux at all, so the entire cross-session-messaging surface is out of scope for
this question.

**Four app-side consumers do read or write the stream.** Three are real, one is
not what it looks like.

- **Interrupt detection — reads *outgoing* bytes, not incoming.**
  `handleOutgoingInput` (`TerminalPanelView.swift:1292-1305`) scans the
  keystroke chunk SwiftTerm hands back for `0x03` or a lone `0x1b` and calls
  `AppState.handleTerminalInterrupt` (`AppState+Terminals.swift:458-517`), which
  clears the agent's spinner locally and tells the daemon the interrupt origin.
  It is wired to run *first*, before routing, precisely so it survives whichever
  path the bytes then take (`:1272-1274`). This breaks under an
  emulator-owns-the-pty design not because the app stops seeing *output* but
  because it stops seeing *input* — the user's keystrokes would go emulator →
  pty without passing through TBD code. This is the clearest casualty and it is
  on the input side, which is worth stating because the question is usually
  framed around output.
- **Attachment confirmation — reads incoming bytes, but only as a trigger.**
  `dataReceived` (`:1247-1252`) calls `groupedViewerDidReceiveOutput` on every
  chunk; that method inspects no byte, and simply uses "output arrived" as the
  cue to run one `list-clients` probe (`:527-545`). A confirmed attachment
  resets the automatic terminal-recovery budget
  (`AppState+Terminals.swift:648-653`), which is what stops a genuinely broken
  terminal from being recreated forever. Two things follow. The dependency is on
  a *signal that something arrived*, not on the content, so almost any
  "the surface rendered" callback would substitute. And the retry arm already
  re-arms itself without waiting for another chunk (`:560-562`), specifically
  because an attached idle client may never emit one — so the mechanism is
  already half-independent of the stream.
- **The outgoing-input routing switch — control-mode only.**
  `OutgoingInputRoute.decide` (`OutgoingInputRoute.swift:18-20`) sends
  keystrokes to the local pty or to the framed sidecar depending on whether a
  control-mode attach is live, and `PasteInterception` does the same for pastes
  (`TerminalPanelView.swift:1040-1070`). Both are inert on the default path. But
  note the shape: control mode *already* took the pty away from the app, and had
  to reintroduce an input path (the sidecar) to get keystrokes back to tmux. Any
  design that hands the pty to the emulator faces the same problem in the same
  place.
- **Viewer environment and child reaping — not stream reads, but pty
  ownership.** The app scrubs `TMUX`/`TMUX_PANE` and pins
  `TERM=xterm-256color` before spawning the attach
  (`makeViewerEnvironment`, `:217-223`), supplies the window size from
  SwiftTerm's own cell metrics (`getWindowSize`, `:1254-1267`), writes a
  "[View detached]" notice into the view when the child exits
  (`:1216-1245`), and reaps the child through `ChildReaper`. None of these read
  bytes, but all of them presuppose that TBD owns the process. Any design that
  moves pty ownership must move these too, or find equivalents on the emulator's
  API — the environment override in particular is not optional, since an
  un-scrubbed `TMUX` makes the attach refuse to nest.

**What is not affected, contrary to a plausible guess:** activity tracking.
Agent working/idle/awaiting-input state comes from the Claude and Codex hook
rail — hook → `tbd` CLI → RPC → daemon (`TerminalActivityEventCommand.swift:10`
states it explicitly: state changes arrive "without the app scraping tmux pane
titles"). The app never derives activity from bytes.

## What breaks if tmux were removed entirely

Nobody proposes this. The value of the answer is that it names what tmux is
actually load-bearing for, which is more than the session-persistence story
usually told.

- **Session survival across app and daemon restarts.** The obvious one. The
  `main` session persists when the app closes (`TmuxBridge.swift:65`).
- **Detached execution.** A TBD session runs with no viewer attached at all —
  that is the normal state for most of a fleet. Without tmux there is no process
  to keep the pty alive between views.
- **Every actuation into a session.** `send-keys` and `paste-buffer` are how the
  daemon types. Without tmux, `tbd terminal send`, cross-session agent messaging,
  the rate-limit auto-continue, the auto-`/login` pump, the polite `/exit` before
  parking, and every supervision nudge lose their transport. There is no second
  path.
- **Bracketed-paste correctness.** tmux is the sole wrapping authority
  (`PasteInterception.swift:8-19`); `-p` wrapping is what keeps a trailing Enter
  outside the paste, which is what stopped large `--submit` messages being
  silently swallowed by a TUI's paste-burst coalescing.
- **Environment delivery, and therefore the whole hook rail.** As above:
  `TBD_TERMINAL_ID` reaches a session only through `-e` flags or the
  `export …;` prefix. Without that, no hook can identify which terminal it is
  firing for, and activity state, session events, notifications and
  ask-user-question events all lose their addressing.
- **Pane identity, and therefore the anti-misdelivery guarantee.**
  `@tbd_terminal_id` is a tmux pane option and `#{pane_start_command}` is a tmux
  format. Both disappear with tmux, and with them the only mechanism that stops
  a stale coordinate typing into a stranger's session.
- **Reconciliation's ground truth.** The reconcile sweep and `AgentReaper`
  compare DB rows against `list-sessions`, `list-panes` and `list-windows`.
  Remove tmux and there is no external system to reconcile *against* — the
  orphan-reclamation doctrine would need an entirely different ground truth.
- **Process-tree reclamation.** `AgentReaper` finds structural orphans by
  the tmux server being their parent (`:37-39`).
- **Scrollback for closed-terminal history and parked snapshots.**
  `capture-pane -S -10000` is where both come from.
- **Sizing detached panes.** `resize-window` is what stops a never-viewed
  terminal rendering into hard-wrapped 80x24 scrollback that cannot be reflowed
  when a wider view finally attaches.
- **The supervision tick's whole fleet read** — it enumerates panes from the DB
  and captures each one.

## Invocations with no live caller

None found. Every argv builder in `TmuxManager` and `TmuxBridge` traces to at
least one live call site, including the ones that look vestigial:
`deleteBufferCommand` fires only on the paste-failure branch (`:975-985`),
`windowInventoryQueryArgs` only on a preparation failure (`TmuxBridge.swift:455`),
and `terminalFeaturesHyperlinksCommand` runs on both the existing-session and
new-session branches of `ensureServer` (`:750`, `:769`).

Two things are worth flagging as *inert* rather than dead, which is a different
claim:

- **The entire `ControlMode/` tree.** Every type in it is referenced and
  compiles, and the wiring is live (`Daemon.swift:557`,
  `RPCRouter+AttachHandlers.swift:20`) — but the gate is shut by default, so in a
  stock install none of those tmux commands is ever issued. It is not dead code;
  it is code with no current runtime.
- **`newWindowCommand`'s `cols`/`rows` parameters** (`TmuxManager.swift:425-426`)
  are explicitly discarded — `new-window` does not accept `-x`/`-y`. The comment
  says callers still pass them. That is a dead *argument*, not a dead
  invocation, and removing it is a cleanup with no behavioral consequence.

## Where this inventory is uncertain

Stated so nobody reads more confidence into the above than it earns.

- **Whether `list-clients` attachment confirmation could be re-triggered without
  the byte stream** is a design question this document does not settle. What it
  establishes is that the trigger uses no byte content and that a
  content-independent retry arm already exists (`TerminalPanelView.swift:560-562`).
  What would settle it: check whether the retry arm alone reaches confirmation
  on a pane that never emits, which is testable today by suppressing the
  `dataReceived` call.
- **How widely the peer-registry pane join is actually used** cannot be
  established from this repository. It is documented instruction to agents
  (`TBDSkillContent.swift:122-123`), not a code path, so its usage lives in
  agent transcripts. What would settle it: sample real sessions for the join, or
  accept that it is a convention whose cost of loss is friction rather than
  breakage.
- **Whether the emulator-owns-the-pty design can preserve interrupt detection**
  depends entirely on whether the candidate engine exposes an outgoing-input
  hook. That is an engine-API question, not a tmux question, and this document
  deliberately does not answer it.
- **`ClaudeStateDetector.captureSessionID`** (`:67-95`) uses `panePID` and then
  falls back to `pgrep -P <pid> -x claude`. Whether that fallback still fires in
  practice — the doc comment says zsh usually execs into Claude directly, making
  `pane_pid` already the Claude process — is not established here. It is cheap
  and harmless either way, but it is a place where the code carries a branch
  nobody has confirmed is reached.
