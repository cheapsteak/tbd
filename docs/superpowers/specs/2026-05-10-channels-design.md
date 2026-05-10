# Channels Design

**Date:** 2026-05-10
**Status:** Ready for implementation planning
**Replaces:** `2026-04-09-inter-session-messaging-design.md` (the prior "broadcast/thread/visibility-rules" attempt; deemed over-engineered)

## Overview

A Slack-like **channels** feature for inter-session context sharing across
Claude Code agents running in TBD-managed terminals. Free-form named topics
(`#help`, `#api-questions`, `#whatever`), append-only logs, pull-based
reads. Humans mediate cross-session discovery; agents post and read
explicitly.

The persistence story is the unusual choice: each channel is a single
JSONL file at `~/tbd/channels/<name>.jsonl`. The filesystem is the source
of truth; SQLite holds only viewer/UI metadata. This makes channel
content trivially inspectable, tailable, and readable by agents using
their existing primitives (`Read`, `tail -f`, `cat`).

## Goals and non-goals

### Goals

- Let one agent post a message that another agent (in any worktree, any
  repo, any tmux pane) can subsequently read.
- Make posting and reading both feel cheap and obvious from the agent's
  perspective — no schema gymnastics, no protocol learning.
- Keep the daemon out of the read path entirely. Reads should work even
  if the daemon is down.
- Be replaceable / inspectable / debuggable with standard Unix tools.

### Non-goals (v1)

- Auto-injection of unread messages into agent context via `PreToolUse`
  hooks. The prior attempt's "context arrives naturally" property is
  explicitly traded away in favor of agent-controlled, deterministic
  pulls.
- App UI. CLI-only ship; revisit once data shape stabilizes.
- Threading. Defer; can add `in_reply_to_seq` later without breaking
  existing files.
- Subscriptions. Agents pull what they want; no server-side
  subscription state.
- Auto-pruning. Files grow unbounded for now; add `archive` later if it
  matters.
- Cross-channel "firehose" reads (`tbd channels read` with no name).
  Use `tbd channels list` for cross-channel awareness; revisit if it
  matters.

## Concept

### What is a channel

A channel is a **free-form named topic** in a single global namespace.
`#help` means the same thing whether you post from repo A or repo B. A
channel is auto-created on first post; there is no separate "create
channel" step.

### Channel name validation

Names are normalized to lowercase and validated at the RPC boundary:

- Pattern: `^[a-z0-9][a-z0-9_-]{0,63}$`
- No leading/trailing whitespace, no slashes, no dots, no Unicode.
- Names that fail validation are rejected with a clear error before
  any file operation is attempted.

This is strict by design. APFS is case-insensitive on the boot volume,
which means `#Foo` and `#foo` resolve to the same file but would be
distinct rows in the per-viewer cursor table; lowercasing eliminates the
ambiguity. The pattern also closes the path-traversal vector
(`../../etc/passwd` and friends) before file paths are constructed.

## Storage model

### Filesystem (source of truth)

Each channel is a single append-only JSONL file:

```
~/tbd/channels/<name>.jsonl
```

(`~/tbd/` is the existing TBD config dir; do not introduce `~/.tbd/`.)

One JSON object per line. Newlines inside `body` are encoded (`\n`).
Lines are never updated, only appended. The channel file is auto-created
on first post by opening with `O_CREAT | O_WRONLY | O_APPEND`.

### Per-line schema

```json
{
  "seq": 42,
  "ts": "2026-05-10T14:23:01.234Z",
  "from_session": "abc-123",
  "from_label": "tbd-20260510-known-smelt",
  "body": "anyone seen the launchctl crash?"
}
```

| Field | Type | Notes |
|---|---|---|
| `seq` | int | Per-channel monotonic, 1-based. `(channel_name, seq)` is the message identity. |
| `ts` | string | ISO-8601 with millisecond precision. UTC. |
| `from_session` | string | The opaque Claude Code session ID (for traceability). |
| `from_label` | string | A human-readable session display name. Provisional source: TBD's worktree label / pane label. |
| `body` | string | UTF-8 plain text. Agents may post markdown; the daemon does not interpret it. Max 64 KB. |

### SQLite (`~/tbd/state.db`)

Two new tables. **`channel_index` is a derivable cache; `channel_cursor`
is non-recoverable app state** (sibling to `notification` per the
existing "NEVER delete `~/tbd/state.db`" rule).

