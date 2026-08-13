# Remote agent provider contract (v1)

This document specifies the contract a **provider** must implement to plug a remote agent backend into TBD. A provider is a single executable, registered with TBD, that manages agent sessions running somewhere TBD doesn't otherwise reach — a cloud VM, a container service, a remote SSH host, or similar. TBD owns this contract; providers own everything about how they actually reach and run sessions. This document is normative: an implementation that satisfies it is a valid provider regardless of what transport or vendor APIs it uses internally.

## Overview & invocation model

TBD invokes the provider executable as `<exec> [args...] <verb> [flags]`. Depending on the verb, TBD may pass structured input on stdin and reads either a single JSON object or an NDJSON stream from stdout. stderr is diagnostic only — TBD logs it but never parses it.

Every invocation runs with `TBD_CONTRACT_VERSION=1` set in the environment (see Versioning below), and the provider inherits the caller's full login environment.

Four verbs are **required**. The rest are optional and declared as **capabilities** via `describe`.

## Verb table

| Verb | Required? | Invocation | stdin | stdout | Timeout |
|---|---|---|---|---|---|
| `describe` | required | `<exec> describe` | — | JSON | 10s |
| `create` | required | `<exec> create` | JSON | JSON session | 60s |
| `list` | required | `<exec> list` | — | JSON `{sessions:[...]}` | 30s |
| `stop` | required | `<exec> stop <id>` | — | JSON session | 30s |
| `log` | capability `log` | `<exec> log <id> [--lines N]` | — | raw bytes | 30s |
| `send` | capability `send` | `<exec> send <id>` | raw bytes | JSON `{}` | 30s |
| `rename` | capability `rename` | `<exec> rename <id> <title>` | — | JSON session | 30s |
| `set-profile` | capability `set-profile` | `<exec> set-profile <id>` | JSON profile | JSON session | 60s |
| `attach` | capability `attach` | `<exec> attach <id>` | TTY | TTY | unbounded |
| `events` | capability `events` | `<exec> events` | — | NDJSON stream | unbounded |

## Session object

This is the one shape every verb that returns session data shares:

```json
{
  "id": "fix-flaky-ci",
  "title": "fix flaky CI",
  "created_at": "2026-07-24T18:02:11Z",
  "state": "starting|running|exited",
  "exit_code": 0,
  "agent_state": "working|waiting_input|idle|exited|unknown",
  "agent_state_reason": "permission_prompt",
  "agent_state_at": "2026-07-24T18:40:00Z",
  "meta": {"repo": "acme/api", "branch": "fix-ci"}
}
```

Session state is two independent axes:

- **`state`** — terminal/session liveness only (`starting`, `running`, `exited`). It says whether the underlying process, container, or instance is alive; it says nothing about the agent's activity or health.
- **`agent_state`** — "does a human need to look at this" (`working`, `waiting_input`, `idle`, `exited`, `unknown`). **Normative rule: `agent_state` MUST be derived from machine interfaces — agent lifecycle hooks, transcript files, process exit codes — and MUST NEVER be inferred by parsing rendered terminal output.** Screen text is a display surface, not a state API: scraping it breaks silently when rendering changes and produces false signals. A provider with no such instrumentation available MUST report `"unknown"` rather than guess. `state: "running"` with `agent_state: "unknown"` means only that the terminal/session is present and no machine-readable agent state is available; it never means healthy, idle, or finished. If machine-readable instrumentation reports that the agent produced final output and is waiting for another instruction, the provider SHOULD report `"idle"`; without that instrumentation it remains `"unknown"`.

Other fields:

