# A message composer in the live transcript pane

## Summary

A person watching a live Claude Code session in the app's transcript pane can
read what the agent says but cannot answer it there. Answering means switching
to the terminal pane, and when the terminal is slow the reply lags behind the
conversation. This design adds a composer under the live transcript: a
multi-line text field that sends a message into the running session, offers
completion for Claude Code's slash commands, skills, and subagents, and accepts
pasted or dropped images.

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

- **Enabled** while Claude is working, idle, or in an informational state. A
  message sent mid-turn queues inside Claude Code, as it does when typed.
- **Disabled with a reason** when the session is hibernated, with a Wake
  action, and when the session has a dialog on screen or an unrecognized
  awaiting-input reason, showing the notification message the daemon carries
  and a Reveal Terminal action.
- **Hidden** for terminals whose worktree is remote, and for Codex and shell
  terminals.

Keys: Enter sends, Shift+Enter inserts a newline, Cmd+Enter always sends,
Cmd+/ focuses the composer from anywhere in the pane, Escape returns focus to
the transcript. Drafts are kept per terminal in memory and restored when the
pane is shown again. Sending clears the field and its attachment chips on a
successful response, and leaves them in place with an error banner on failure.

Text sitting unsent in the terminal's own input box is invisible to the
composer, and a message sent from the composer appends to it. No signal exists
for this outside the rendered screen: Claude Code keeps its composer in process
memory, writes no draft file for a pty-hosted session, and exposes nothing about
it on its peer socket or control protocol. The design accepts the limitation
and documents it rather than warning from a keystroke timestamp that would be
wrong in both directions.

## Send pipeline

The app composes one payload: the message text, then for each attachment a
space and the quoted absolute path of its PNG. It calls the existing
`terminal.send` RPC with `text`, `submit`, and a new optional field
`envelope: "suppressed"`. The daemon then reuses the seam the queued-prompt path
already uses and injects nothing but the message. Old daemons ignore the unknown
field. The composer never uses the keys path and never asks for verification.

Every other text send to an agent carries a `<tbd-dispatch>` line naming the
actuation and actor. The composer suppresses it because the person is speaking
in their own voice, exactly as at the keyboard, and Claude should see only the
message.

Inside the per-terminal send serializer, the daemon applies two refusals before
dispatching to either transport:

- **Hibernated terminal.** Refused with a named reason. Today a send to a parked
  tmux session finds the window alive with a shell prompt in it, pastes the
  message, presses Enter, and executes the message as a shell command while
  reporting success. This refusal ships as its own fix ahead of the composer.
- **Awaiting-input gate.** If the terminal's latest state has a prompt on screen
  or an unrecognized awaiting-input reason, and the transcript-supersession
  check does not show the session has moved on, the send is refused with the
  carried notification message. A pasted body plus Enter into a permission
  dialog commits whichever option is highlighted, so the gate fails toward
  refusing, and an unknown reason is treated as a dialog because that is what a
  newer Claude Code's new dialog type looks like to this build. Informational
  reasons and the idle prompt are allowed. The gate is evaluated at send time
  in the daemon, not only at render time in the app, so the CLI benefits too.

### Transport behavior and the holder dependency

The tmux arm delivers text as an explicit bracketed paste followed by a
separate Enter, so multi-line messages are safe there.

The holder arm writes body and carriage return in one delivery with no
bracketed-paste wrapping. Measured against the installed Claude Code 2.1.261
under a real pty with the zero-token stub: a single unwrapped write of 63 bytes
submits, and a write of 64 bytes or more does not. The tokenizer splits control
bytes into key events only while the pending chunk is under 64 bytes, so past
that the carriage return is swallowed into the text and the whole string sits
in Claude's composer unsent. The same body wrapped in bracketed paste submits
regardless of size, whether the carriage return arrives in the same write or
10 milliseconds later. The dispatch envelope line alone is 68 bytes, so every
envelope-carrying send to a holder session today fails to submit.