```sql
-- v18 migration:
CREATE TABLE channel_index (
  name TEXT PRIMARY KEY,
  created_at TEXT NOT NULL,
  last_message_at TEXT,
  message_count INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE channel_cursor (
  viewer_id TEXT NOT NULL,        -- "app" for the SwiftUI app today
  channel_name TEXT NOT NULL,
  last_seen_seq INTEGER NOT NULL,
  PRIMARY KEY (viewer_id, channel_name)
);
```

Both tables update on every successful post. `channel_index` could be
rebuilt by walking `~/tbd/channels/*.jsonl`; `channel_cursor` could not.
Per the project's standard rule, both shipping schemas (the GRDB Record
type and the `TBDShared/Models.swift` Codable model) must be updated in
the same commit as the migration.

### Per-channel file layout, end state

```
~/tbd/channels/
├── help.jsonl          # source of truth
├── help.lock           # cross-process lock file (zero bytes)
├── api-questions.jsonl
├── api-questions.lock
└── …
```

Lock files are zero-byte sentinels used only for `flock(2)`; never read
or written.

## Write path (daemon-only)

All posts go through the daemon over the existing Unix socket. The CLI
calls `channels.post`; the daemon does the file I/O. There is no
direct-write path for the CLI in v1.

### Per-post sequence

For each `channels.post(name, body, fromSession, fromLabel)`:

1. Validate `name` against the regex above; reject otherwise.
2. Validate `body` is UTF-8 and ≤ 64 KB.
3. Acquire the daemon's per-channel async lock (in-process serialization).
4. `flock(LOCK_EX)` on `~/tbd/channels/<name>.lock`, opening the lock
   file with `O_CREAT` if absent.
5. Open `~/tbd/channels/<name>.jsonl` with `O_WRONLY | O_APPEND | O_CREAT`.
6. Determine next `seq`: read the highest `seq` from the in-memory cache
   (populated on daemon startup or first touch — see torn-line policy
   below).
7. Build the JSON line, ending with `\n`.
8. Single `write(2)` call. (Atomicity guarantees rest on the
   serialization above, not on PIPE_BUF.)
9. `fsync(2)`.
10. `close(2)`.
11. Release `flock`.
12. Update `channel_index` (`last_message_at`, `message_count++`,
    create row if first post).
13. Release per-channel lock.
14. Return `{seq, ts}` to the CLI.

No cached file descriptors. Each post reopens the file — this is the
trade-off chosen to avoid the "cached FD survives `unlink`/atomic-save"
hazard surfaced during adversarial review, at the cost of two extra
syscalls per post. Acceptable given the expected low post rate.

### `fsync` default

`fsync` is performed on every post in v1. The cost (~ms on APFS) is
acceptable given the expected low post rate. There is no flag to disable
it; if one is added later, the documented failure mode is "an OS-level
crash during a burst of posts can lose the most recent unflushed lines."

### Torn-line recovery (startup)

On daemon startup, for each `~/tbd/channels/*.jsonl`:

1. Stream-parse the file from the start, line by line.
2. Track the highest successfully-parsed `seq`.
3. If a line fails JSON parse, it is treated as a torn write.
4. **If the failed line is the last line of the file:** truncate the
   file to the offset of the trailing newline preceding it, log the
   truncation at `.notice` level, continue.
5. **If the failed line is anywhere else in the file:** log at `.error`,
   skip the line, continue parsing.
6. **If the file is unreadable entirely:** refuse to start, surface a
   loud error.

Recovery is logged so that a curious user can find out why their last
post is missing. Silent data loss is not acceptable; loud-but-recovered
loss is.

### Cross-process write hazard

The daemon enforces single-process operation via `Daemon.swift`'s
PID-file check, but there is a TOCTOU race in `PIDFile.swift` (read →
`kill(pid,0)` → write is not atomic) and a manual `swift run TBDDaemon`
from a sibling worktree could in principle race past the check. The
per-channel `flock` is a defensive measure for that case: even with two
daemons live, channel files cannot be torn by interleaved writes. The
worst surviving failure mode is duplicate `seq` values (each daemon
allocates from its own in-memory cache); detection of this and recovery
is out of scope for v1, but the lock prevents file corruption.

## Read paths

Reads bypass the daemon entirely. The CLI reads files directly. The
daemon does not need to be running for reads to work.

### Path 1: `tbd channels read <name> [--seq N | --since N] [--limit N]`