- `exit_code` is present if and only if `state` is `"exited"` and the code is known.
- `meta` is a flat string-to-string map of provider-defined display pairs. The keys `repo`, `branch`, and `profile` are well-known: a caller MAY interpret them (for example, to look up PR status for that repo/branch pair, or to show which identity a session is currently running as) when present — mirroring how `create_params` already blesses well-known field names below. Providers are not required to supply `repo`, `branch`, or `profile`, and a caller MUST degrade gracefully when any are absent (falling back to opaque rendering, or simply showing nothing extra). Two further well-known keys, `tbd_worktree_id` and `tbd_parent_worktree_id`, are specified under Worktree identity keys below. Every other key, and any well-known key whenever a caller has no special handling for it, are rendered as opaque detail rows — the caller never interprets arbitrary `meta` keys or values beyond this well-known set. When present, `meta.profile` is the display name of the profile the session is currently running as (a plain string — the profile's `name`, not the full profile object below) — a provider that supports the `profile` and/or `set-profile` capabilities SHOULD keep it current across `create` and any later swap, so any other client of the same backend can see which identity a session runs as without maintaining its own state.

The condition worth notifying a human about is an **edge** in `agent_state` — a transition into `waiting_input` or `exited` — not the value in isolation.

### Worktree identity keys (optional)

Two further `meta` keys are well-known, on the same terms as `repo`, `branch`, and `profile`: `tbd_worktree_id` and `tbd_parent_worktree_id`. They are how a session tells TBD which lane it *is* and which lane spawned it. Both are optional, and both are additive within contract v1 — a provider that sets neither is fully conformant and behaves exactly as it does today.

TBD reads them exactly once per session, when it first creates the worktree row that represents the session (**adoption**). A session that resolves to a repository TBD has registered gets exactly one such row; a session that resolves to no registered repository gets none, and neither key changes that. Once the row exists it is never re-derived: a later value for either key on a later `list` or `events` sighting is ignored, because the row's identity and its position in the tree are the user's to change from that point on.

- **`tbd_worktree_id`** — the session's own lane identity, as a UUID string. TBD's lane identifier for a session is exported into that session's environment as `TBD_WORKTREE_ID`, which is what lets an agent running inside the session use TBD verbs keyed on ambient identity. A provider that knows this value SHOULD echo it here, because the echo is what makes the binding self-healing: if TBD loses the row after the session is already running, echoing the id lets TBD recreate the row under the same identity rather than minting a second one and stranding the variable the session already exported.
  - **Absent** – TBD mints a fresh identifier for the row. Nothing is lost except self-awareness inside the session.
  - **Not a UUID** – ignored with a warning, and TBD mints a fresh identifier. The session still gets its row.
  - **Names a worktree TBD already has that is not this session** – ignored with a warning, and TBD mints a fresh identifier. The existing row is never rebound, renamed, reparented, or otherwise touched. The identifier could name a local worktree or another provider's lane, and no session may take a row over by claiming its id.
  - **Names nothing yet** – the row is created with that identifier. This is the case the echo exists for.

- **`tbd_parent_worktree_id`** — the identifier, again as a UUID string, of the worktree that spawned this session. TBD uses it to nest the session's row beneath that lane in its tree, so a fan-out reads as a hierarchy rather than a flat list. The edge is presentation only: it never affects the session's git base, and TBD never reports it back to the provider.
  - **Absent, or not a UUID** – the row is created at top level in its repository. The user can move it afterwards.
  - **Names a worktree TBD does not have** – same: top level.
  - **Names an archived worktree, or a repository's main worktree** – same: top level, and the edge is not stored at all. TBD does not render either row's descendants, so nesting a live session beneath one would file it where nobody can find it.
  - **Names a live worktree** – the row is nested beneath it.

A provider that populates these keys is describing TBD-side facts it was told, not facts it discovered. It MUST NOT invent either value — an identifier the provider made up would name no lane, and for `tbd_worktree_id` it would defeat the echo it is meant to serve.

### Pending question (optional)

A provider MAY include a `pending_question` field on the Session object describing a structured choice the agent is currently blocked on — for example, a multiple-choice prompt the agent's own tooling surfaced, which a calling application would otherwise only see as `agent_state: "waiting_input"` with no further detail.

```json
{
  "pending_question": {
    "id": "q-4f2a1c",
    "questions": [
      {
        "prompt": "Which environment should this change deploy to?",
        "label": "Environment",
        "multi": false,
        "options": [
          {"label": "staging", "description": "Deploy to the staging cluster"},
          {"label": "production", "description": "Deploy to the production cluster; requires a follow-up approval"}
        ]
      }
    ]
  }
}
```

- `id` — a stable identifier for this question, opaque to the caller. It stays the same while the same question is still pending and changes when the agent asks a new one, so a caller can tell "still waiting on the same thing" apart from "a new question just appeared" without diffing question text.
- `questions` — one or more question objects presented together (an agent MAY ask more than one structured question in a single blocking turn). Each has:
  - `prompt` (required) — the question text.
  - `label` (optional) — a short label for compact rendering (a tab title, a form field caption) where the full `prompt` doesn't fit.
  - `multi` (optional, default `false`) — whether more than one option may be selected.
  - `options` (required, one or more) — each an object with `label` (required, the option's display text) and `description` (optional, supporting detail).

**Lifecycle.** `pending_question` is present only while the agent is blocked on this specific question; it MUST be absent once the question is answered or abandoned (for example, because the session was stopped, or the agent moved on some other way).

Its presence is display detail layered on top of `agent_state`, never a substitute for it. A provider that reports `pending_question` MUST keep it consistent with `agent_state` — report `agent_state: "waiting_input"` for exactly as long as `pending_question` is present, and clear both together — and a caller MUST NOT infer that a session is blocked solely from `pending_question`'s presence; blocking is still read off `agent_state`, same as every other session.

**Optionality and degradation.** This field is entirely optional. A provider with no way to surface structured question data — including one with no concept of structured questions at all — simply never sets it and remains fully conformant; it MUST NOT fabricate a single-option question just to answer the general `waiting_input` case. A caller renders a session with `agent_state: "waiting_input"` and no `pending_question` exactly as it always has (a generic "needs input" state), and renders one with `pending_question` present with the richer card. No capability gates this field: it rides on the Session object returned by verbs (`create`, `list`, `stop`, `events`) that already exist, rather than introducing a new verb, so it follows the same rule as `meta`'s well-known keys above — a provider either populates it or doesn't, and a caller that doesn't recognize it ignores it per the response-field forward-compatibility rule in Versioning below.

**Answering.** `pending_question` is display data only — it does not add a way to answer. Answering a pending question uses the mechanisms this contract already has: attach interactively and answer the prompt directly through the terminal (`attach`), or deliver the chosen option's text as input (`send`). No dedicated "answer" verb is introduced in v1. A future answer verb, if one is ever added, would need to solve two things this field alone does not: submitting a choice when no terminal is attached (so `send`'s raw-keystroke delivery isn't available), and confirming which specific `pending_question.id` the answer was directed at (`send` has no notion of a question at all, so it can't tell the provider which pending question the bytes are meant to resolve).

**Machine-interface rule.** The same normative rule that governs `agent_state` applies here without exception: `pending_question` MUST be derived from the agent's own machine interface — its lifecycle hooks or structured tool output — and MUST NEVER be constructed by parsing rendered terminal output, including the bytes `log` returns. A provider that cannot source it this way MUST simply omit the field, exactly as it MUST report `agent_state: "unknown"` rather than guess.

## Profile object

A **profile** selects an agent's identity and routing: which credential it authenticates with, and which model or endpoint it talks to. Profile and location are orthogonal — this object never says *where* a session runs (that's a property of which provider, if any, a session belongs to), only *who* it runs as.

