# A message composer in the live transcript pane

## Summary

A person watching a live Claude Code session in the app's transcript pane can
read what the agent says but cannot answer it there. Answering means switching
to the terminal pane, and when the terminal is slow the reply lags behind the
conversation. This design adds a composer under the live transcript: a
multi-line text field that sends a message into the running session, offers
completion for Claude Code's slash commands, skills, and subagents, and accepts
pasted or dropped images placed inline in the text.

Three constraints shape it. The message must arrive in the session exactly as
if typed, so the composer reuses the daemon's existing send path and adds
nothing Claude sees. The completion list must stay current when Claude Code
ships new commands or the person installs new skills, with no TBD release in
between, so the list comes from the installed Claude Code binary itself, never
from a table inside TBD. And the composer must never read the rendered
terminal, because screen text is not an interface in this codebase.

Scope is Claude Code sessions on local worktrees. Codex, shell, and remote
sessions are out of scope. The archived transcript view never gets a composer.

## What the person sees

The composer is a text field pinned below the transcript table, inside the
session workbench beside the index rail, wherever a live Claude Code transcript
renders. A send button names the target terminal so the injection is never
anonymous.

- **Running.** Enabled while Claude is working, idle, or in an informational
  state. A message sent mid-turn queues inside Claude Code, as it does when
  typed.
- **Not running.** Enabled, with a note that Claude is not running and that
  sending will resume it, and the send button labeled accordingly. This covers
  a hibernated session and a session whose Claude process exited. Sending wakes
  the session with the message as its first prompt. While the wake is in
  flight the text stays in the field, shown as sending, until the session that
  wake started reports in. On a timeout the text is restored editable with the
  error line.
- **Blocked.** Disabled when the session has a dialog on screen or an
  unrecognized awaiting-input reason, showing the notification message the
  daemon carries and a Reveal Terminal action. Answering in the terminal is the
  correct resolution.
- **Hidden** for terminals whose worktree is remote, and for Codex and shell
  terminals.

Keys: Enter sends, Shift+Enter inserts a newline, Cmd+Enter always sends,
Cmd+/ focuses the composer from anywhere, Escape returns focus to the
transcript. Cmd+/ is unbound in the app, unclaimed by the terminal view, inert
in SwiftTerm, and not a system default. Drafts are kept per terminal in memory
and restored when the pane is shown again. A send to a running session clears
the field on a successful response and leaves it in place with an error banner
on failure.

Text sitting unsent in the terminal's own input box is invisible to the
composer, and a message sent from the composer appends to it. No signal exists
for this outside the rendered screen: Claude Code keeps its composer in process
memory, writes no draft file for a pty-hosted session, and exposes nothing about
it on its peer socket or control protocol. The design accepts the limitation
and documents it rather than warning from a keystroke timestamp that would be
wrong in both directions.

## Send pipeline

### Payload

The app splits the composer text at its image tokens into an ordered list of
parts, each either text or an image path. Empty text parts are skipped. It
calls the existing `terminal.send` RPC with two new optional fields: `parts`
and `envelope: "suppressed"`, plus `submit`. Old daemons ignore unknown fields
and treat the request as text-only, which the app avoids by checking the
capability before sending parts. The composer never uses the keys path and
never asks for verification.

The daemon delivers each part as its own bracketed paste, in order, then
Enter. A text part is pasted as text. An image part is pasted as the bare
quoted absolute path and nothing else, because Claude Code's paste handler
turns a paste into an image attachment only when the whole paste is one quoted
path with an image extension. Measured on 2.1.261: a bare quoted path pasted
alone became a base64 image block in the user message, while the same path
inside a sentence, and any path given as a command-line argument, stayed
literal text. Pasting the parts in order reproduces what drag-and-drop
produces: an `[Image #N]` placeholder at the caret between the words around it.

### Envelope

Every other text send to an agent carries a `<tbd-dispatch>` line naming the
actuation and actor. The composer suppresses it because the person is speaking
in their own voice, exactly as at the keyboard, and Claude should see only the
message.

Suppression is authority, not preference, so it rests on nothing the request
says about itself. `ActuationActor` is an ambient declaration: any process on
the daemon socket can stamp `{"kind":"app"}`, and the CLI, the app, and every
agent share one socket. Honoring suppression on that field would hand every
local caller the ability to type as a human, which is the one property the
envelope exists to deny.

The daemon authenticates the connection instead. `LOCAL_PEERPID` is a property
of an `AF_UNIX` socket rather than of the bytes on it, so the kernel names the
process that actually connected and no peer can claim another's pid. At accept,
the RPC connection reads that option through NIO's socket-option provider — one
`getsockopt`, and the app opens a fresh connection per request — and the
connection is provisionally the app's when the pid equals the pid the FD-vending
sidecar recorded for its current client. The sidecar has exactly one client, the
app, which connects it eagerly and unconditionally as soon as the RPC socket
answers, and the daemon already treats that recorded identity as load-bearing:
the app-liveness arbiter decides on it whether the daemon may read a pty again.

