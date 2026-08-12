# Cross-session messaging for TBD-spawned Claude sessions

Claude Code v2.1.224 added cross-session messaging: a session discovers
peer sessions with `ListAgents` and sends plain text to one with
`SendMessage`. On one machine, delivery is peer-to-peer — each session
binds a per-session Unix inbox socket and registers itself in files on
disk; no Anthropic servers are involved. Reference:
[Message your other Claude Code sessions](https://code.claude.com/docs/en/cross-session-messaging).

TBD's workflow — many Claude sessions across parallel worktrees of one
repo — is exactly what the feature targets. This spec adopts the native
transport rather than building one: TBD's job is to make its sessions
addressable, keep discovery whole across profiles, and describe the
channel; the transport, throttling, and inbound-safety rails are Claude
Code's.

## Goals

- **Sibling worktree coordination** — orchestrator and worker sessions
  hand findings, status, and decisions to each other directly, without
  the human relaying between tabs.
- **Supervision status channel** — fleet-supervision programs (see
  `2026-07-26-fleet-supervision-design.md`) may use the channel as
  authored content, in both directions.

## Non-goals

- No TBD-owned message transport, daemon-side peer-protocol client, or
  `tbd message` CLI verb.
- No UI surfacing of peer messages.
- No compiled preference between native messaging and
  `tbd terminal send`.
- No live rename of running sessions.
- No compiled inbound policy.

Each is expanded under Rejected alternatives.

## How the native feature behaves for TBD sessions

Facts this design leans on, from the Claude Code documentation and the
TBD spawn path:

- **Same machine, same OS user** — the discovery boundary is the
  operating-system user, not the Anthropic account. All TBD sessions run
  in tmux on the host under one user, so the message sockets are mutually
  visible, and TBD unifies the otherwise per-profile peer registry (see
  Cross-profile discovery). Sessions logged into different Anthropic
  accounts (different TBD profiles) can therefore message each other
  locally.
- **Permission classes** — with no `crossSessionInbound` value set,
  Claude Code delivers a message when sender and receiver are in the
  same permission class. TBD spawns every Claude session with
  `--dangerously-skip-permissions`, so TBD↔TBD messages deliver with no
  approval dialogs out of the box.
- **Beyond the machine** — cross-machine and web sessions are reachable
  through Anthropic servers, same account only, and reply-only: a local
  session can answer a message from one but never initiate.
- **Killswitches** — `DISABLE_TELEMETRY`, `DO_NOT_TRACK`,
  `DISABLE_GROWTHBOOK`, and `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`
  can turn off the feature-flag evaluation messaging depends on. TBD's
  own spawn env sets none of these, but a user's free-form env override
  (global, repo, or profile scope) can — silently.

## Design

### Session naming — the one compiled change

`ClaudeSpawnCommandBuilder.build` gains an optional `sessionName`
parameter. When non-nil and non-empty, both the fresh-spawn and resume
branches append `--name <value>`, shell-escaped. The `cmd`/shell-fallback branches are
untouched, and Codex spawns are out of scope — messaging is a Claude
Code feature.

Callers pass the worktree's **display name** — the human-visible,
user-renamable name in the app — so `ListAgents` rows read the same as
the app sidebar. Without the flag, a session names itself
after its working-directory folder: the generated slug plus a random
suffix, which never matches an app rename. The flagged value lands
verbatim as the registry row's `name`, without the
`"nameSource": "derived"` marker the cwd-slug default carries — so the
listing distinguishes a deliberately named session from a self-named
one.

The display name is mutable and `--name` is fixed at spawn, so a rename
applies at the session's next respawn or resume; until then the running
session answers to its spawn-time name. This staleness is accepted:
respawns are frequent in TBD (wake, swap, fresh spawns), renames are
rare, and the listing carries the working directory and a per-session
identifier next to the name, so a stale name misleads no one who reads
the row.

#### The name is a label; the ref is the address

A name does not identify one session, and cannot be made to. Every
Claude session spawned in a worktree carries that worktree's display
name, and display names carry no uniqueness constraint of their own —
field measurement on one host found 16 worktrees running more than one
Claude terminal (four in the largest) and one pair of worktrees already
sharing a display name. Spawn-time staleness adds a second way for a
name to answer for the wrong session, but multiplicity is the dominant
one and exists even when every name is current.

Disambiguation therefore belongs at the addressing layer, not the naming
one. `ListAgents` prints a short `[ref]` beside each row, unique per
live session, and a sender addresses a peer it has not messaged before
as `name [ref]` — a bare name may be refused with an error naming the
ref, measured even where exactly one row answered to that name, and the
ref is likewise how a sender picks between rows sharing a name. Once a
message to that peer has gone through, its bare name works. Keeping
`--name` as the unadorned display name is what makes the
listing legible against the app sidebar — a human reading either surface
sees the same words — while the ref is what makes a row addressable.
Decorating the name to force uniqueness would trade the first property
away to duplicate the second.

### CLI version floor: 2.1.76, documented rather than gated

`--name` is emitted unconditionally. `-n` / `--name` shipped in CLI
v2.1.76 (published 2026-03-14, per the Claude Code changelog and npm
registry; verified accepted on v2.1.226), so TBD's Claude spawn path
requires CLI ≥ 2.1.76 — a five-month floor on a tool that self-updates
by default, and one strictly looser than what the feature itself needs:
messaging arrived in 2.1.224. A session on 2.1.76–2.1.223 gets a correct
name and simply lacks the messaging tools.

On a CLI below the floor the failure is loud and self-describing, not
silent: measured against v2.1.226, a spawn-shaped invocation carrying an
unknown option exits 1 with `error: unknown option '--…'` before doing
anything else, so the pane shows exactly what to fix (`--version` and
`--help` are the exceptions — they short-circuit and succeed
regardless). The docs page states the floor.

No feature flag for `--name`: it acts on no timer, destroys no state,
and replaces no load-bearing path — it is small additive spawn surface.
The registry mirror is the other unflagged change here, and it carries
its own argument below rather than borrowing this one.

### Cross-profile discovery

Sessions on different TBD profiles discover and message each other.
Profile isolation exists for credentials, not for reachability.

The peer registry is `$CLAUDE_CONFIG_DIR/sessions/`: one small JSON row
per live session, named `<pid>.json`, holding the pid, session id,
working directory, tmux pane, the session's message socket path
(`messagingSocketPath`), its `name` and `nameSource`, and a coarse
`status` (`idle` / `busy` / `waiting` / `shell`) with an `updatedAt`
timestamp. No transcript content. The message sockets themselves live
outside the config dir, at `/tmp/cc-socks/<pid>.sock`, and are therefore
already shared per OS user.

Fragmentation is entirely in the index. Because the registry hangs off
`CLAUDE_CONFIG_DIR`, each TBD profile keeps its own, and sessions on
different profiles are mutually invisible — field measurement found 24
live sessions in one profile that a session in another profile could not
list. Since the sockets are already whole across the OS user, unifying
the index is sufficient; no transport work exists.

The fix is one entry: `sessions` joins `ClaudeProfileConfigDirManager`'s
host-mirror slots, so each profile's `claude/sessions` is a symlink to
the host store's `sessions` directory — the same mechanism that already
carries `projects`, `plugins`, `hooks`, `skills`, and `settings.json`.
Seeding is idempotent and failure is non-fatal (log and continue),
matching the plugin and overlay writers.

#### Creating the host directory, and the guards on doing so

The host `sessions/` directory is created if absent, at mode `0700` —
field-measured, not assumed: the host directory and every profile-local
one on the measured machine are `drwx------`, so a TBD-created directory
is indistinguishable from one the CLI would have made and peer rows are
never world-readable.

Creating it at all is where this slot departs from the other eight.
Those mirror host *customizations*, so an absent host entry means "the
user does not use this" and skipping is right. An absent `sessions/`
means only that no session has registered on this machine yet — skipping
would silently no-op and leave that machine's profiles fragmented
forever, which is the exact failure the slot exists to prevent.

Two guards bound the creation:

- **The host base directory must already exist.** TBD mirrors into a
  host Claude store; it never conjures one. With no host store on the
  machine, the slot is skipped rather than materialized.
- **The host entry, if present, must be a directory.** A regular file or
  a dangling symlink in that position is refused with a warning instead
  of being symlinked into every profile, where it would wedge the slot
  behind a target no session can write a row into.

#### Pre-existing profile-local rows are merged, not set aside

Every other non-`projects` slot moves pre-existing profile-local content
to a `<slot>.profile-local` sidecar before symlinking. That policy is
right for cold user content and wrong here, because the registry holds
**live process state**. Field measurement on one host: four profiles
held 48 rows between them, 47 of them belonging to processes still
running. Seeding also runs on every spawn, not once at profile creation,
so the directory it encounters is a live one by default rather than by
accident.

A sidecar would move running sessions' rows out from under their own
processes. Those sessions would drop out of every peer's listing while
still running, and their rows would be orphaned permanently: a session
unlinks its row by path at exit, and that path — once the symlink is in
place — resolves to a host location where the row was never written. The
sidecar would then accumulate dead rows nothing ever cleans up.

Merging avoids all of it and is collision-free by construction. Rows are
named `<pid>.json` and PIDs are unique per OS user, so the same filename
can appear on both sides only when one row is a stale leftover from a
dead process whose pid was later reused; there the newer row wins. The
rows move into the host directory, the emptied profile directory is
removed, and the symlink takes its place. The result is that the
migration **adopts** already-running sessions into the shared registry
instead of hiding them.

#### No feature flag for the mirror

The mirror ships unflagged on its own merits, not by extension of the
`--name` argument:

- **It destroys nothing** — no row is set aside, discarded, or made
  unreachable. The single loss case is a duplicate filename, where the
  older of two rows is dropped; by the argument above that row belongs
  to a dead process.
- **The operation class is precedented** — `projects` already merges
  profile content into the host store through the same function, over
  transcript data, which is far more valuable than an address book.
- **It is user-initiated** — seeding runs in response to a spawn the
  user asked for. It acts on no timer, kills no process, and replaces no
  load-bearing path.
- **Rollback is a single removal** — delete the symlink and the profile
  is back to a private registry. The rows stay valid where they are;
  nothing needs unpicking.

The flag rule exists for behavior that acts on its own or can lose
state. This does neither, and a flag would buy only the ability to keep
profiles fragmented — the condition the change exists to end.

Three consequences, stated plainly:

- **The user's own terminal sessions join the pool.** The symlink target
  is the host store, not some TBD-private directory, so plain-terminal
  `claude` sessions under the same OS user and TBD sessions become
  mutually discoverable. That is the intended reach, not a leak: the
  boundary the feature draws has always been the OS user.
- **Only discovery changes.** A registry row carries no transcript
  content, and `projects/` — where transcripts live — is already a host
  mirror, so nothing newly crosses a profile boundary but the index.
  Row freshness is unaffected: a session writes its own status row, so
  the row is equally fresh whichever directory the file lives in.
- **TBD's own session-ID recapture starts working for profile
  terminals.** `ClaudeStateDetector` recaptures a session id by reading
  `<host claude home>/sessions/<pid>.json` — the same registry, read for
  a different purpose. Before the mirror that read missed for every
  terminal spawned on a profile, because the row was written into the
  profile's config dir and the detector only ever looked at the host
  store. With the mirror the two paths are the same file, so recapture
  after a `--fork-session` resume now succeeds for profile terminals
  where it previously did not. This is an intended consequence of
  unifying the registry, not a side effect to be tidied away: a test
  pins the detector reading through the mirrored path, so a later reader
  cannot "fix" it back onto per-profile paths without the failure being
  visible.

### Skill content

`TBDSkillContent.body` gains a short section stating the channel as
fact: sibling TBD sessions are reachable with `ListAgents` /
`SendMessage` when the installed Claude Code supports messaging, and
`tbd terminal send` / `tbd terminal output` is the daemon-mediated
alternative that can also drive input into a session. Both channels are
described; neither is recommended over the other. The text is phrased so
a session on a CLI without messaging falls back to `tbd terminal send`
naturally.

### Inbound policy is user-land, already

Because TBD sessions all bypass permission prompts, the class-based
default already delivers TBD↔TBD messages. A repo that wants a different
policy sets `crossSessionInbound` (`accept` / `hold` / `refuse`) in its
`claude-settings.json`, which deep-merges into TBD's per-spawn
`--settings` overlay today. Documented in the docs page; no code.

### Supervision and the actuation record

Native peer messages travel session-to-session over Claude Code's
sockets and never transit the daemon. They are therefore outside TBD's
actuation record — in both directions, deliberately. The record's
integrity claim is unchanged in kind but explicit in scope: it attests
everything sent **through TBD's transport**, and nothing else.
Supervision programs (sweep, wake, playbooks) may use the native channel
as authored content, accepting that such messages are evidenced only by
the participating sessions' own transcripts. The fleet-supervision
design is untouched by this: its record claims only the acts the daemon
executes.

### Documentation page

`docs/cross-session-messaging.md` covers, for TBD users:

- the version story: TBD's spawn path requires CLI ≥ 2.1.76 (`--name`),
  messaging needs ≥ 2.1.224, and how to confirm a session has the
  feature (`/list-agents`, `/status` peer-address row);
- the killswitch env vars above, with the warning that setting one via
  TBD env overrides silently disables messaging;
- naming and addressing: sessions answer to the worktree display name,
  renames apply on next respawn/resume, and the `[ref]` from
  `/list-agents` is what a sender uses when several rows share a name;
- the per-repo `crossSessionInbound` recipe;
- reach: same OS user on one machine — across every TBD profile and the
  user's own plain-terminal sessions; same account and reply-only beyond
  it; native peer messages are not in TBD's actuation record;
- the registry: where it lives, what a row holds, that it holds no
  transcript, that TBD unifies it across profiles by symlinking to the
  host store, and that a profile's own pre-existing rows are merged in
  so running sessions stay listed;
- what to do when an expected peer is missing: seeding is best-effort,
  so `/list-agents` is the authority on who can be addressed.

## Failure modes

- **Messaging absent** (older CLI, killswitch env, unsupported
  provider): sessions simply lack the tools; coordination falls back to
  `tbd terminal send` per the skill text. No TBD surface breaks.
- **CLI below the 2.1.76 floor**: every Claude spawn fails in the pane
  with `error: unknown option '--name'` — loud, immediate, and fixed by
  updating the CLI. Accepted in exchange for not building a version
  probe (see Rejected alternatives).
- **Registry symlink seeding fails** (I/O error, no host store yet, or a
  host `sessions` entry that is not a directory): log and continue; the
  profile works normally, but its sessions discover only peers that
  share its own config dir. `ListAgents` in a session is the authority
  on who is reachable — a peer absent from the listing cannot be
  addressed, whatever the sender expected.

## Testing

- Builder unit tests: `--name` emitted and escaped; omitted when
  `sessionName` is nil or empty.
- Skill-content test asserting the messaging section is present.
- Registry-mirror tests through the existing
  `ClaudeProfileConfigDirManager(baseDirectory:hostBaseDirectory:)`
  seams: the `sessions` symlink is created and points at the host store;
  seeding is idempotent across repeated calls; the host directory is
  created when absent, at mode `0700`; creation is skipped when the host
  base directory does not exist; a host entry that is a regular file or
  a dangling symlink is refused, leaving no symlink behind; a
  pre-existing profile-local `sessions/` has its rows merged into the
  host directory, with the emptied profile directory removed and
  replaced by the symlink; and where the same `<pid>.json` exists on
  both sides, the newer row is the one that survives.
- A detector test pinning that `ClaudeStateDetector` reads the session
  file through the host store — the path the mirror makes reachable from
  a profile terminal — so the recapture coupling above is not silently
  undone.

All via `scripts/test.sh`.

## Rejected alternatives

- **A TBD-mediated send path (`tbd message`, daemon speaking the peer
  socket protocol)** — would put peer messages in the actuation record,
  but couples TBD to an unversioned wire format at the wrong layer, the
  same class of coupling the no-screen-scraping rule exists to prevent.
  Rebuild-worthy evidence: a supervision incident that turns on proving
  a peer message was or was not sent, where session transcripts were
  insufficient.
- **Compiled channel preference (native messaging vs.
  `tbd terminal send`)** — which channel a session should use is a
  theory two reasonable projects answer differently; it fails the
  placement battery's first test. Both channels are stated as facts and
  the choice stays with the session and its operator.
- **Live `/rename` push on display-name change** — keeps names current
  by injecting input into a running session's composer, the same risk
  class that forced `auto_hibernate_enabled` off. A cosmetic win priced
  at a default-off flag and a soak; spawn-time naming with accepted
  staleness costs neither.
- **Compiled inbound policy (shipping a `crossSessionInbound` value in
  the overlay)** — the class-based default already delivers TBD↔TBD
  traffic, and the per-repo overlay merge gives users the knob with zero
  code. Shipping `accept` would also loosen delivery from the user's
  non-TBD sessions without being asked.
- **Slug instead of display name** — immutable, so never stale, but it
  reproduces what the cwd-derived default already provides and never
  matches what the user sees in the app. It also buys no uniqueness: a
  slug is per-worktree just as the display name is, so the several
  Claude sessions one worktree runs would still share it, and two
  worktrees with the same display name would still collide. Ambiguity is
  resolved by the `[ref]` in the listing whatever the name says, which
  leaves the slug trading the sidebar match for staleness relief alone.
- **A `claude --version` capability probe gating `--name`** — a daemon
  probe (run once, cached, plumbed to the builder as a capability bit)
  would spare users on a pre-2.1.76 CLI from failing spawns. The
  population it protects is anyone more than five months behind on a
  self-updating CLI, the failure it prevents is loud and
  self-describing rather than silent, and the feature the naming serves
  needs 2.1.224 anyway — so the probe subsystem, its cache, and its
  branch tests buy almost nothing. Rebuild-worthy evidence: field
  reports of spawn failures from users legitimately pinned below
  2.1.76 (e.g. an enterprise-frozen CLI).