Only a profile's name and routing may cross the process boundary to a provider — never its credential. This object is a **projection**, not a snapshot: it exists specifically because it excludes secret material, which makes it safe to hand to a provider.

```json
{
  "name": "acme-default",
  "kind": "oauth",
  "routing": {
    "model": "acme-large-v2",
    "base_url": "https://api.example.com",
    "aws_region": "us-east-1",
    "aws_profile": "acme-bedrock"
  },
  "env": {"ACME_FEATURE_FLAG": "1"},
  "credential_ref": "acme-vault://oauth/acme-default"
}
```

Every field is optional, and the whole object is optional wherever it appears — an absent `profile` means "the provider's default identity."

- `name` — display name for the identity, shown to a human.
- `kind` — `oauth`, `api_key`, or `bedrock`.
- `routing` — model/endpoint selection: `model`, `base_url`, and (for `bedrock`) `aws_region`/`aws_profile`. A provider applies whichever sub-fields the caller supplies and falls back to its own default for the rest.
- `env` — the profile's own flat string-to-string env overrides (routing-adjacent settings — not secrets; see below).
- `credential_ref` — an opaque string the provider resolves against its own secret store. The caller never interprets it; it means nothing outside the provider that issued it.

**Normative rules:**

- This object MUST NOT contain credential material of any kind.
- A caller MUST NOT put secrets in `env`.
- A provider MUST NOT echo this object into logs it doesn't own.
- `credential_ref` is opaque to the caller; only the provider that issued it knows how to resolve it.