A pid is a number the kernel reissues, so a request that actually asks for
suppression pays for the rest of the identity: the daemon re-verifies the
sidecar's recorded identity against the pid through the same start-time and
command-line check every other pid-reuse guard in the daemon uses, and only a
`.same` verdict authenticates the connection. That second half costs two process
reads and runs only on a composer send, never on the request stream.

Suppression is honored only on an app-authenticated connection, whatever the
request's actor field says; the CLI, agents, and any other local process get the
envelope, so agent-to-agent dispatches stay attributed. The declared actor keeps
its existing job of recording which door an act came through, and gains no
authority. The check fails closed: an unreadable peer pid, no recorded sidecar
client, a pid mismatch, or any verdict but `.same` attaches the envelope. The
cost of failing closed is a visible dispatch line on a human's message, never a
lost message.

Suppression is a daemon-internal disposition today, reachable only from inside
the send core because no RPC field could be trusted to ask for it. This is the
one route that opens it to a caller, and what it turns on is the connection, not
the field: the request still cannot assert its way to suppression, it can only
ask on a socket the daemon has already established belongs to the app.

### Refusals and the gate

Inside the per-terminal send serializer, the daemon applies these before
dispatching to either transport:

- **Not-running terminal.** A text send to a terminal whose Claude process is
  gone is refused with a named reason. Today a send to a parked tmux session
  finds the window alive with a shell prompt in it, pastes the message, presses
  Enter, and executes the message as a shell command while reporting success.
  The same happens after Claude exits on its own, because the daemon records
  nothing on SessionEnd and the pane check sees a live pane with a matching id.
  Two facts make the refusal possible. The SessionEnd hook stamps the terminal
  as hibernated with an exited reason, cleared by the next SessionStart, which
  gives the app a machine-readable not-running state. The stamp applies only to
  SessionEnd reasons that mean the process is leaving; a `/clear`, which ends
  one session and starts another inside the same process, does not stamp. And because a hook can be
  missed on a crash, the send path also asks the daemon's existing
  foreground-process inspector, used today by the limit-resume path, whether
  Claude is the pane's foreground process, and refuses when it is not. Both are
  process-table facts, not screen text. This refusal and the exit stamp ship as
  their own fix ahead of the composer, since they also protect the CLI.
- **Awaiting-input gate.** When the request opts in, and the terminal's latest
  state has a prompt on screen or an unrecognized awaiting-input reason, and
  the transcript-supersession check does not show the session has moved on, the
  send is refused with the carried notification message. A pasted body plus
  Enter into a permission dialog commits whichever option is highlighted, so
  the gate fails toward refusing, and an unknown reason is treated as a dialog
  because that is what a newer Claude Code's new dialog type looks like to this
  build. Informational reasons and the idle prompt are allowed. The composer
  always opts in. Existing CLI sends do not, because agents use them to answer
  dialogs deliberately.

### Not-running delivery

When the terminal is not running, the app does not call send. It calls the
existing `terminal.wake` RPC with the message in its `prompt` field, which the
daemon already passes to the spawn builder as a trailing argument on `claude
--resume <sessionID>`. Measured on 2.1.261: the resumed TUI submits that
argument as a user turn with no keystrokes, reusing the session id. The daemon,
the coordinator, the builder, and the CLI already carry this parameter; only
the app has never passed it.

Because Claude has exited, the hibernation state is the same shape as a
deliberate hibernation: process gone, terminal alive, session id known. Stamping
an exit as hibernation means one state, one wake path, and one UI.

An argument prompt cannot carry image attachments, so for a not-running target
each image token is replaced inline with the quoted path as plain text. The
sentence reads the same, and Claude reads the files with its Read tool, whose
image reads are capped near 500 KB. The composer says so on the send button,
because the transcript then shows a tool read after the message rather than an
image inside it. TBD spawns sessions with permissions skipped, so a read outside
the worktree raises no prompt.

