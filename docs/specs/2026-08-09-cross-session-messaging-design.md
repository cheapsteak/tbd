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
  in tmux on the host under one user, so registry files and sockets are
  mutually visible. Sessions logged into different Anthropic accounts
  (different TBD profiles) can still message each other locally.
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
parameter. When non-nil, non-empty, and the installed CLI supports it
(next section), both the fresh-spawn and resume branches append
`--name <value>`, shell-escaped. The `cmd`/shell-fallback branches are
untouched, and Codex spawns are out of scope — messaging is a Claude
Code feature.

Callers pass the worktree's **display name** — the human-visible,
user-renamable name in the app — so `ListAgents` rows and message
addresses match the sidebar. Without the flag, a session names itself
after its working-directory folder: the generated slug plus a random
suffix, which never matches an app rename.

The display name is mutable and `--name` is fixed at spawn, so a rename
applies at the session's next respawn or resume; until then the running
session answers to its spawn-time name. This staleness is accepted:
respawns are frequent in TBD (wake, swap, fresh spawns), renames are
rare, and Claude Code tolerates the fallout — same-named or stale-named
sessions are disambiguated with short identifiers and working
directories in the listing.

Name collisions across worktrees are likewise Claude Code's problem,
handled the same way.

### Version gate on `--name`

An unrecognized flag on an older installed CLI would fail every Claude
spawn — a hard regression for users who have not updated. The daemon
therefore probes `claude --version` once and caches the result for its
lifetime; the spawn path passes the builder a `supportsSessionName`
capability bit, and the builder omits `--name` when it is false or the
probe failed. A failed or missing probe degrades to today's spawn
command — the probe must never block or break a spawn.

The minimum version that accepts `--name` is a field-verification item
(the flag may predate messaging itself); the constant lands with the
implementation. Both branches of the gate get tests, per the
conditional-gate rule in `CLAUDE.md`.

No feature flag beyond this gate: nothing here acts autonomously,
destroys state, or replaces a load-bearing path — `--name` is small
additive spawn surface.

### Cross-profile discovery

Requirement: sessions on different TBD profiles must discover and
message each other. Profile isolation exists for credentials, not for
reachability.

The peer registry's on-disk location is undocumented. Verification on a
macOS host with the feature comes first: spawn sessions under two
profiles (distinct `CLAUDE_CONFIG_DIR`s) and run `/list-agents` in
each.

- **If they see each other**, the registry is per-user, not
  per-config-dir, and no work exists.
- **If discovery is fragmented**, `ClaudeProfileConfigDirManager` adds
  one step to profile-dir seeding: symlink the registry subdirectory
  inside the profile's config dir to the default profile's registry
  location, so every profile shares one registry while credentials and
  `.claude.json` stay isolated. Seeding is idempotent and failure is
  non-fatal (log and continue), matching the plugin and overlay
  writers. The exact subdirectory name comes out of the same
  verification.

The contingent fix is not built until fragmentation is confirmed in the
field.

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
the participating sessions' own transcripts. The fleet-supervision spec
needs no amendment — its record only ever claimed acts the daemon
executed.

### Documentation page

`docs/cross-session-messaging.md` covers, for TBD users:

- the Claude Code version requirement and how to confirm a session has
  the feature (`/list-agents`, `/status` peer-address row);
- the killswitch env vars above, with the warning that setting one via
  TBD env overrides silently disables messaging;
- naming: sessions answer to the worktree display name; renames apply on
  next respawn/resume;
- the per-repo `crossSessionInbound` recipe;
- reach: same OS user on one machine; same account and reply-only beyond
  it; native peer messages are not in TBD's actuation record.

## Failure modes

- **Messaging absent** (older CLI, killswitch env, unsupported
  provider): sessions simply lack the tools; coordination falls back to
  `tbd terminal send` per the skill text. No TBD surface breaks.
- **Version probe fails** (claude not on PATH, unparseable output):
  builder omits `--name`; spawns behave exactly as today.
- **Contingent symlink seeding fails**: log and continue; the profile
  works, discovery may be fragmented for it.

## Testing

- Builder unit tests: `--name` emitted and escaped; omitted when
  `sessionName` is nil or empty or `supportsSessionName` is false.
- Version-probe parse tests against real and malformed
  `claude --version` output; probe-failure path yields the degraded
  capability bit.
- Skill-content test asserting the messaging section is present.
- Contingent: symlink-seeding idempotency and isolation tests through
  the existing `ClaudeProfileConfigDirManager(baseDirectory:hostBaseDirectory:)`
  seams.

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
  matches what the user sees in the app.
