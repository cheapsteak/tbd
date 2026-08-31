# Prior art: keeping a terminal session alive when the program displaying it dies

*Researched 2026-08-30 from source checkouts, official documentation, and
maintainer statements in issue and discussion threads. Two claims in this
document were verified by direct experiment on the development machine and are
marked as such. Companion document:
[`iterm2-session-restoration.md`](iterm2-session-restoration.md), which covers
iTerm2 in depth — this survey defers to it and does not duplicate it.*

TBD keeps agent sessions alive across daemon and app restarts by running them
under tmux. Field measurement puts a real interactive cost on that choice:
keystroke-to-visible through a raw pty is 0.1 ms p50 and 0.9 ms p90 and is
indifferent to system load, while the same keystroke through tmux is 3.3 ms p50
and 12.7 ms p90, degrading to 139 ms p90 under heavy load. This document
surveys how other systems have answered the underlying question — can a session
outlive the program displaying it without putting a process in the
per-keystroke path — so that the eventual design decision is made against the
known landscape rather than against two data points.

## Synthesis

**Nobody ships persistence with zero processes in the per-keystroke path, but
the two halves of the answer both exist in production, in different systems,
and neither half is speculative.**

The design space turns out to have three occupied regions and one empty one.

- **Own the pty in the GUI process** – Ghostty, kitty, Warp, and every
  conventional emulator. Zero extra processes per keystroke; the emulator
  writes the byte to the pty master and the kernel line discipline echoes it
  inside that same `write()`. Persistence is structurally impossible: the
  master fd dies with the process and the child gets `SIGHUP`.
- **Own the pty in a server, relay bytes over a socket** – dtach, abduco,
  shpool, Zellij, WezTerm's mux domains, zmx, hauntty, VS Code's pty host, and
  every GUI-app persistence daemon found. Persistence works; a process is in
  the path on every keystroke.
- **Own the pty in a server, but hand the *display* fd to the server** – tmux
  and GNU screen. This is the region most people, including the framing of this
  research task, get wrong. Both of them pass the attaching client's real
  terminal fd to the long-lived server over `SCM_RIGHTS`, and the server then
  does direct `read`/`write`/`tcsetattr` on it. **The tmux and screen client
  processes are not in the steady-state keystroke path.** They idle on signals.
  The per-keystroke cost of tmux is the server waking twice and running a full
  VT parse and grid diff — not a four-hop client relay.
- **Own the pty in a supervisor, hand the *pty master* fd to the renderer** –
  occupied, but only halfway. **iTerm2 ships exactly this mechanism** and has
  for years: its session-restoration server owns the master and hands it to
  the app, which does direct I/O (see the companion iTerm2 record for the
  source read). So the transport is precedent, not invention, and should not
  be described as unexplored.

  What is genuinely unoccupied is the *combination*: a supervisor that owns
  the master, a renderer that reads it directly, **and a always-present
  daemon that drains the master whenever no renderer is attached**. iTerm2
  cannot occupy that third corner structurally — it has no process alive
  while the app is closed, so a detached session's output has nowhere to go
  and its supervisor simply parks the fd. That gap is the region TBD's
  question actually points at, and it is a smaller and better-supported claim
  than "nobody does this".

The mechanism that region needs is not novel, and every piece of it is in
production somewhere:

- **Passing a pty master over a socket** is how systemd's `machined` serves
  `machinectl shell` and `systemd-run --pty`: `OpenPTY`, `OpenLogin`, and
  `OpenShell` are D-Bus methods whose reply signature is `hs` — a UNIX fd
  handle plus the pts name — so the caller receives the master and does its own
  I/O on it ([`machine-dbus.c`](https://github.com/systemd/systemd/blob/main/src/machine/machine-dbus.c)).
  `machined` closes its own copy, so this buys the handoff and not the
  persistence.
- **Keeping a duplicate of the master alive to prevent `SIGHUP`** is how
  Superset upgrades its terminal daemon without killing shells: the outgoing
  daemon spawns its successor with the pty masters on inherited fds, and "the
  kernel's fd refcount keeps master fds alive across the predecessor's
  exit — shells never see `SIGHUP`"
  ([PR #3971](https://github.com/superset-sh/superset/pull/3971)).
- **Moving a live pty master between processes after the fact** is what
  `reptyr -T` does, attaching to a terminal emulator with `ptrace`, locating the
  master fd, and pulling it across a UNIX socket with `SCM_RIGHTS`
  ([nelhage, 2014](https://blog.nelhage.com/2014/08/new-reptyr-feature-tty-stealing/)).

The only place the combination has been written down is the Zed RFC on
persistent terminal sessions, which proposes a per-session `pty-host` daemon
and then notes, of the socket-path handshake it settled for, that "file
descriptor transfer via `SCM_RIGHTS` would be cleaner" — and defers it
([discussion #50584](https://github.com/zed-industries/zed/discussions/50584)).
Even there the renderer is not proposed as the direct pty reader; the fd
transfer is discussed as a tidier way to find the daemon.

Two further conclusions matter as much as the empty region.

**Nothing surveyed resurrects a live process across a reboot, and almost
nothing does across the death of its own daemon.** What survives is always a
serialized *description* — a layout file, a grid snapshot, a scrollback
buffer — used to redraw the screen and relaunch the command. Zellij's session
resurrection re-runs the pane's command behind a "Press ENTER to run" banner.
kitty's `--session` restore re-starts the shell and the process inside it. VS
Code calls its equivalent "process revive". Superset's disk snapshots give a
"cold restore" the user can look at but cannot resume. The honest framing is
that persistence across a *client* restart and persistence across a *host*
restart are different products, and only the first is solved anywhere.

**The minimal supervisors lose output produced while detached** — which is the
functional gap that matters most for a fleet of agents that keep working with
nobody watching. This is confirmed in both sources, below.

## The verified mechanism

Two claims underpin any design in the empty region. Both were tested directly
rather than assumed.

**A pty master handed to another process over `SCM_RIGHTS` works, and the
receiver's death costs the child nothing so long as a supervisor still holds a
copy.** A test program created a pty with `forkpty`, passed the master to a
separate process over a `socketpair` with `SCM_RIGHTS`, had that process do
direct `read()` and `write()` on the master, then killed it. The shell — which
had a `trap ... HUP` installed to report the signal — never saw `SIGHUP` and
exited normally with its own status. This is the whole hypothesis, and on this
Darwin machine it holds.

**But holding the master is not sufficient; the supervisor must also drain
it.** The first version of that test had the supervisor hold the master and not
read it. The shell then wedged permanently in the exiting state (`ps` state
`?Es`) rather than completing, because its terminal output had nowhere to go.
Draining the master after the renderer died made the test pass immediately. The
consequence for a design is concrete: a supervisor that merely parks the fd is
not enough. It has to take over reading the moment the renderer detaches or
dies, which means a handoff protocol with an explicit "you read now, I have
stopped" edge — exactly the pause-and-acknowledge step Superset describes for
its daemon upgrade, where only one process may actively read a pty at a time.
And once the supervisor is reading detached output, it needs somewhere to put
it, which is the whole terminal-state problem that dtach and abduco decline to
solve.

## The minimal supervisors: dtach and abduco

Both were read end to end from source
([dtach](https://github.com/crigler/dtach),
[abduco](https://github.com/martanne/abduco); roughly 1,700 and 1,400 lines
respectively). They are the closest existing thing to "just hold the pty", and
they are close to identical in shape.

- **Pty ownership** – a master process created by `forkpty`, which `setsid()`s
  away from the launching terminal and daemonizes. Nothing external keeps it
  alive; it is a plain orphan reparented to init, and it exits when its child
  does.
- **Keystroke path** – **a process is in the path, and neither passes any file
  descriptor.** Grepping both trees for `SCM_RIGHTS`, `sendmsg`, and `recvmsg`
  returns nothing. The attaching client puts its own terminal into raw mode
  with `ECHO` cleared (`attach.c`), so there is no local kernel echo at all;
  every byte travels client `read(0)` → `write(socket)` → master
  `read(socket)` → `write(ptm)` → line-discipline echo → master `read(ptm)` →
  `write(socket)` → client `read(socket)` → `write(1)`. That is four process
  wakeups per keystroke, the same topology as a byte-relay multiplexer, with
  the terminal emulation removed. dtach is smaller than tmux; it is not
  structurally closer to the kernel.
- **What survives** – the live process, and nothing else. Neither keeps any
  terminal state. dtach's answer to a reattached blank screen is a "redraw
  method": send the application a literal `^L`, or send it `SIGWINCH`, or do
  nothing (`master.c`, `REDRAW_WINCH` / `REDRAW_CTRL_L`). abduco has no redraw
  at all; its README recommends running `dvtm` inside it if you want one.
  Nothing survives a reboot.
- **Output while detached is discarded.** In abduco, `server.read_pty` is
  initialised to `(action == 'n')` and set true forever on the first client
  accept, after which the server keeps reading the pty and, with no clients in
  its fan-out loop, drops what it reads (`server.c`). dtach's master defers its
  *first* read until a client attaches — a startup race fix, per the 0.8
  changelog — and thereafter fans pty output out to whatever clients exist,
  which when detached is none. For a session a human reattaches to within
  seconds this is invisible. For an agent that produced twenty minutes of
  output while nobody was watching, it is total loss.
- **Reattachment** – by filesystem path. The session *is* a UNIX socket at a
  path the user names. dtach marks the socket's user-execute bit while clients
  are attached (`update_socket_modes`) so a lister can tell attached from
  detached; abduco keeps a directory under `$HOME/.abduco` or `/tmp/abduco/$USER`
  and its bare invocation prints a session list with attached, terminated, and
  idle markers.
- **Orphan reclaim** – an `atexit` handler unlinks the socket in both. That
  covers a clean exit and nothing else; dtach added stale-socket detection on
  `-A` in 0.8 precisely because the handler is not reliable. abduco adds a
  `SIGUSR1` handler to recreate a socket somebody deleted by accident, and
  documents `pgrep -P 1 abduco` as the way to find a server whose socket is
  gone — an admission that there is no reconciler and the operator is it.
- **Relative to tmux, it gives up** – all multiplexing, all scrollback and
  copy-mode, any machine-readable interface to session state, resize
  reconciliation across differently-sized clients, and every form of screen
  restoration. abduco adds read-only clients and a session list over dtach; the
  gap to tmux is otherwise the same.

## The incumbents: tmux and GNU screen

This is where the common mental model is wrong, and the correction is the most
decision-relevant fact in this survey.

**GNU screen passes the attaching terminal's fd to the backend.** The attacher
dups its own controlling tty (`screen.c`, `attach_fd = 0`) and `WriteMessage`
routes an attach message through `SendAttachMsg` (`socket.c`), which builds a
`msghdr` with a `SOL_SOCKET`/`SCM_RIGHTS` control message and `sendmsg`s the fd
over the session socket. The long-lived backend picks it up in `ReceiveMsg`,
validates it against the pts name, and installs it as `D_userfd` via
`CreateTempDisplay` → `MakeDisplay`, immediately calling `SetTTY(D_userfd, ...)`
to put the *user's real terminal* into the mode it wants. From then on the
backend reads keystrokes from and writes updates to that fd directly. The
attacher, meanwhile, sits in a loop of `alarm(15); pause();` (`attacher.c`),
waking only for `SIGWINCH`, detach, suspend, or its liveness alarm. It has no
per-keystroke role whatsoever.

**tmux does the same thing.** `client_send_identify` dups `STDIN_FILENO` and
`STDOUT_FILENO` and sends each through `proc_send(..., MSG_IDENTIFY_STDIN, fd, ...)`
(`client.c`); `proc_send` hands the fd to `imsg_compose`, whose transport is
`sendmsg` with `SCM_RIGHTS` — and the client's `pledge` promise list includes
`sendfd` for exactly the window in which this happens. The server stores them as
`c->fd` and `c->out_fd` (`server-client.c`), then `tty_open` registers its own
libevent read and write watches directly on `c->fd`, and `tty_start_tty` calls
`tcsetattr(c->fd, ...)` to put the client's real terminal into raw mode
(`tty.c`). `tty_read_callback` does `evbuffer_read(tty->in, c->fd, -1)` — the
server reading raw keystroke bytes off the client's terminal itself. The tmux
client process, after the identify handshake, handles signals and control
messages and nothing else.

So for a plain `tmux attach`, the per-keystroke cost is **two wakeups of one
process** — the server waking on the client's terminal fd, and waking again on
the pane's pty master once the line discipline echoes — plus a full VT parse of
the echoed bytes into the grid (`input.c` → `screen-write.c`) and a rendered
diff written back out to `c->fd`. It is not a four-hop relay, and there is no
client process to remove. This matters for TBD directly: `TmuxBridge.swift`
spawns `tmux -u -L <server> attach -t <session>` inside a pty the app owns, so
the fd the tmux server ends up reading keystrokes from is the slave side of
TBD's own pty. Whatever the measured 3.3 ms is buying, it is not being spent on
a client relay that a cleverer design could delete.

Control mode (`-CC`) is a different path — a textual protocol over the imsg
channel rather than raw tty ownership — and is the one place the byte-relay
model is the right description of tmux. The identify handshake and fd passing
happen unconditionally before the control-mode branch, so a control-mode client
still hands over fds it then does not use for rendering; whether the server
skips the `tty_open` watch entirely for such clients was not traced and is
unconfirmed here.

What tmux buys over a bare supervisor is substantial and should not be
undersold, particularly given that TBD ships an external-attach feature that
depends on it:

- **Multiplexing** – windows, panes, and layout (`layout.c`, `window.c`), none
  of which dtach or abduco has in any form.
- **Attach from any emulator** – the client negotiates terminfo capabilities at
  identify time (`MSG_IDENTIFY_TERM`, `MSG_IDENTIFY_TERMINFO`), so the server
  renders correctly for whatever terminal shows up. A bare supervisor passes
  raw bytes and hopes.
- **Remote and ssh attach** – falls out of the above: the server is reachable
  by anything that can run the tmux binary against its socket, including over
  ssh, from a machine that has never seen TBD.
- **Shared sessions** – the server holds an array of clients, each with its own
  tty and its own size, all viewing one session; `resize.c` reconciles them.
- **A machine interface** – control mode as a protocol, and `capture-pane` for
  scripted extraction of screen state, which is how a supervisor learns what a
  session looks like without screen-scraping a rendered display.
- **Scrollback and copy-mode** – `window-copy.c`, and the grid history behind
  it, which is also what makes reattachment show you the screen you left rather
  than a blank one.

On lifecycle, tmux's defaults are worth naming because they are the opposite of
a reconciler: `exit-empty` defaults on (the server exits with zero sessions) but
`exit-unattached` defaults off, so a session whose client never returns lives
forever by design. `destroy-unattached` is the per-session opt-in. The socket
file is unlinked at bind time by the next server, not at exit by the last one.
Sessions do not survive a reboot; `tmux-resurrect` and `tmux-continuum` are
third-party plugins that snapshot layout, working directories, and pane text
and re-run an operator-configured allowlist of commands — layout restoration,
not process resumption.

## Latency by prediction: mosh

[mosh](https://mosh.org/) solves a different problem — network round-trip time
and client roaming, not process death — but it is the canonical answer to the
*latency* half of TBD's question, and its limits are instructive because they
are structural rather than incidental.

The `PredictionEngine` in `src/frontend/terminaloverlay.cc` speculatively echoes
the user's own keystrokes locally, underlined, before the server confirms them,
and reconciles against the authoritative screen state when the confirmation
arrives. The USENIX ATC 2012 paper reports that mosh "was able to immediately
display the effects of 70% of the user keystrokes", cutting median keystroke
response from 503 ms to under 5 ms on a commercial 3G link, measured over 9,986
keystrokes from six users across 40 hours
([Winstein & Balakrishnan](https://www.usenix.org/conference/atc12/technical-sessions/presentation/winstein)).

What it predicts is a narrow set: insertion of a printable single-width
character, backspace, and left/right arrow. Everything else calls
`become_tentative()`, which invalidates in-flight predictions until the server
catches up — any control character, any escape sequence, any CSI dispatch other
than left or right arrow, any non-single-width character, a prediction landing
in the last column, and a resize. The man page states the policy plainly: "The
predictive model must prove itself anew on each row of the terminal and after
each control character, so mosh avoids echoing passwords or non-echoing editor
commands."

The limit that matters most for TBD: **prediction only ever speculates about the
echo of the user's own keystroke. It never touches program output.** Scrolling,
a full-screen TUI repainting, an agent streaming tokens — none of it is
predictable, and none of it is helped. The paper concedes the high-output case
directly, noting that mosh's state-synchronization approach "causes trouble for
a task like 'cat'-ing a large file to the screen". A full-screen application is
defeated implicitly, since its escape traffic flips prediction tentative
continuously.

mosh also does not provide detach and reattach. `mosh-server` exits if no client
connects within 60 seconds, and after a connection it waits indefinitely for a
client to reappear unless `MOSH_SERVER_NETWORK_TMOUT` is set. The documented
answer to persistence is to run tmux or screen under it.

## GUI terminals that own the pty in-process

These are the systems with zero extra processes per keystroke, and they get
there by not having persistence.

- **Ghostty** – owns the pty in-process (`src/termio/Exec.zig`); no daemon
  exists, so nothing survives the app. macOS `window-save-state` restores tab
  and split *layout* with fresh shells and no scrollback. The maintainers'
  position is a decision, not an omission: a collaborator states flatly in
  [discussion #4931](https://github.com/ghostty-org/ghostty/discussions/4931)
  that "Ghostty does not do sessions, and it is currently not planned", and in
  [#12571](https://github.com/ghostty-org/ghostty/discussions/12571) that the
  focus is on libghostty as a reusable building block instead. Mitchell
  Hashimoto's own writing frames libghostty as "a public building block for
  terminal applications"
  ([Superlogical](https://mitchellh.com/writing/superlogical)) and the
  multiplexer he is now building is a separate product built on it, not a
  Ghostty feature. Read as prior art, this is the strongest argument in the
  survey for putting persistence in a layer the emulator does not own.
- **kitty** – calls `openpty()` in `kitty/child.py` and dies with its children.
  `--session` files restore layout by re-running commands; the documentation is
  explicit that "the shell **and** the process running inside it are
  **re-started**". Kovid Goyal's objection to multiplexers is a throughput
  argument — "every byte has to be parsed twice, once by the middleman and once
  by the terminal... you get at best a halving of throughput"
  ([#391](https://github.com/kovidgoyal/kitty/issues/391#issuecomment-638320745)) —
  and kitty's own benchmarks page carries the measurement. He distinguishes that
  from persistence, which he has said for years he would implement as a daemon
  eventually and has not: most recently, "It was never out of scope. Simply
  something I am not particularly interested in"
  ([#9318](https://github.com/kovidgoyal/kitty/issues/9318#issuecomment-3688649953)).
- **Warp** – local sessions run in the app process; quitting kills them, which
  is why Warp ships a quit warning. Block *text* is persisted to a local SQLite
  database and window layout is restored, so a restart looks continuous and is
  not. A tmux-style detach/reattach request is closed as not planned
  ([#2106](https://github.com/warpdotdev/Warp/issues/2106)). Its remote daemon
  exists only for ssh sessions, runs on the remote host, and self-terminates on
  an idle timer.

## GUI applications that added a persistence daemon

This is the group TBD most resembles, and every member of it relays bytes.

- **VS Code** – moved terminal processes out of the renderer into a "pty host"
  under the shared process. Reloading a window reconnects to the live processes;
  restarting the application does *not* — that path is "process revive", which
  restores the terminal's content from disk and relaunches the process with its
  original environment
  ([docs](https://code.visualstudio.com/docs/terminal/advanced)). The pty host is
  monitored and restarted if it dies or stops responding, and
  `terminal.integrated.persistentSessionScrollback` bounds how much content is
  kept. The orphan story is a timeout: persistent terminals were originally
  reclaimed 60 seconds after a disconnect
  ([#123518](https://github.com/microsoft/vscode/issues/123518)).
- **Superset** – an Electron terminal whose daemon owns every pty and whose app
  is "just a *client* of the terminal daemon", with the stated principle that
  "the default should be persistence, not cleanup". A headless xterm.js instance
  in the daemon keeps screen state, terminal modes, and cwd, so reattachment
  restores a real screen rather than a redraw request. Two sockets — one for
  RPC, one for the output stream — avoid head-of-line blocking. When the daemon
  dies, sessions are lost; disk snapshots give a cold restore you can read but
  not resume ([architecture writeup](https://superset.sh/blog/terminal-daemon-deep-dive)).
  Its fd-inheritance upgrade path is described in the synthesis above.
- **Zed** – has no shipped implementation; the
  [RFC](https://github.com/zed-industries/zed/discussions/50584) proposes a
  standalone per-session `pty-host` binary holding a headless
  `alacritty_terminal::Term`, serializing the whole grid on reconnect rather
  than replaying raw bytes ("No replay, no re-parsing"). It rejects tmux
  integration on double-emulation, nested keybindings, and scrollback grounds.
  The author reports six months of daily personal use.
- **WezTerm** – local panes have no server and no IPC hop; only panes in a mux
  domain do, and there the cost is acknowledged. WezTerm ships
  `local_echo_threshold_ms`, a predictive-echo feature that exists specifically
  to hide mux round-trip latency, and a maintainer fix
  ([`d36ad7c`](https://github.com/wezterm/wezterm/commit/d36ad7ca7f9054a9d2b49ffe8696c3e617623194))
  addressed the server pushing whole viewports per update and producing roughly
  half a second of lag per keystroke at large pane sizes. `wezterm-mux-server`
  daemonizes but is registered with no init system, so reboot survival is the
  user's problem, and there is no orphan reaper — persistence-until-killed is
  stated as intentional ([#631](https://github.com/wezterm/wezterm/issues/631)).
- **Zellij** – server and client split over a UNIX socket, server double-forks
  and `setsid()`s. Every keystroke is a discrete protobuf `ClientToServerMsg::Key`
  across the socket. Session resurrection serializes panes, tabs, and each
  pane's command to a KDL layout file about once a second and, on restore,
  **re-runs** the command behind a "Press ENTER to run" prompt — the verb is
  accurate, and REPL or editor state is gone. Reclaim of exited sessions is
  manual (`delete-session`). Against tmux it adds true multiplayer editing and
  a browser web client that needs no local binary.
- **herdr** – a recent agent-oriented multiplexer with the same shape: a
  persistent server owning all pty sessions, thin clients over UNIX sockets,
  layout and cwd saved to a JSON file on exit and restored on restart.

## The new state-sharing cohort

A cluster of 2025–2026 tools separates *session persistence* from
*multiplexing*, keeping the first and discarding the second. Architecturally
they are all byte relays; what is new is that they carry a real terminal-state
model, so reattachment restores a screen instead of begging the application for
a redraw.

- **shpool** – daemon owns named sessions; the client relays. Its README
  contrasts itself with tmux on rendering rather than on hops: "While `tmux`
  renders terminal contents remotely and only paints the current view to the
  screen, `shpool` just directly sends all shell output back to the user's local
  terminal", so "scrollback and copy-paste will work exactly as they do in your
  native terminal". It keeps an in-memory render solely to redraw on reattach,
  including output generated while disconnected. A grep of the tree for
  `SCM_RIGHTS` returns nothing — the latency claim is about avoiding double
  rendering, not about removing a process from the path. It is the only system
  surveyed with a purpose-built reaper: `daemon/ttl_reaper.rs`, a min-heap of
  session deadlines feeding `--ttl`, with a generation id per session name so a
  reap cannot clobber a fresh session that reused the name. Its stated
  philosophy — "managing different terminals is the job of your display or
  window manager, not your session persistence tool" — is precisely TBD's
  situation. It allows only one client per session.
- **zmx** – one daemon *per session* rather than one globally, `forkpty` plus
  double-fork and `setsid()`. Uses `ghostty-vt` to shadow-consume the pty stream
  and keep terminal state for restore. Its own framing, "the only thing sitting
  in-between you and your PTY is a unix socket", describes a byte relay
  accurately; the tree has no `SCM_RIGHTS`. No panes or tabs, deliberately.
- **hauntty** – one global daemon, sessions in an in-process map, `ghostty-vt`
  compiled to WASM for state tracking, snapshots to disk every 30 seconds. Its
  `restore` path decodes a snapshot for display and then spawns a **new**
  process — the same re-run-not-reattach limitation as Zellij, at the finer
  grain of daemon death rather than reboot. Its README is candid that it is an
  exploratory project.

## Adjacent mechanisms worth knowing

- **The Emacs daemon** takes a third approach to removing the client from the
  path: `emacsclient` sends the tty *name*, not the fd (`lib-src/emacsclient.c`
  sends `-tty <ttyname> <termtype>` after `ttyname(STDOUT_FILENO)`; there is no
  `SCM_RIGHTS` in the file), and the daemon opens that device itself and drives
  it directly. The client then blocks until the frame closes. Same outcome as
  screen — the persistent owner talks to the display device, the launcher idles —
  by a simpler route. It works only because the display is a kernel device a
  second process can open by name, which is exactly what a SwiftUI view is not.
- **`reptyr -T`** demonstrates that a live pty master can be moved out of a
  running emulator after the fact, via `ptrace` plus `SCM_RIGHTS`. It is not a
  design to copy — it needs root against setuid processes and is inherently
  fragile — but it is proof the fd is genuinely mobile.
- **iTerm2** is covered in the companion document and not duplicated here.

## Implications for TBD

Recommendations only; this is a research record, and none of this is a design.

- **The "remove the tmux client from the keystroke path" saving does not
  exist.** tmux already passes TBD's pty slave fd to its server and reads
  keystrokes off it directly. Whatever the measured 3.3 ms p50 is, it is one
  process waking twice and doing a full VT parse and grid diff, not a relay
  chain. The mechanism attribution behind the current measurement is worth
  re-deriving before it is used to justify a design, because the obvious saving
  it implies is not available.
- **The empty region is reachable, and the first spike is small.** A supervisor
  that creates the pty, hands the master to the app over `SCM_RIGHTS`, and keeps
  a copy gives the app direct pty I/O — kernel-line-discipline echo inside
  `write()`, the 0.1 ms path — while the session survives the app. This was
  verified working on this machine. Nobody ships it, which is a reason for
  caution about unknown corners, not evidence that it cannot work.
- **Draining is the hard half, not the handoff.** A supervisor that parks the fd
  without reading it wedges the child on exit — observed directly. The design
  needs an explicit single-reader handoff with an acknowledged edge, and the
  supervisor needs a terminal-state model to put detached output into, or it
  reproduces dtach's and abduco's worst property: agents produce output while
  nobody watches, and it is lost. Every modern tool in this space
  (shpool, zmx, hauntty, Superset, the Zed RFC) concluded independently that a
  headless VT model in the persistent process is mandatory, and TBD would be
  choosing the same thing.
- **Predictive echo is not the alternative it looks like.** mosh's own numbers
  are excellent for typing and it does nothing for scrolling or program output,
  which for a fleet of streaming agents is most of the perceived latency. It is
  a complement to a fast path, not a substitute.
- **Whatever replaces tmux has to replace external attach too.** Attaching from
  any emulator, over ssh, from a machine that has never run TBD, is a real
  capability that falls out of tmux's terminfo negotiation and socket
  reachability and out of nothing else in this survey. Every system that dropped
  multiplexing also dropped some of that, and said so on purpose.
- **A supervisor is a new kind of durable external resource.** Per-session
  daemons, their sockets, and their state snapshots all outlive the request that
  created them, and the survey's evidence on reclaim is discouraging: tmux keeps
  unattached sessions forever by default, WezTerm has no reaper and calls that
  intentional, Zellij's is manual, and abduco documents `pgrep -P 1` as the
  recovery procedure. shpool's TTL reaper — a scheduled heap with a generation
  id so a reap cannot hit a name-reusing successor — is the one design here
  worth copying outright.