The fix is wrapping when the child has bracketed-paste mode on, in one write,
and it belongs to the child-as-contract-party design (PR #816, decision 5),
which also gives the holder a typed screen carrying the child's modes. This
design takes that as a dependency and builds no second mode oracle. Until it
lands, the composer refuses to send a multi-line message to a holder-backed
session and says why. Holder delivery is at-least-once by design, so a rare
duplicate message there is a documented property, not a composer defect.

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
and carries names without descriptions.

The probe passes a settings overlay of `{"disableAllHooks": true,
"disableClaudeAiConnectors": true}`, a strict empty MCP configuration, and no
API key in the environment. Each of those closes a measured side effect:

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
- An API key in the environment changes the auth path and loses three
  subscription-gated commands.

The probe reads the Keychain twice per run through `security
find-generic-password`, keyed on the config directory's hash. The reads
complete in about ten milliseconds with no authorization activity, because the
item was created by the same tool and its access list trusts it. No prompt
appears.

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
hangs is killed at five seconds.

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
decayed with a seven-day half-life and floored at ten percent, kept in app
defaults. A bare slash shows the top five by frecency, then built-ins, user
commands, project commands, and plugin skills, each group alphabetical.

The fuzzy score is a greedy leftmost subsequence match: sixteen points per
query character, four for each adjacent pair, minus three plus the gap length
for each gap, eight for a character at position zero or after a separator, six
at a lowercase-to-uppercase transition, and a shortness bonus. Field weights
are name three, display name two, segments two, aliases two, description one
half. A query containing a colon is also split and matched segment by segment
with a large bonus when every query segment prefixes a distinct candidate
segment in order.

### Rows and keys

Each row shows the name with a matched alias in parentheses, a source badge for
built-in, user, project, or plugin, the one-line description, and the argument
hint. Matched characters are highlighted. Eight rows are visible in a list with
a fixed maximum height and a scroller, so a change in row count never shifts
layout. The list opens upward from the composer.

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
  about six lines, then scrolls. SwiftUI's TextEditor is rejected because Apple
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
- **Chips.** Attachments render as a strip of chips above the text view, never
  as inline text attachments. The text view stays plain, which keeps the
  substitution and paste-formatting hazards the submitting editor closed.
- **Drafts.** A per-terminal observable object held by the app state, placed
  outside the session-identity reset so a session rollover rebuilds the
  transcript without touching the draft.
- **Theme.** The transcript text theme, not the terminal theme, because the
  composer sits under the transcript.

Deferred: a browsable all-commands dialog like the one the Claude Code VS Code
extension added beside its type-ahead, ghost-text completion of a command
mid-sentence, and file paths and MCP resources under the at-sign.

## Attachments

A pasted or dropped image is prepared in the app through ImageIO: decode,
downscale to at most 2000 pixels on the long edge with orientation applied,
encode as PNG, and re-encode smaller if the result would exceed Claude Code's 5
MiB base64 cap. The thumbnail call passes the always-from-image option, because
the if-absent variant can return a stale embedded EXIF thumbnail. Clipboard
TIFF, clipboard PNG, and file drops share the path. The paste override reads the
pasteboard itself and does not add image types to the readable types, so
NSTextView's default pipeline never inserts an inline attachment, the shape the
terminal view's paste override already uses. The original bytes are never
passed through unexamined. An image that fails to decode is refused with a
message. A write that fails prevents the send.

Files are written to `~/tbd/attachments/<worktreeID>/<uuid>.png`, derived from
`TBDConstants` so `TBD_HOME` and the test fence apply, following the notes and
terminal-history precedents. The send payload appends each file's quoted
absolute path, which Claude Code's paste handler turns into an image attachment.

This is a new kind of durable resource, so it names its reconcilers:

- **Archive-time deletion.** The archive path fires a worktree-removed callback
  that the daemon wires to scratchpad cleanup. That callback also unlinks the
  worktree's attachments directory under the same GC-enabled guard. A revived
  worktree does not get its images back. This is best effort.
- **Periodic sweep.** A new OrphanGC leg runs on the existing hourly cadence.
  For each directory under attachments: keep it if its name is not a UUID or
  names a live worktree row; otherwise delete files older than 14 days and
  remove the directory when empty. It follows the existing leg shape: skip the
  whole leg on a failed database read, emit keep and reap lines into the plan,
  record each reclaim. Fourteen days is a soak knob, not a load-bearing number.
  A file whose send fails stays on disk for this sweep.

## Flag

One flag, `transcript_composer_enabled`, a `config` column added by a new SQL
migration with no DEFAULT clause, resolved in the record's model conversion
through `?? Config.transcriptComposerEnabledDefault`, default false. NULL means nobody chose, so graduation is a change to that constant that
preserves every explicit opt-out. Migration, GRDB record, Codable model, and
the migration manifest test land in one commit.

The daemon exposes it through `daemon.capabilities`, and Settings shows a
toggle beside the live transcript pane toggle, the way the queued-prompt flag
is surfaced. A flag with no toggle is not a shipped feature.

The flag gates the composer UI, the completions probe, attachment writes, and
the OrphanGC leg. It is a config column rather than an app default because the
GC leg lives in the daemon and cannot read the app's defaults. The probe needs
no flag of its own: with hooks and connectors disabled it has no visible side
effect, and it runs only when a composer is shown.

Two daemon changes ship ahead of the composer with no flag, as bug fixes: the
hibernated-terminal refusal and the `envelope` option on the send params. The
awaiting-input gate lands with the composer.

Graduation: after a soak with the toggle on, flip the default constant.

## Testing

- Send params decode with and without the envelope field, and the suppressed
  path injects no dispatch line.
- The hibernation refusal fires for a hibernated row and not for a live one, on
  both transports.
- The awaiting-input gate: one case per awaiting-input class, plus a superseded
  prompt that is allowed through.
- The probe runner against a fake executable that emits a canned initialize
  response: cache hit, fingerprint invalidation, timeout kill, and fallback to
  the filesystem scan. The scan against fixture command, skill, agent, and
  plugin directories, including a disabled plugin.
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
- **Wake a hibernated session and deliver.** Rejected for the first version
  because waking is a state-changing act that needs its own soak, and
  wake-then-deliver has an ordering hazard the injection design does not
  answer.
- **A SwiftUI-only composer.** Rejected because no SwiftUI text API exposes
  marked-text state, which is the single fact the Enter-versus-IME decision
  depends on, and because the multi-line case takes Up and Down away from the
  move-command modifier.

## Dependencies and follow-ups

- PR #816, child-as-contract-party: bracketed-paste wrapping on the holder arm
  when the child's mode is on, in one write, and the typed screen that exposes
  the mode. The composer's holder multi-line refusal lifts when it lands. The
  64-byte measurement and its harness were handed to that work.
- The two ahead-of-composer fixes: hibernated-terminal refusal and the envelope
  option.
- Deferred autocomplete features: the all-commands dialog, ghost-text
  completion mid-sentence, file paths under the at-sign.
- Not confirmed: whether the connectors setting leaves strictly no outbound
  socket. The debug log shows the fetch skipped; no packet capture was taken.