Why credentials never travel, by kind:

- **`oauth`** — an OAuth credential's refresh token rotates on every refresh. Pushing a snapshot of one would create two independent refreshers racing on a single rotating token, and the loser's copy silently goes stale. There is no representation of an OAuth credential that is safe to transport, so `oauth` profiles only ever cross via `credential_ref`.
- **`api_key`** — an API-key secret is technically transportable, but pushing one would send it through a process the caller doesn't audit, and leave the caller with no rotation or revocation story for a copy it can no longer see. So `credential_ref` is used instead here too, even though the constraint is policy rather than physics.
- **`bedrock`** — has no secret material to transport in the first place: `routing.aws_profile` names an AWS profile/role the provider assumes using its own credential chain. `credential_ref` is typically absent for this kind.

> **Implementation note (non-normative).** A provider whose box keeps one config directory per identity — each bootstrapped once, the first time a given `credential_ref` is used — can realize both `create`'s `profile` field and `set-profile` by pointing the agent process at a different config directory and restarting it — the same technique a calling application typically uses to manage profiles for sessions it runs locally. This costs one bootstrap **per identity per box**, not per swap and not per session: once a directory exists for a given identity, every later `create` or `set-profile` against that identity just reuses it — profile swapping does not imply continuous credential syncing. This is guidance, not a requirement: the contract stays agnostic to whether a provider uses this layout, a different one, or no persistent identity at all, and it must not be read as assuming git, tmux, or any particular agent.

## `describe`

**`describe` MUST answer entirely from static local data: no network calls, no authentication.** Callers invoke it at registration time and at every application start; an expired credential or unreachable backend must never be able to break that.

```json
{
  "contract_versions": [1],
  "name": "example-provider",
  "provider_version": "0.4.2",
  "capabilities": ["log", "send", "attach", "events", "rename", "profile", "set-profile"],
  "create_params": [
    {"name": "repo",   "type": "string", "label": "Repository", "required": true},
    {"name": "branch", "type": "string", "label": "Branch", "default": "main"},
    {"name": "prompt", "type": "text",   "label": "Initial prompt"},
    {"name": "size",   "type": "enum",   "label": "Size", "values": ["small","large"], "default": "small"}
  ],
  "profile_kinds": ["oauth", "api_key", "bedrock"],
  "credential_ref_hint": "acme-vault path, e.g. acme-vault://oauth/<name>"
}
```

- `contract_versions` — every contract major version this provider supports (see Versioning).
- `name` — a stable machine identifier for the provider (used, along with each session id, as the caller's key for this provider's sessions).
- `capabilities` — which optional verbs/features (`log`, `send`, `attach`, `events`, `rename`, `profile`, `set-profile`) this provider implements. `profile` gates whether `create`'s `profile` field is honored (see `create` and the Profile object above); `set-profile` gates the verb of the same name.
- `create_params` — a flat field list, not a JSON Schema, describing the form for `create`. Supported `type` values: `string`, `text`, `bool`, `int`, `enum`. The caller renders this generically (the most complex widget is an enum dropdown) and only does required/type checks client-side — the provider is the validator of record, via the error model below. The field names `repo`, `branch`, `prompt`, and `title` are well-known: a caller may prefill them from ambient context (e.g. a currently selected repository) when present.
- `profile_kinds` and `credential_ref_hint` are meaningful only when `capabilities` includes `profile`; a provider without that capability SHOULD omit both, and a caller MUST ignore them if present without it. `profile_kinds` lists which `kind` values (from the Profile object above) this provider can actually realize. `credential_ref_hint` is placeholder text — not validation — describing the shape of a `credential_ref` this provider expects; a caller shows it as placeholder text in its credential-reference input.