The recommended path for agents.

- `tbd channels read help` — last 20 messages from `#help`.
- `tbd channels read help --since 40` — messages with `seq > 40`.
- `tbd channels read help --seq 42` — just message 42.
- `tbd channels read help --limit 50` — last 50 messages.
- `--since` and `--seq` are mutually exclusive.
- Channel name is required (no cross-channel read in v1).

Implementation: open the file, stream-parse, filter, format, print.
Output is a human-readable rendering; JSONL is for storage, not for
consumption by humans/agents at the read layer.

### Path 2: `tbd channels tail <name> --follow`

A long-running command that watches the channel file and prints new
lines as they arrive. Designed for agents to launch as a Claude Code
background bash (`run_in_background: true`) and poll via `BashOutput`.

Implementation: open file, seek to EOF, register a `DispatchSource` /
`kqueue` watcher on `VNODE_WRITE | VNODE_EXTEND`. On event, read from
the saved position to current EOF, split on newlines, format, print.
Exits cleanly on SIGINT/SIGTERM.

The `BashOutput` integration is **load-bearing on undocumented Claude
Code behavior** (per-shell output buffer cap, idle-shell reaping, cursor
reset on shell death). Before docs claim the integration "just works,"
implementation includes an empirical-validation task; if the behavior is
fragile, the docs say so honestly and recommend short-lived background
shells over long-lived ones.

### Path 3: Direct file read by an agent

Agents can also read the channel file directly using Claude Code's
native `Read` tool: `Read("~/tbd/channels/<name>.jsonl", offset=N)`.

This works but has caveats:

- `offset` is **line-numbered**, not seq-numbered. After a torn-line
  recovery the two diverge.
- `Read` has a default 2000-line cap and per-line truncation.
- A growing file triggers Claude Code's stale-read warning machinery on
  every poll.

The TBD skill (which is loaded into TBD-spawned agent sessions via the
Claude Code plugin) documents the CLI as the recommended path and notes
these caveats for direct `Read`. We do not actively prevent direct
reads; it can be useful for one-off inspection.

### Read-path summary

| Path | Daemon involved? | Use case |
|---|---|---|
| `tbd channels read <name> --since N` | No (CLI reads file) | Agent pulls incrementals |
| `tbd channels read <name> --seq N` | No (CLI reads file) | Read one specific message (the post-output suggestion) |
| `tbd channels tail <name> --follow` | No (CLI tails file) | Agent watches in background |
| `Read("~/tbd/channels/<name>.jsonl", offset=N)` | No | Direct file read with caveats |
| `tbd channels list` | Yes (RPC for index) | Discovery |
| `tbd channels post <name> <body>` | Yes (RPC; daemon writes) | Posting |

## Identity

Reuse the prior attempt's mechanism. A tiny `PreToolUse` hook
subcommand writes session identity to a temp file on every fire:

```
/tmp/tbd-session-${TMUX_PANE}
```

Contents:

```json
{"session_id": "abc-123", "transcript_path": "~/.claude/projects/.../sessions/abc-123.jsonl"}
```

The hook subcommand (provisionally `tbd channels write-session-id`)
does **only** this one thing: read the hook's stdin JSON, write the
identity file. No daemon roundtrip. No throttle needed (purely local
file write, sub-millisecond).

`tbd channels post` reads `/tmp/tbd-session-${TMUX_PANE}` to resolve
`{from_session, from_label}` automatically; agents never need to know
their own identity. `--from` and `--from-label` flags exist as
overrides for testing or non-TBD contexts.

This is **not** the descoped content-push hook. It only writes the
identity file.

`tbd setup-hooks` is extended to install this `PreToolUse` hook
alongside the existing `Stop` notification hook.

## CLI

| Command | Purpose |
|---|---|
| `tbd channels post <name> <body>` | Post a message. Body may be `-` to read from stdin. Stdout includes a copy-pasteable read suggestion. |
| `tbd channels read <name> [--seq N \| --since N] [--limit N]` | Read messages. |
| `tbd channels tail <name> [--follow] [--from-start]` | Tail a channel; `--follow` watches for new messages. |
| `tbd channels list` | List channels with `last_message_at` and `message_count`. |
| `tbd channels write-session-id` | Internal hook subcommand. Not user-facing. |

### `post` output

```
Posted to #help (seq 42)
→ tbd channels read help --seq 42
```