A wake whose session id no longer resolves makes Claude print one line and exit
1 with the prompt lost, while tmux reports the respawn as a success. The app
therefore holds the text as sending until the session its own wake started
reports in, and restores it on timeout. The hold is scoped to that one spawn,
because a SessionStart on the same terminal is not evidence the composer's wake
succeeded: a competing wake, a post-`--fork-session` recapture, and a person
typing `claude --resume` in the pane all produce one. Every respawn that
replaces a terminal's process, the wake path among them, already mints a
session incarnation id, plants it in the spawned process's environment as
`TBD_TERMINAL_INCARNATION_ID`, and gets it back on the hooks that process
fires. A worktree's first spawn and an archive restore plant no such id, which
is why a SessionStart without one never releases the hold. The discriminator
therefore exists on the one path the composer uses and only needs returning:
`terminal.wake`
gains one additive optional field on its result, the incarnation id it minted,
populated only on the `woken: true` path where a spawn actually happened. The
app releases the hold on the SessionStart carrying that id and on no other. A
manual `claude --resume` inside the pane the wake created inherits that spawn's
environment and so carries the same id, which is the composer's own incarnation
continuing and correctly releases. The wake RPC already returns `woken: false`
when the terminal was not hibernated and an error when the session is gone, and
the app surfaces both without ever entering the hold.

### Transport behavior and the holder dependency

The tmux arm delivers each part as an explicit bracketed paste followed by a
separate Enter, so multi-line and multi-part messages are safe there.

The holder arm writes body and carriage return in one delivery with no
bracketed-paste wrapping. Measured against 2.1.261 under a real pty with the
zero-token stub: a single unwrapped write of 63 bytes submits, and a write of
64 bytes or more does not. The tokenizer splits control bytes into key events
only while the pending chunk is under 64 bytes, so past that the carriage
return is swallowed into the text and the whole string sits in Claude's
composer unsent. The same body wrapped in bracketed paste submits regardless of
size, whether the carriage return arrives in the same write or 10 milliseconds
later. The dispatch envelope line alone is 68 bytes, so every envelope-carrying
send to a holder session today fails to submit.