`describe.capabilities` reports **interface capabilities**: which contract verbs TBD may call. It does not prove that a session has the external **task capabilities** a workload needs. A provider or workflow that claims ownership transfer or completion MUST preflight the concrete external capabilities required by that task and fail visibly before transfer when they are unavailable. Successful `create`, `state: "running"`, or `send` handoff proves only that the corresponding contract or transport step succeeded; it does not prove workload permission. The provider or higher-level workflow owns this preflight because TBD cannot infer vendor-specific permissions from the provider contract.

## `create`

stdin:

```json
{
  "params": {"repo": "acme/api", "branch": "fix-ci", "prompt": "..."},
  "profile": {"name": "acme-default", "kind": "oauth", "credential_ref": "acme-vault://oauth/acme-default"},
  "idempotency_key": "tbd-9a1c..."
}
```

`profile` (optional) is a Profile object (see above) selecting the identity the new session's agent should run as. It is meaningful only when the provider declares the `profile` capability; a provider that doesn't declare it MUST ignore the field — per the ignore-unknown-fields rule in Versioning — and create the session against its own default identity rather than error. An absent `profile` always means the provider's default identity, regardless of capability.

If `create_params` exposes the well-known `prompt` field, the provider owns clearing any agent startup or trust gate before delivering that prompt. Writing prompt bytes while another interactive gate owns the TTY does not count as delivery. Providers SHOULD use agent flags or machine interfaces to clear and verify such gates, and MUST NOT infer readiness by parsing cosmetic TUI output.

Response: a Session object.

`create` MUST return within seconds. If provisioning is slow, return immediately with `state: "starting"` and let `list` (or `events`) carry the session to `running` later.

The caller may retry a timed-out `create` call using the **same** `idempotency_key`. The provider MUST dedupe on this key: replaying a key that already produced a session returns that same session rather than creating a duplicate. This is what makes "the transport timed out but the session actually started" safe to retry.

## `list`

Returns `{"sessions": [Session, ...]}`.

Providers SHOULD keep exited sessions listable for at least 24 hours (with `state: "exited"`) rather than dropping them from the list immediately. A session disappearing from the list is indistinguishable from transport drift unless exited sessions stick around long enough to be told apart from a genuine loss.

A transport-overload or unreachable failure MUST be returned as a transient error (exit 3), never as a successful empty list. The caller keeps its last successful snapshot and marks the provider stale; an empty successful snapshot instead counts toward the two-absence rule and can incorrectly mark live sessions gone.

## `stop <id>`

Terminates the session. Whether termination is graceful, forceful, or graceful-then-forceful is entirely the provider's business.

`stop` is idempotent: stopping an id that is already dead, or unknown, exits 0 and returns the session in a terminal state — at minimum `{"id": "...", "state": "exited"}`. There is no separate archive/done verb; anything like archival is state the caller keeps on its own side.

## `log <id> [--lines N]`

Writes raw scrollback bytes to stdout: the last `N` lines (default 2000), with ANSI passthrough intact. This is display data for a read-only view, not a JSON envelope.

Rendering scrollback to a human is not the thing the machine-interface rule (above) forbids — that rule is about *inferring `agent_state`* from rendered text. Showing the same text to a human to read is fine.

## `send <id>`

stdin bytes are delivered verbatim to the session as keystrokes. The provider does not add a terminator. When a caller means the terminal Enter key, it MUST append carriage return (`\r`, byte `0x0D`); line feed (`\n`, byte `0x0A`) is not equivalent in a raw PTY and may fail to submit the line. Exit 0 means the bytes were handed to the transport, not that the agent has acted on them.

