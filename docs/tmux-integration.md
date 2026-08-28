# Tmux Integration: Learnings & Architecture

How TBD integrates with tmux, what we tried, what worked, and why.

## Architecture: One Linked Window Per Viewer + Direct PTY

Each terminal panel in TBD gets its own tmux client attached to a **private
session holding exactly one linked window**. SwiftTerm connects to the PTY
natively — no protocol parsing needed.

```
┌─────────────────────────────────────────────┐
│  tmux server: tbd-a1b2c3d4                  │
│                                             │
│  Session "main" (daemon-managed, persists)  │
│    Window @1: claude code                   │
│    Window @2: setup hook                    │
│    Window @3: claude code                   │
│    Window @4: setup hook                    │
│                                             │
│  Session "tbd-view-abc123"                  │
│    → holds @1 alone, linked from "main"     │
│    → the same window object, not a copy     │
│                                             │
│  Session "tbd-view-def456"                  │
│    → holds @3 alone, linked from "main"     │
│                                             │
└─────────────────────────────────────────────┘
```

A window linked into two sessions is one window: same pane, same processes,
same scrollback. Linking is what lets a panel show a window that `main` also
holds, without copying anything and without the two viewers sharing a
current-window pointer.

### How it works

1. **Daemon** creates tmux windows in session `main` (one tmux server per repo)
2. **App** creates an isolated session per visible terminal panel:
   `tmux new-session -d -s tbd-view-<uuid> -c /tmp`
3. **App** links in the one window it wants and discards the throwaway window
   the session was born with: `tmux link-window -s @3 -t tbd-view-<uuid>:`
   then `tmux kill-window -t tbd-view-<uuid>:0`. **That `:0` assumes the
   default `base-index`.** A user running `set -g base-index 1` puts the
   throwaway at index 1, so the kill fails with `can't find window: 0`, tmux
   aborts the rest of the command chain, and the viewer session is left holding
   a stray `/tmp` shell alongside the window it wanted. `kill-window -a -t
   <session>:@<id>` — kill everything except the target — is base-index
   independent and is what the external-attach command uses.
4. **SwiftTerm** spawns `tmux -u attach -t tbd-view-<uuid>` in a native PTY via
   `LocalProcess`
5. **On hide**: `tmux kill-session -t tbd-view-<uuid>` — the viewer session
   dies; the window survives because `main` still holds it, and so does
   `main` itself
6. **On app close/reopen**: all viewer sessions die, `main` persists. The app
   creates new viewer sessions on demand.

The command builders for each step live in `TmuxBridge`
(`Sources/TBDApp/Terminal/TmuxBridge.swift`).

### Why one linked window per session

- **Independent sizing.** This is the load-bearing reason, and it comes from
  the *one window per session* part rather than from the session boundary. A
  tmux window has exactly one size: under `window-size latest`, the most
  recently active client among those displaying it sets its dimensions. Two
  panels showing two different windows therefore never contend. Two clients on
  the *same* window always do, no matter how their sessions are arranged — the
  only escape is the per-client `ignore-size` flag.
- **No shared pointer.** A private session means switching what a panel shows
  cannot move any other viewer, and cannot move `main` — which matters because
  the daemon's control-mode connection attaches to `main`.
- **Session persistence.** `main` survives app restarts, and tmux keeps all
  scrollback.
- **Native PTY.** SwiftTerm works exactly as designed: input, output and resize
  all go through the terminal driver.

### Not session groups

tmux **session groups** (`new-session -t main`) are the other way to get a
viewer its own current-window pointer: the new session shares the target's
whole window list. TBD does not use them. Grouping hands a viewer every window
on the repo's server — including windows belonging to other worktrees — where
linking hands it exactly the one it should show. The narrower grant is worth
more here than the shared window list, which no TBD viewer has any use for.

Some identifiers and comments in the app still say "grouped sessions" for this
path (`AppState`, `DaemonClient`, `RPCRouter+AttachHandlers`); read them as
"the direct-PTY viewer path, as opposed to control mode".

## What We Tried First: Control Mode (-CC)

We initially used `tmux -CC attach` (control mode), where tmux sends structured protocol messages instead of rendering its TUI:

```
%output %3 \033[31mhello\033[0m
%begin 1234567890 42 0
%end 1234567890 42 0
%window-add @5
```

### Why control mode failed for us