The second line is the bridge to another session. A user posts in
agent A's terminal, copies that line, pastes it as agent B's prompt,
and agent B reads exactly that one message.

## RPC additions

`Sources/TBDDaemon/Server/RPCRouter+ChannelHandlers.swift` (new):

| Method | Request | Response |
|---|---|---|
| `channels.post` | `{name, body, fromSession, fromLabel}` | `{seq, ts}` |
| `channels.list` | `{}` | `[{name, createdAt, lastMessageAt, messageCount}]` |

That is the complete RPC surface for v1. Reads bypass the daemon. The
shared model layer (`Sources/TBDShared/Models.swift`,
`RPCProtocol.swift`) is updated in the same commit as the migration
per the project's standard rule.

## Discovery

Two paths:

1. **`tbd channels list`** — always available.
2. **The TBD skill** (loaded into TBD-spawned Claude Code sessions via
   the plugin shipped in commit `798293c`) gains a Channels section
   covering: what channels are, the post/read/tail commands, the
   `--seq` vs `--since` distinction, the post-output read-suggestion
   pattern, and the caveats for direct `Read`.

The typical workflow is **human-mediated**: a user asks agent A to post
something, then goes to agent B's pane and asks it to read. Agents do
not auto-discover or auto-poll.

## App UI

Out of scope for v1. The SwiftUI app is unchanged.

The `channel_cursor` table includes the row `viewer_id = "app"` for a
future v2 sidebar; v1 simply does not write to it. (The presence of the
table in the migration is fine — it is a no-op until the app starts
using it.)

## Adversarial review findings

The first round of adversarial review (feasibility-skeptic persona) was
run against an earlier draft of this design. Key calibrated findings:

| # | Finding | Status in this design |
|---|---|---|
| 1 | "PIPE_BUF makes O_APPEND atomic" claim is wrong (POSIX guarantees apply to pipes, not regular files; macOS PIPE_BUF is 512, not 4096) | **Removed.** Crash safety = serialization + `flock` + torn-line policy + `fsync`, not kernel atomicity. |
| 3 | Torn-line recovery on startup is unspecified | **Resolved.** Truncate-to-last-newline policy with logging. |
| 4 | `channel_cursor` claimed to be derivable but isn't | **Resolved.** Table is reframed as non-recoverable app state, sibling to `notification`. |
| 6 | `Read --offset` is line-numbered and diverges from `seq` | **Documented.** TBD skill recommends CLI; direct `Read` is supported with caveats noted. |
| 7 | Channel name validation undefined; APFS case-insensitivity, path traversal | **Resolved.** Strict regex + lowercasing at RPC boundary. |
| 8 | Cached file handles survive `unlink`/atomic-save | **Resolved.** Reopen-per-write; no cached FDs. |
| 2 | Multi-daemon writer hazard | **Mitigated.** Single-daemon enforced via PID-file (with TOCTOU race acknowledged); per-channel `flock` defends against the racy edge case. |
| 5 | `BashOutput` integration claim oversold | **Carried forward.** Empirical-validation task in the implementation plan before docs make claims. |
| Missed: fsync default | **Resolved.** `fsync` on per post in v1. |

## Open questions / risks

- **`BashOutput` lifecycle assumptions.** The "tail-as-background-bash"
  read path is convenient but rests on undocumented behavior. The
  implementation plan must include an empirical-validation task that
  characterizes: per-shell output buffer cap, idle-shell reaping, and
  what happens when the underlying bash dies.
- **Duplicate `seq` under the (rare, racy) two-daemon scenario.** The
  per-channel `flock` prevents file tearing but does not prevent two
  daemons from independently allocating the same `seq` from their own
  caches. Detection and recovery are out of scope for v1; if it
  becomes observable, a future revision can move sequence allocation
  into a small SQLite transaction.
- **`from_label` provenance.** The label is human-meaningful (e.g.,
  `tbd-20260510-known-smelt`). The exact source — worktree display
  name, pane label, something else — is left for the implementation
  plan to specify after looking at what's available in the daemon's
  per-pane state. Whatever is chosen should be stable for the
  lifetime of the pane.
- **No automatic pruning.** Files grow unbounded. For the expected
  usage (humans post sporadically), this should not bite for a long
  time. If/when it does, an `archive` subcommand that moves a channel
  file to `~/tbd/channels/_archive/<name>-<ts>.jsonl` is the obvious
  v2 addition.