## `rename <id> <title>` (optional)

`<title>` is passed as a single argv value — TBD invokes the provider directly, never through a shell, so the caller need not shell-escape it, and the provider must accept it verbatim including spaces. Response: the updated Session object (with `title` reflecting the new value).

This lets a caller push a display name to the provider so other clients of the same backend — another machine, or the provider's own UI — see it too. The verb is optional and declared via the `rename` capability, and MUST stay optional: a caller keeps its own display name for a session regardless of whether the provider can persist one, so a provider that cannot support renaming (or cannot support it for some sessions) remains fully usable without it. A caller SHOULD invoke `rename` when the capability is present so the name doesn't drift between clients, but MUST NOT require it to succeed in order to rename a session locally.

Failure follows the standard error model below (for example, exit 1 with `code: "not_found"` if `id` no longer exists).

## `set-profile <id>` (optional)

Swaps the identity a running session's agent process authenticates and routes as, in place — without recreating the session.

stdin: a Profile object (see above) — the same shape `create`'s `profile` field takes.

Response: the updated Session object.

**Normative semantics:**

- The workspace and session identity are preserved: the `id` in the response MUST be the same `<id>` passed on the invocation line.
- The agent process is restarted against the new identity (a new `credential_ref`, `routing`, or both).
- The session MUST NOT be recreated — this is a live swap of an existing session, not stop-then-create.
- Scrollback preservation across the restart is the provider's business, not a contract requirement — but the session's identity and continued existence are not renegotiable regardless of whether scrollback survives.

This mirrors what a local swap already does for a session run directly by the calling application: kill the agent in place, respawn it against a different identity, and leave the workspace, session, and scrollback alone. `set-profile` exists so a provider whose box is laid out the same way — one config directory per identity — can offer that same seamless swap remotely (see the implementation note under Profile object above).

The verb is optional and declared via the `set-profile` capability. It is meaningful only alongside the `profile` capability — a provider that cannot accept a profile at `create` time has no default identity to swap away from, and SHOULD NOT declare `set-profile` without also declaring `profile`. A caller keeps its own record of which profile a session runs as regardless of whether the provider can accept a live swap; a provider without this capability remains fully usable, it just cannot be told to swap a running session's identity (only, if at all, at `create` time).

Failure follows the standard error model below: `not_found` if `<id>` no longer exists, `credential_unresolvable` if the profile's `credential_ref` doesn't resolve (see Error model), or `invalid_params` for a malformed profile object.

## `attach <id>`

The caller execs the provider directly on the controlling TTY of a terminal pane and gets out of the way — the provider becomes a live shim between that TTY and the remote session. This gives the provider a live hook to refresh credentials, retry a dropped channel, or exit with code 4 plus remediation on an auth failure.

**A successful attach MUST target the requested `<id>`.** If the provider
cannot establish that targeted attach, it MUST exit non-zero using the standard
error model; it MUST NOT silently fall back to a provider-wide session picker,
an unrelated session, or a plain remote shell. Human-facing commands outside
this contract may offer those fallbacks, but a machine caller cannot distinguish
such a terminal from a successful attach without parsing rendered terminal
output, which this contract explicitly forbids. A retryable targeting or
transport failure uses exit 3.

**Pane exit means the viewer detached — it never means the session is dead.** The only source of truth for whether a session is still alive is `list` (or `events`); `attach` exiting is purely a local, viewer-side event.

**`attach`'s stdout is a PTY byte stream and MUST NOT be parsed.** Unlike every other verb, there is no JSON object — not even the error object — to read here. A pre-connection auth failure still exits 4 per the error model below, and that **exit code alone** is what the caller correlates. A caller that wants the accompanying `message`/`remediation` gets it from a subsequent structured verb (`list`), never by reading attach's bytes.