1. **Complexity**: iTerm2 has ~3,000 lines dedicated to its tmux gateway (`TmuxGateway.m`, `TmuxController.m`, `TmuxWindowOpener.m`). No other terminal has successfully implemented it — [Ghostty](https://github.com/ghostty-org/ghostty/issues/1935) and [Windows Terminal](https://github.com/microsoft/terminal/issues/5612) both have open feature requests.

2. **Size synchronization**: `refresh-client -C cols,rows` sets the control client size, which constrains ALL windows. Multiple panels of different sizes cause constant resize fights.

3. **`%output` is streaming, not stateful**: Control mode only sends output *changes*. When SwiftUI recreates a view (switching tabs, polling updates), all prior content is lost. Workaround (`capture-pane`) produced staircase rendering because its output format (`\n` line endings) differs from live terminal output (`\r\n`).

4. **Input encoding**: `send-keys -l` (literal mode) can't handle control characters like Enter (`\r`). `send-keys -H` (hex) works but adds complexity.

5. **Actor/threading conflicts**: The blocking `availableData` read loop blocked the Swift actor, preventing `registerPane` and `sendKeys` from executing.

### Control mode IS the right approach if:
- You're building a full terminal emulator with dedicated tmux integration code (like iTerm2)
- You want to render tmux panes without tmux's TUI
- You have resources to handle all the edge cases (~3,000+ lines)

### Control mode is the WRONG approach if:
- You want to embed terminals quickly with an existing terminal emulator library
- You have multiple panels of different sizes
- You want session persistence without complex state management

## Tmux Concepts Reference

### Hierarchy
```
Server (socket: /tmp/tmux-UID/tbd-xxx)
  └── Session (named: "main")
        └── Window (@1, @2, ...) — like tabs
              └── Pane (%0, %1, ...) — splits within a window
```

### Key commands

```bash
# Server management (use -L for custom socket name)
tmux -L myserver new-session -s main -d     # create server + session
tmux -L myserver kill-server                 # kill everything

# Viewer sessions as TBD builds them (one linked window each)
tmux -L myserver new-session -d -s view1 -c /tmp  # isolated session
tmux -L myserver link-window -s @3 -t view1:      # link ONE window in
tmux -L myserver kill-window -a -t view1:@3        # drop everything but @3
tmux -L myserver kill-session -t view1            # kill the viewer only

# Grouped sessions (share the whole window list, independent focus).
# Reference only — TBD does not use these.
tmux -L myserver new-session -t main -s view1

# Window management
tmux -L myserver new-window -t main -c /path    # create window
tmux -L myserver kill-window -t @3               # kill window
tmux -L myserver list-windows -t main            # list windows

# Pane info
tmux -L myserver list-panes -a -F '#{window_id} #{pane_id} #{pane_current_command}'

# Hide tmux chrome (for embedding)
tmux -L myserver set -g status off              # hide status bar
tmux -L myserver set -g pane-border-style fg=black  # hide pane borders

# Input
tmux -L myserver send-keys -t %3 -H 68 65 6C 6C 6F 0D  # send "hello\r" as hex

# Capture pane content (careful: output uses \n not \r\n)
tmux -L myserver capture-pane -p -e -t %3       # print with ANSI escapes
```

### Size management

- `refresh-client -C cols,rows` — sets control client size (affects ALL windows)
- `resize-window -t @3 -x cols -y rows` — resize specific window
- `resize-pane -t %3 -x cols -y rows` — resize specific pane
- A window has ONE size. Under the default `window-size latest`, the most
  recently active client among those displaying it wins. Panels avoid
  contention by each holding a different window, not by being in different
  sessions.
- `attach -f ignore-size` makes a client abstain from that calculation — but
  only while another client is contributing a size. Measured on tmux 3.6a: a
  normal 100x30 client and an `ignore-size` 180x45 client together hold the
  window at 100x29; detach the normal one and the window becomes 180x44.

### Session groups

When you create a session with `-t existing-session`, the new session **shares all windows** with the target but maintains:
- Its own "current window" pointer
- Its own attached client size
- Its own key bindings and options (if set per-session)

TBD does **not** use session groups — see "Not session groups" above. It links
a single window into a private session instead. The reference is kept here
because the distinction matters when reading tmux's own documentation.

### Targets resolve by prefix unless you say otherwise

`-t <name>` is tried as an exact name, then as **the start of** a session name,
then as a glob. So a command aimed at a session that has just gone away can
land on a different one whose name merely starts with the same text. Measured
on tmux 3.6a: with no exact `tbd-ext-abcd1234` present, `kill-session -t
tbd-ext-abcd1234` destroyed `tbd-ext-abcd1234-notes` and exited 0.

Prefix the target with `=` to demand an exact match. Two target kinds need a
trailing colon as well — `set-option` and `if-shell` take a *pane* target, so
`'=<name>'` either errors or silently takes the wrong branch, and `'=<name>:'`
is required. TBD's external-attach path pins every session target this way;
`TmuxBridge`'s viewer commands do not, which is safe only because a
`tbd-view-<8hex>` prefix collision would have to be created by hand.

### Linking windows

`link-window -s <src-window> -t <dst-session>:` makes one window a member of a
second session. It is the same window, not a copy: one pane, one process, one
scrollback, visible from both. A window is destroyed when the last session
holding it lets go, so a viewer session can be killed freely while `main` keeps
the window alive.

## Resources

- [tmux Control Mode Wiki](https://github.com/tmux/tmux/wiki/Control-Mode) — protocol spec, notification format
- [iTerm2 tmux Integration Docs](https://iterm2.com/documentation-tmux-integration.html) — user-facing docs for -CC mode
- [iTerm2 tmux Architecture (DeepWiki)](https://deepwiki.com/gnachman/iTerm2/5.2-tmux-integration) — internal architecture: TmuxGateway, TmuxController, TmuxWindowOpener
- [iTerm2 tmux Best Practices](https://gitlab.com/gnachman/iterm2/-/wikis/tmux-Integration-Best-Practices) — tips from the iTerm2 wiki
- [tmux Getting Started Wiki](https://github.com/tmux/tmux/wiki/Getting-Started) — covers session groups, window management
- [Ghostty control mode request](https://github.com/ghostty-org/ghostty/issues/1935) — discussion of challenges
- [Windows Terminal control mode request](https://github.com/microsoft/terminal/issues/5612) — more discussion of challenges
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — the terminal emulator library we use
- [tmux man page](https://man.openbsd.org/tmux.1) — authoritative reference

## Known issues

### A pane can be alive but no longer running an agent

A pane can be alive (`pane_dead=0`) after its Claude process exits, leaving a
bare `zsh` prompt — `terminal send` then types into a shell, not a session, and
that is a real send into a real pane, so nothing refuses it. Ground truth still
requires raw tmux:

```sh
tmux -L <server> list-panes -a -F '#{pane_id} dead=#{pane_dead} cmd=#{pane_current_command}'
```

Worth doing: surface `pane_current_command` in `terminal list` / `output` so
callers can tell "Claude running" from "shell prompt" without raw tmux.

The two neighbouring failures are fixed. `terminal.send` consults its target
before typing (one `list-panes` reading `#{pane_id}`, `#{pane_dead}`, the
`@tbd_terminal_id` pane option and `#{pane_start_command}`) and returns an error
rather than reporting success when the pane is gone, when the pane's process has
exited, or when the pane answers with a different terminal's id than the caller
named. `#{pane_id}` is in that list because `list-panes -t %N` answers for every
pane in `%N`'s **window** — `%N` only picks the window — so in a hand-split
window the send has to select its own pane's line rather than the first one.
`send-keys` into a `remain-on-exit` dead pane exits **0**, so tmux's own status
was never the signal; and pane ids are reused, so a stale DB coordinate used to
type into a live stranger (issue #384). Refusal requires *positive*
disagreement — a pane carrying no identity is sent to as before.

### `terminal wake` answered the same question without asking

`terminal.wake` decided "is there anything to wake?" from the database's parked
flags alone, and answered "already awake (no-op)" whenever they were clear.
That is a claim about a live session made without consulting tmux. Measured on
a live fleet, **34 of 49** rows the database called awake had no pane. Because
a wake no-op never delivers its `--prompt`, an autonomous caller got neither a
wake nor an error.

Wake now asks the same question `terminal.send` asks, through the same
`paneSendTarget` probe, and reports what it finds:

- **`.missing` / `.dead`** — no live session behind the row. Wake returns an
  error naming the state instead of a successful no-op, so a caller can tell a
  benign "already awake" from a terminal that needs recovery.
- **`.live` answering a different terminal's id** — the row's pane coordinate
  has gone stale and now points at a stranger's pane (#384). Also an error;
  wake must not treat someone else's live pane as evidence that this session is
  healthy.
- **`.live` with a matching id, or none at all** — the benign no-op, unchanged.
  As with send, refusal requires *positive* disagreement.
- **The probe threw** — unchanged benign no-op. A tmux call that merely failed
  proves nothing, and tmux calls fail spuriously exactly when the machine is
  loaded enough for the session to be alive.

**Wake reports here; it does not repair.** Respawning a row the database calls
awake would make tmux authoritative over the parked flag, and one false-negative
probe would then destroy a live session's in-flight work. Recovery stays the
parked-row path and the explicit `terminal.recreateWindow` RPC. Reusing send's
probe rather than adding a second one is deliberate: two liveness primitives
would drift, and this is the one that already carries pane identity.