The fix is wrapping when the child has bracketed-paste mode on, in one write,
and it belongs to the child-as-contract-party design (PR #816, decision 5),
which also gives the holder a typed screen carrying the child's modes. This
design takes that as a dependency and builds no second mode oracle. Until it
lands, the composer refuses to send a multi-line or multi-part message to a
holder-backed session and says why, because several deliveries there reopen the
at-least-once and routing questions that one delivery avoids. Holder delivery is
at-least-once by design, so a rare duplicate message there is a documented
property, not a composer defect.

## Command inventory

### Where the list comes from

Claude Code has no flag that prints its commands, and only the running program
knows its built-ins. Its headless mode does answer one control-protocol
request, `initialize`, with every command's name, description, argument hint,
and aliases, plus every subagent, in one flat list that covers built-ins, user
and project commands, skills, and plugin items namespaced `plugin:name`.

The daemon runs a **probe**: it starts the session's Claude Code executable in
print mode with stream-json input and output, writes one `initialize` request,
reads the one response line, closes stdin, and waits. Measured on this machine
against a real logged-in profile: about half a second wall time, 209 commands,
zero tokens, and no credentials required. The init frame that headless mode
also emits is not used, because it appears only after a real, billed message
and carries names without descriptions. Project trust does not gate the probe:
a project with no trust record, one with trust recorded, and an empty config
directory all returned the project's commands, skills, and agents identically.

The probe passes a settings overlay of `{"disableAllHooks": true,
"disableClaudeAiConnectors": true}` and a strict empty MCP configuration, and
runs in the session's own spawn environment unmodified, adding no credentials
of its own. Each of those closes a measured side effect:

- Without the hooks setting, every SessionStart and SessionEnd hook in the
  profile, the project, and enabled plugins runs on every probe, and each probe
  leaves an empty `session-env/<uuid>/` directory behind. With it, no hook runs
  and no directory appears. Merging hook arrays through the overlay does not
  suppress them, no environment variable does, and bare mode does but drops
  every user skill and plugin command.
- Without the connectors setting, a probe in OAuth mode sends an authenticated
  request to the Anthropic API host to list cloud connectors, and the
  nonessential-traffic switch does not stop it.
- Starting the profile's real MCP servers leaked orphaned processes and wrote
  logs into the person's Library folder.
- Adding an API key to an OAuth profile's environment changes the auth path
  and loses three subscription-gated commands. Profiles whose own environment
  carries a key or an endpoint keep it, because that is the environment the
  session runs in.

The probe reads the Keychain twice per run through `security
find-generic-password`, keyed on the config directory's hash. The reads
complete in about ten milliseconds with no authorization activity, because the
item was created by the same tool and its access list trusts it. No prompt
appears.

The probe is not read-only against Claude Code's `.claude.json`. In a fresh
config directory it writes first-run metadata and a backup file. Against an
existing project entry it rewrote the entry, keeping the trust key and dropping
an onboarding key. TBD's trust seeder does an actor-serialized read-merge-write
of the same file when a worktree is created, so every probe runs through that
same actor and never overlaps a seed on the same config directory.

### Which executable

Claude Code updates itself in the background, and a running session keeps the
old binary until restarted. Five versions sit side by side on this machine and
two are running at once with different command counts. The probe therefore
asks the executable the session is running, read from the process table by the
recorded child pid through the shared process-path helper, and falls back
silently to the daemon's normally resolved executable when the pid is unknown,
the child has not yet exec'd, or the versioned file is gone. The fallback
carries no marker: offering a command the running session lacks costs one
"unknown command" reply, which is tolerable, and a marker would add a field to
the RPC and a state to the UI for nothing.

### Cache and cadence

Results are cached per executable identity, profile config directory, and
worktree path. The cache is stale when the modification time changes on the
settings file, the commands, skills, or agents directories under the config
directory or the worktree's `.claude`, or the two plugin manifests. Checking
staleness is a handful of stat calls. The probe runs only on a cache miss,
never on a timer and never on a keystroke, and the app warms the cache when the
composer first gains focus rather than when a slash is typed. A probe that
hangs is killed at five seconds, ten times the measured cold start; the number
is a soak knob, not a load-bearing one.

### Fallback

When a probe fails or times out, the daemon returns a filesystem scan of the
same directories: command and skill frontmatter for names and descriptions,
agent frontmatter for subagents, and the installed-plugins manifest and
enablement map for plugin items. The scan lists everything except built-ins,
because only the binary knows those. The app treats both shapes identically.

### The RPC

A new method, `terminal.completions`, takes a terminal id and returns commands
as name, description, argument hint, and aliases, and agents as name and
description, plus a freshness marker. The app never probes itself: the daemon
holds each session's profile, environment, cwd, and pid, and the app does not
link the daemon library.

## Autocomplete

The behavior follows Claude Code's own composer, read from its binary, except
where a Mac panel and the person's stated preferences call for a change.

### Triggers, and never a trap

The command menu opens when a slash is typed at the start of the input, at the
start of a line, or after whitespace, anywhere in the text. It never opens
inside a word, so `https://` and `foo/bar` do not trigger it. The mention menu
opens on an at-sign under the same rule. Only subagents appear under the
at-sign in the first version.

The menu is a suggestion, not a mode. Typing continues to filter it. A space,
or the caret leaving the token, closes it. Escape closes it and keeps it closed
for that token until the token changes. Backspace into the token reopens it. No
menu opens or updates while an input method has marked text.

### Filtering and ranking

Filtering is synchronous on every keystroke, with no debounce, over a list of
at most a few hundred items. Matching is case-insensitive against the name,
display name, name segments split on colon, dash, underscore, and dot, aliases,
and the description at low weight, so `brain` finds the brainstorming skill
inside its plugin namespace and `sup:br` matches segment by segment.

Order is exact name, exact alias, name prefix with the shortest first, alias
prefix, fuzzy score, then frecency as a tiebreak. Frecency is usage count
decayed with a seven-day half-life and floored at ten percent, kept in one
global store in app defaults keyed by command name. Those two constants are
Claude Code's own, read from its binary during this design's research — it
scores a command as usage count times the larger of 0.5 raised to
days-since-last-use over 7, and 0.1 — and copying them is the point: the same
commands rise to the same places in the transcript composer as in the terminal,
so muscle memory carries across the two. The floor is what keeps a
once-favored command from decaying to nothing and vanishing from the list.

A bare slash shows the top five by frecency, then built-ins, user commands,
project commands, and plugin skills, each group alphabetical.

The fuzzy score is a greedy leftmost subsequence match: sixteen points per
query character, four for each adjacent pair, minus three plus the gap length
for each gap, eight for a character at position zero or after a separator, six
at a lowercase-to-uppercase transition, and a shortness bonus. Those numbers
are Claude Code's own, read from its binary: they are the scorer its composer
applies to file paths under the at-sign, applied here to command names, and the
field weights, name three, display name two, segments two, aliases two,
description one half, are the weights its command menu gives the same fields.
Copying them is the point: a query ranks the same way in this composer as in
the terminal, so nothing has to be relearned. A query containing a colon is
also split and matched segment by segment with a large bonus when every query
segment prefixes a distinct candidate segment in order; that rule is TBD's
own, because the terminal has no namespaced completions to need it.

### Rows and keys

Each row shows the name with a matched alias in parentheses, a source badge for
built-in, user, project, or plugin, the one-line description, and the argument
hint. Matched characters are highlighted. Eight rows are visible in a list with
a fixed maximum height and a scroller, so a change in row count never shifts
layout. The list opens upward from the composer. Every row carries an
accessibility label, and the highlighted row is announced as the selection
moves.

- **Tab** accepts the highlighted row, or the first row when none is
  highlighted, and inserts the token with a trailing space. Tab is the accept
  gesture the composer surfaces in any hint it shows.
- **Up and Down** move the selection and wrap. Ctrl+N and Ctrl+P do the same.
- **Enter** with a row highlighted accepts it, and sends when the token is the
  whole message. Enter with nothing highlighted sends the text as typed. At the
  start of the input the first row is preselected only on a genuine prefix
  match of the name, an alias, or a segment, so `/comp` plus Enter runs compact
  as it does in the terminal, and `/xyz` plus Enter sends a message.
  Mid-sentence nothing is preselected, so Enter sends and the menu engages only
  on Down, Tab, or a click.
- **Escape** closes the menu and leaves the text untouched.
- **Cmd+Enter** always sends. When the menu is closed, Tab, Up, Down, and Escape
  pass through to their normal meanings.
- **Hover** previews a row without moving the keyboard cursor. A click
  highlights rather than runs, because mouse mis-clicks on a list are common
  and the rows are larger targets than a terminal's.

A mid-sentence slash token is text to Claude Code, which expands a command only
at the start of a message. The completion earns its place there by getting the
name right, as Claude Desktop does when it inserts skill names mid-sentence.

Once a space follows a command token, the command's argument hint renders as an
inline placeholder.

### Loading and no match

If the inventory is not cached when a slash is typed, the menu shows a single
dim "Loading commands" row and swaps in real rows when the cache lands, with
nothing preselected so Enter cannot accept a row that appeared under the
finger. No match shows "No commands match" once the query is longer than one
character and contains no characters a command cannot contain. The typed text
stays literal.

### Mechanics

- **Text view.** A new NSTextView representable modeled on the existing
  `SubmittingTextEditor`, which already decides Return semantics through a
  pure, tested function with an IME guard. The composer needs three imperative
  writes that editor's one-way contract forbids: restore a draft, replace a
  token on accept, and clear on send. They arrive as one-shot token commands,
  the idiom the transcript pane uses for scroll-to-bottom. Height grows to
  about six lines, then scrolls. The text view stays plain: image tokens are
  plain text styled through the layout manager's temporary attributes, which
  never touch the storage. SwiftUI's TextEditor is rejected because Apple
  documents neither whether its key handler runs before insertion nor its
  behavior during composition, and it has no fit-to-content sizing on macOS.
  The text input suggestions modifier is rejected because it replaces the whole
  field rather than inserting a token. NSTextView's built-in completion is
  rejected because Apple documents it as a plain string list.
- **Key routing.** One pure function extends the existing Return-key decider
  with a menu-open input and returns submit, newline, menu up, menu down, menu
  accept, menu close, blur, or pass through. It is intercepted in
  `doCommandBy`, reads the shift flag from the current event because AppKit
  binds no separate Shift+Return, and passes every key through while marked
  text exists. A second guard refuses to open or update the menu during
  composition. There is no second decision site.
- **Suggestion list.** A SwiftUI overlay inside the pane, never a separate
  window. The text view keeps first responder, so the caret keeps blinking and
  the IME candidate panel keeps working while the list has logical focus. The
  transcript pane already renders a SwiftUI overlay above its AppKit table. A
  non-key child window is the fallback if clipping ever bites, and the
  floating-panel code documents that adding a child window to the split-view
  window raises an exception, which is why it is not the default.
- **Completion controller.** A pure observable object shaped like the jump
  menu's view model: query, selected index, rows, move up and down, a row cap,
  with rows memoized by query. It lives in the app target with its tests, like
  both existing palette precedents.
- **Drafts.** A per-terminal observable object held by the app state, placed
  outside the session-identity reset so a session rollover rebuilds the
  transcript without touching the draft. The draft holds the text and the
  attachment map.
- **Theme.** The transcript text theme, not the terminal theme, because the
  composer sits under the transcript.

Deferred: a browsable all-commands dialog like the one the Claude Code VS Code
extension added beside its type-ahead, ghost-text completion of a command
mid-sentence, and file paths and MCP resources under the at-sign.

## Attachments

### Inline tokens and the strip

Pasting or dropping an image inserts a placeholder token at the caret,
`[Image #1]`, `[Image #2]`, rendered in a distinct color with a thumbnail on
hover. The token is the anchor: it decides whether the image is sent and where
it sits among the words. A side map in the draft holds token to staged file. At
send time the text is scanned for tokens in order, and a token that was deleted
or edited so it no longer matches drops its image, the rule Claude Code's own
composer applies to the same placeholders.

A strip above the text field shows every staged image as a thumbnail, hidden
when there are none. It is a view of the same map. An image whose token is
gone from the text shows as detached, greyed and marked "not in message", so
nothing is dropped silently. Clicking a detached thumbnail re-inserts its token
at the caret; clicking an attached one moves the caret to its token. Hovering a
token highlights its thumbnail and hovering a thumbnail highlights its token.
The x on a thumbnail removes the token and the image from the send. The text
decides what is sent; the strip shows what is available.

### Preparation and storage

Each image is prepared in the app through ImageIO: decode, downscale to at most
2000 pixels on the long edge with orientation applied, encode as PNG, and
re-encode smaller if the result would exceed Claude Code's 5 MiB base64 cap.
Both limits are Claude Code's own client-side caps, read from its binary: an
image over 2000 pixels on either side is recompressed or refused there, so
staying under them means the file arrives as sent.
The thumbnail call passes the always-from-image option, because the if-absent
variant can return a stale embedded EXIF thumbnail. Clipboard TIFF, clipboard
PNG, and file drops share the path. The paste override reads the pasteboard
itself and does not add image types to the readable types, so NSTextView's
default pipeline never inserts an inline attachment, the shape the terminal
view's paste override already uses. The original bytes are never passed through
unexamined. An image that fails to decode is refused with a message. A write
that fails prevents the send.

Files are written to `~/tbd/attachments/<worktreeID>/<uuid>.png`, derived from
`TBDConstants` so `TBD_HOME` and the test fence apply, following the notes and
terminal-history precedents.

### Reclaim

This is a new kind of durable resource, so it names its reconcilers:

- **Archive-time deletion.** The archive path fires a worktree-removed callback
  that the daemon wires to scratchpad cleanup. That callback also unlinks the
  worktree's attachments directory under the same GC-enabled guard. A revived
  worktree does not get its images back. This is best effort.
- **Periodic sweep.** A new OrphanGC leg runs on the existing hourly cadence.
  For each directory under attachments: keep it if its name is not a UUID;
  otherwise, if no worktree row of that id remains, remove the whole directory
  once nothing in it is younger than 14 days. Inside a directory whose row does
  still exist, each file older than fourteen days is reclaimed on its own while
  the directory stays — it is never removed while the row lives, even once it
  holds nothing. That per-file reclaim is safe because a staged image is read at
  paste time, or at resume time on the wake path: the file is needed for
  minutes, never days, so one that has sat untouched for two weeks belongs to a
  message nobody is going to send. It follows the existing leg shape: skip the
  whole leg on a failed database read, emit keep and reap lines into the plan,
  record each reclaim. Fourteen days is a soak knob, not a load-bearing number.
  A file whose token was deleted, or whose send failed, stays on disk for this
  sweep.

## Flag

One flag, `transcript_composer_enabled`, a `config` column added by a new SQL
migration with no DEFAULT clause, resolved in the record's model conversion
through `?? Config.transcriptComposerEnabledDefault`, default false. NULL means
nobody chose, so graduation is a change to that constant that preserves every
explicit opt-out. Migration, GRDB record, Codable model, and the migration
manifest test land in one commit.

The daemon exposes it through `daemon.capabilities`, and Settings shows a
toggle beside the live transcript pane toggle, the way the queued-prompt flag
is surfaced. A flag with no toggle is not a shipped feature.

The flag gates the composer UI, the completions probe, attachment writes, and
the OrphanGC leg. It is a config column rather than an app default because the
GC leg lives in the daemon and cannot read the app's defaults. The probe needs
no flag of its own: with hooks and connectors disabled it has no visible side
effect, and it runs only when a composer is shown.

Two changes ship ahead of the composer with no flag, as bug fixes: the daemon's
not-running refusal with its exit stamp and inspector rail, and the app passing
the wake prompt it has never passed. That change needs no flag because it
adds no new way for input to reach a session: the wake prompt is an existing,
unflagged parameter that the CLI's wake command already passes and that the
nightwatch skill already uses to resume a parked session with a composed
prompt. The app's side is the only new call site, and it stays inert until the
composer exists: every parameter it adds defaults to nil, nothing in the app
passes a prompt yet, and a nil prompt encodes no field. The envelope option,
the parts list, and the opt-in gate land with the composer.

The exit stamp earns the same unflagged treatment on its own terms, not by
riding along with the wake prompt's. It records a fact the agent's own
`SessionEnd` hook reported — that the process has already ended — and neither
kills anything nor sends anything, which is exactly what distinguishes it from
the two auto-park causes that do sit behind flags: the idle sweep's
`auto_hibernate_enabled` decides to end a session nobody asked to end, and the
merge park's gate in `HibernationGate` decides to interrupt one. The stamp
decides nothing; it transcribes. It is scoped by session incarnation and
excludes holder transport, so it can only ever describe the tmux process it
was told about, and it is retracted the moment `SessionStart` or the wake path
reports the session back — so a wrong stamp costs one stray banner and one
refused send, never lost input. The refusal it enables is the bug fix: without
it, a send to a parked pane finds a live shell prompt, pastes the message,
presses Enter, and runs the text as a shell command while reporting success.

Graduation: after a soak with the toggle on, flip the default constant.

## Testing

- Send params decode with and without the new fields.
- Connection authentication, over a `socketpair` whose peer is the test process
  itself, with the sidecar identity injected: a connection whose peer pid
  matches the recorded app and verifies `.same` suppresses the envelope; a
  connection from any other pid gets the envelope however it declares its
  actor, including `{"kind":"app"}`; an unreadable peer pid, an absent sidecar
  client, and each non-`.same` verdict all keep the envelope. The declared
  actor never changes the outcome in any of these rows.
- Parts delivery on the tmux arm: text, image, text pastes in order, then one
  Enter; empty text parts skipped.
- The not-running refusal: a hibernated row, an exit-stamped row, and a live
  row whose inspector says Claude is not foreground are refused; a live row
  with Claude foreground is not.
- SessionEnd stamps the terminal hibernated with an exited reason; SessionStart
  clears it.
- The awaiting-input gate: one case per awaiting-input class with the opt-in
  set, a superseded prompt that is allowed through, and an opted-out request
  that is never gated.
- Wake with prompt from the app: the parameter reaches the spawn command;
  `woken: false` and the session-gone error are both surfaced without entering
  the hold; the wake result carries the incarnation id it minted on the woken
  path and none on the no-op paths.
- The sending hold: a SessionStart carrying the wake's own incarnation id
  releases it; one carrying a different id, and one carrying none, both leave
  it held; the timeout restores the text editable.
- Not-running attachment fallback: tokens replaced inline with quoted paths.
- The probe runner against a fake executable that emits a canned initialize
  response: cache hit, fingerprint invalidation, timeout kill, fallback to the
  filesystem scan, and serialization behind the trust seeder's actor. The scan
  against fixture command, skill, agent, and plugin directories, including a
  disabled plugin.
- Executable pinning: holder child pid, tmux pane child, shell not yet exec'd,
  and versioned path gone.
- The key router: every selector with the menu closed yields submit or pass
  through, never a menu action; marked text passes through unconditionally; a
  stale menu-open flag is impossible because the router reads the controller
  at decision time.
- The trigger detector: start of input, start of line, after whitespace, inside
  a word, inside a URL, after Escape suppression, after backspace.
- Ranking: prefix beats fuzzy, `brain` finds the namespaced skill, `sup:br`
  matches by segment, frecency breaks ties only.
- Tokens: insert at caret, split into parts, deleted token drops its image,
  edited token drops its image, detached thumbnail re-inserts, x removes both.
- Image preparation: TIFF in, PNG out, downscale, orientation, oversize
  re-encode, undecodable input refused.
- The GC leg with dry-run plans: live worktree kept, non-UUID kept, orphan older
  than 14 days reaped, orphan younger kept, failed database read skips the leg.
- Both branches of the flag, and the three states of the column.
- Live verification in the app against a stub-backed session, because
  transcript work has greened headless while broken live.

## Rejected alternatives

- **Hold messages until the session is idle.** The queued-prompt machinery
  could deliver when the session reports idle. Rejected because Claude Code
  queues typed input itself and shows it as pending, so immediate injection
  mirrors the terminal exactly, and a second delivery state would need
  explaining in the UI.
- **Keep the dispatch envelope.** Rejected because the composer is the person
  speaking in their own voice, and the envelope is noise to Claude and in the
  transcript.
- **Let any caller suppress the envelope.** Rejected because the envelope is
  how an agent-to-agent dispatch stays attributed inside the receiving session,
  and a public suppression switch would let any agent inject unattributed text.
- **Trust the declared actor field.** Reading suppression off
  `{"kind":"app"}` needs no new mechanism at all. Rejected because that field
  is a self-declaration the daemon has never verified and deliberately does not
  verify — it records which door an act came through — and the CLI, the app,
  and every agent reach the daemon through one socket. A caller that wanted
  unattributed injection would only have to type the field, which is the
  previous alternative wearing a different hat.
- **Check the peer's executable name.** Read the peer pid and accept any
  process whose executable is named `TBDApp`. Rejected because the name proves
  nothing — a same-user process can call its binary anything — and doing better
  by path means guessing the install location, which is `/Applications/TBD.app`
  for an installed build and a worktree's own `.build` bundle for a work-in-
  progress one. Matching against the sidecar's recorded client needs no guess.
- **A nonce the app registers at startup.** Rejected because it authenticates a
  secret rather than a process: anything that read the nonce would inherit the
  authority, and it adds a handshake to keep in sync with the app's lifecycle.
  The peer pid is supplied by the kernel and needs no secret.
- **A second, app-only RPC socket.** Genuinely stronger in that the CLI could
  not reach it at all, and rejected only on cost: it would duplicate the whole
  RPC surface, or split it, to carry one bit that a socket option already
  carries on the socket the app is using.
- **Gate every send on awaiting-input state.** Rejected because agents use the
  send RPC to answer permission dialogs deliberately, and a daemon-wide gate
  would refuse exactly those sends.
- **Disable the composer for a hibernated session.** Rejected because the wake
  path already accepts a prompt and delivers it atomically with the respawn, so
  the extra click bought nothing.
- **A separate exited state beside hibernation.** Rejected because the two are
  the same shape, process gone with a known session id, and one state gives
  one wake path and one UI.
- **Wake with the text, then paste the images.** Rejected because the images
  would arrive as a second turn. **Wake without a prompt and paste the whole
  message after the SessionStart settle** was deferred, not rejected: it is
  correct but reintroduces the paste-readiness dependence the argument path
  exists to avoid, and the model-read fallback covers the case.
- **A compiled-in list of built-in commands.** Rejected because it is stale the
  day Claude Code ships, and the requirement is that new commands appear
  without a TBD update.
- **Take built-ins from the headless init frame.** Rejected because the frame
  appears only after a real, billed message, omits about twenty
  interactive-only commands, and carries no descriptions.
- **Read Claude Code's rendered screen.** Banned in this codebase.
- **Ask only the resolved executable, never the running one.** Simpler, and a
  wrong-version completion costs only an "unknown command" reply. Rejected
  because the pin reduces to one lookup with a silent fallback, changes no
  downstream shape, and both ingredients, the recorded child pid and the
  process-path helper, already exist.
- **Warn about unsent terminal text.** The only available signal is the last
  keystroke time TBD routed into the pane, which cannot distinguish typed text
  from typed-then-deleted text, is absent on holder sessions, and clears only
  on the next observed state change. A disclaimer driven by it would persist
  after the text was cleared. Rejected in favor of documenting the limitation.
- **The rendezvous socket reply frame.** A session started with Claude Code's
  internal background-daemon environment variables listens on a unix socket
  and accepts a reply frame that enqueues text as a human user turn. Measured:
  it submits idle and mid-turn messages in about 0.3 seconds with multi-line
  text intact, and it is stable across the five installed versions. Rejected
  as the delivery path because a reply beginning with an exclamation mark runs
  as a shell command and a reply of `/exit` kills the session, so any same-user
  process reaching the socket owns the session; a reply sent during a
  permission dialog becomes stuck draft text that never submits; answering a
  question requires a session-kind variable that changes other behavior; a
  second connection silently displaces the first; the socket file is never
  unlinked; and the variables are undocumented internal plumbing. Claude Code's
  own supervisor uses the frame only when a session is blocked and otherwise
  types a bracketed paste into the pty. A future flagged experiment could use
  it for queue-while-blocked, the one place its owner uses it.
- **A separate flag for the probe.** The probe spawns a process without a
  keystroke. Rejected because, with hooks and connectors disabled, it has no
  visible side effect, it runs only when a composer is shown, and a second
  toggle would leave the composer half-working in one of its four states.
- **A chip strip with no inline anchors.** Rejected because it gives no way to
  refer to an image at a point in the sentence, which the terminal composer and
  Claude Desktop both allow.
- **Images as inline text attachments.** Rejected because enabling rich text in
  the view reopens the substitution and paste-formatting hazards the submitting
  editor closed, and a plain-text token with temporary attributes gives the
  same anchor.
- **A SwiftUI-only composer.** Rejected because no SwiftUI text API exposes
  marked-text state, which is the single fact the Enter-versus-IME decision
  depends on, and because the multi-line case takes Up and Down away from the
  move-command modifier.

## Dependencies and follow-ups

- PR #816, child-as-contract-party: bracketed-paste wrapping on the holder arm
  when the child's mode is on, in one write, and the typed screen that exposes
  the mode. The composer's holder multi-line and multi-part refusal lifts when
  it lands. The 64-byte measurement and its harness were handed to that work.
- The hibernation subsystem: hibernation and wake must treat holder-backed
  terminals the same as tmux-backed ones. The gate today refuses holder
  transports, which is a defect in the gate, not a property this design may
  rely on. Wake for a holder terminal, whose Claude process is the whole job,
  is that subsystem's work and a dependency of the not-running state here. A
  code comment in the coordinator claiming resume is cwd-scoped is false on
  2.1.261, where a full session id resumes from any directory.
- The two ahead-of-composer fixes: the not-running refusal with its exit stamp
  and inspector rail, and passing the wake prompt from the app.
- Deferred: paste-after-settle delivery of attachments to a not-running
  session; the all-commands dialog; ghost-text completion mid-sentence; file
  paths under the at-sign.
- Not confirmed: whether the connectors setting leaves strictly no outbound
  socket. The debug log shows the fetch skipped; no packet capture was taken.