(An alternative design where the provider prints a command line for the caller to exec instead was considered and rejected: it freezes credentials at print time, gives the provider no reconnect or cleanup hook once running, and leaks provider-internal argv into the caller's process table.)

## `events` (optional)

A long-running NDJSON stream: one JSON object per line, connection held open indefinitely.

```json
{"event": "hello", "contract_version": 1}
{"event": "snapshot", "sessions": [Session, ...]}
{"event": "session", "session": { ...Session object... }}
{"event": "removed", "id": "fix-flaky-ci"}
{"event": "ping"}
```

- Every connection MUST open with a `hello` event immediately followed by a `snapshot` event carrying the full current session list.
- **Snapshot-on-connect is the entire resync mechanism — there are no cursors, sequence numbers, or replay-from-offset.** If a caller misses a transition, the cost is one reconnect, which re-establishes full state via the next snapshot.
- `session` events carry the complete session object, never a partial diff. This makes them idempotent and safely replayable in any order relative to other `session` events.
- `removed` means the session should no longer be tracked at all (distinct from the session reaching `state: "exited"`, which is itself delivered as a `session` event).
- The provider MUST emit `ping` at least every 30 seconds while otherwise idle. A caller that sees 90 seconds of silence should treat the stream as dead, terminate the process, and reconnect.
- If the stream capability is absent, or a stream repeatedly fails to stay up, the caller falls back to polling `list` on an interval (on the order of 60s). Every provider gets at least this floor of freshness for free, whether or not it implements `events`.

## Channel granularity

`events` is a **provider-level** stream, not a per-session one: a provider runs exactly one `events` connection that carries state for every session it knows about, and every `snapshot`/`session`/`removed` event on that single stream can reference any session the provider has. A caller opens one `events` connection per provider, full stop — never one per session.

`attach`, by contrast, is inherently **per-session**: one connection per session, opened only while a viewer pane is actually looking at that session, and closed the moment the viewer detaches.

The two verbs differ in granularity because what they carry differs in shape. A provider's aggregate session state — the kind of thing `list` and `events` report — is comparatively small and shared: one connection is enough to keep every session's state current, because that state is a summary. An interactive terminal is the opposite: a live, two-way byte stream tied to one human looking at one session, with no meaningful way to multiplex two people's keystrokes for two different sessions over a single channel. Opening one `events` stream per session — rather than the one-per-provider this contract specifies — multiplies connection count by session count for no benefit, which matters against transports with per-account connection limits and non-trivial per-connection cost.

## Error model

Every verb signals failure through its process exit code:

| Exit | Meaning | Expected caller behavior |
|---|---|---|
| 0 | success | parse the result normally |
| 1 | permanent error | surface to the user; do not retry |
| 2 | usage/contract error | surface as a provider bug; log the full invocation |
| 3 | transient error | retry with backoff (bounded, e.g. up to 3 attempts for snapshot-style verbs) |
| 4 | auth needed | show a banner with remediation; pause further calls to this provider until one succeeds |

On a nonzero exit, the provider SHOULD emit one JSON error object on stdout:

```json
{
  "error": {
    "code": "auth_expired",
    "message": "credentials expired for profile acme-mgmt",
    "retryable": false,
    "remediation": {"label": "Run example-provider login", "command": "example-provider login --profile acme-mgmt"}
  }
}
```

Well-known `code` values in v1: `auth_expired`, `auth_missing`, `not_found`, `already_exists`, `unreachable`, `invalid_params`, `credential_unresolvable`. Providers may return other codes; callers should treat unrecognized codes as opaque strings and still show `message`.

`credential_unresolvable` means a `credential_ref` in a `profile` object didn't resolve against the provider's own secret store. It's distinct from `invalid_params` because the remedy is provisioning — registering or fixing the secret on the provider side — not correcting the shape of the request. It carries the same `remediation` shape as any other code:

```json
{
  "error": {
    "code": "credential_unresolvable",
    "message": "credential_ref \"acme-vault://oauth/acme-default\" not found in provider secret store",
    "retryable": false,
    "remediation": {"label": "Register credential in acme-vault", "command": "acme-provider credentials add acme-default"}
  }
}
```

If stdout on failure is not parseable JSON, the caller falls back to exit-code class plus the last few lines of stderr. On exit 4, a caller should present one actionable banner (for example, offering to run `remediation.command`) rather than a fresh error on every poll; any later invocation that succeeds clears that banner.

### Auth-needed state

The exit-4 row above is a per-invocation rule; this section specifies the state it puts the caller in, which the rest of the table doesn't need.

- **Auth-needed is a state of the PROVIDER, not of a session.** Exit class 4 from **any** verb — including `attach`, whose exit code is the only signal it has — means this provider cannot authenticate. It says nothing about whether any session is alive; per Identity & drift, only `list`/`events` speak to that.
- **Both signals count; neither overrides the other.** A caller classifies as auth-needed on the **union** of the two: exit class 4, **or** a parseable `code` of `auth_expired` / `auth_missing`. So a provider that exits 4 with a `code` the caller doesn't recognize (or with no parseable object at all) is auth-needed on the exit class, and a provider that exits 1 while naming `auth_expired` is auth-needed on the code, with its remediation intact. `credential_unresolvable` is **not** in this set: its remedy is provisioning, not re-authentication.
- **`remediation` is opaque.** A caller displays `label` and `command` verbatim and MAY offer to run the command, but MUST NOT interpret, parse, rewrite, or split it, and MUST NOT infer anything about the backend from it.
- **While auth-needed, keep polling.** "Pause further calls until one succeeds" (exit-4 row) means *stop starting new work* — in particular a caller SHOULD NOT spawn new `attach` processes, which would only die on connect. It does **not** mean going silent: the caller MUST keep its low-frequency `list` poll running, because that poll is the entire recovery mechanism. Pausing it would leave the state stuck until the user did something.
- **Recovery: the first subsequent SUCCESSFUL verb clears the state**, with no user gesture and nothing persisted. Auth-needed is runtime health only; it never survives across a caller restart on its own, it is simply rediscovered.

## Versioning

The contract version is a single integer major, exposed on every invocation as the `TBD_CONTRACT_VERSION` environment variable.

At registration, the caller invokes `describe`, intersects its own supported major versions with the provider's `contract_versions`, and picks the highest common value. If the intersection is empty, the caller refuses to use the provider and shows a clear error. Whatever major is chosen is what rides on every subsequent invocation via `TBD_CONTRACT_VERSION`.

Within a major version: providers may add new response fields at any time — a scalar or a structured object alike, such as `pending_question` on the Session object — and callers MUST ignore fields they don't recognize. This is symmetric: callers may send new optional fields in structured stdin (for example, `profile` on `create`) that an older provider doesn't recognize, and **providers MUST likewise ignore fields they don't recognize in structured stdin** rather than fail on them — the same forward-compatibility contract applies in both directions. Removing or renaming a field, or changing the semantics of a verb, requires a new major version. Adding a new optional verb — gated behind a new entry in `capabilities`, as `rename` and `set-profile` were — is likewise additive within a major version: a caller that doesn't recognize the capability string simply never invokes the verb, so no version bump is needed for it either.

## Identity & drift

- The provider mints session ids. An id MUST be opaque, unique within that provider, and durable across reboots of whatever the session runs on — derived from persisted state, not from a process id or an ephemeral index. The caller keys everything by the pair `(provider name, session id)`.
- The provider — via `list` and the `events` snapshot — is the source of truth for which sessions exist and their state. Any local record the caller keeps is a mirror, never authoritative.
- A session that is absent from **two consecutive** successful snapshots is considered gone by the caller — a distinct, visible state, not a silent deletion. A single absence is not enough to conclude this, since transports occasionally flake.
- If a caller observes a session id it has never seen before, it should adopt it — sessions created from elsewhere (another machine, or directly against the provider) are real and should be shown, not discarded.
- If the provider is unreachable, the caller's mirror goes stale-but-shown, with a staleness indicator. Unreachability of the provider is never equivalent to "the sessions are dead" — those are independent facts.
