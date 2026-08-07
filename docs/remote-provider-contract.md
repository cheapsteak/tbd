# Remote agent provider contract (v2)

This document specifies the contract a **provider** must implement to plug a remote agent backend into TBD. A provider is a single executable, registered with TBD, that manages agent sessions running somewhere TBD doesn't otherwise reach — a cloud VM, a container service, a remote SSH host, or similar. TBD owns this contract; providers own everything about how they actually reach and run sessions. This document is normative: an implementation that satisfies it is a valid provider regardless of what transport or vendor APIs it uses internally.

## Overview & invocation model

TBD invokes the provider executable as `<exec> [args...] <verb> [flags]`. Depending on the verb, TBD may pass structured input on stdin and reads either a single JSON object or an NDJSON stream from stdout. stderr is diagnostic only — TBD logs it but never parses it — with exactly one exception: `transcript` returns its continuation cursor as a JSON envelope on stderr, and that envelope is the only stderr content any verb defines (see `transcript` below).

Every invocation carries the negotiated contract major in `TBD_CONTRACT_VERSION` (see Versioning below), and the provider inherits the caller's full login environment.

Three verbs are **required**: `describe`, `create`, and `list`. Every other verb is optional and declared as a **capability** via `describe`. A caller MUST NOT invoke a verb whose capability the provider has not declared, and MUST NOT offer a user-facing action that would require one.

## Verb table

| Verb | Required? | Invocation | stdin | stdout | Timeout |
|---|---|---|---|---|---|
| `describe` | required | `<exec> describe` | — | JSON | 10s |
| `create` | required | `<exec> create` | JSON | JSON session | 60s |
| `list` | required | `<exec> list` | — | JSON `{complete, sessions:[...]}` | 30s |
| `stop` | capability `stop` | `<exec> stop <id>` | — | JSON session | 30s |
| `archive` | capability `archive` | `<exec> archive <id>` | — | JSON session | 30s |
| `unarchive` | capability `unarchive` | `<exec> unarchive <id>` | — | JSON session | 30s |
| `log` | capability `log` | `<exec> log <id> [--lines N]` | — | raw bytes | 30s |
| `transcript` | capability `transcript` | `<exec> transcript <id> [--since <cursor>]` | — | JSONL bytes | 60s |
| `send` | capability `send` | `<exec> send <id>` | raw bytes | JSON `{}` | 30s |
| `rename` | capability `rename` | `<exec> rename <id> <title>` | — | JSON session | 30s |
| `set-profile` | capability `set-profile` | `<exec> set-profile <id>` | JSON profile | JSON session | 60s |
| `land` | capability `land` | `<exec> land <id>` | — | JSON land object | 30s |
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
  "archived": false,
  "meta": {"repo": "acme/api", "branch": "fix-ci"}
}
```

Session state is three independent axes:

- **`state`** — terminal/session liveness only (`starting`, `running`, `exited`). It says whether the underlying process, container, or instance is alive; it says nothing about the agent's activity or health.
- **`agent_state`** — "does a human need to look at this" (`working`, `waiting_input`, `idle`, `exited`, `unknown`). **Normative rule: `agent_state` MUST be derived from machine interfaces — agent lifecycle hooks, transcript files, process exit codes — and MUST NEVER be inferred by parsing rendered terminal output.** Screen text is a display surface, not a state API: scraping it breaks silently when rendering changes and produces false signals. A provider with no such instrumentation available MUST report `"unknown"` rather than guess. `state: "running"` with `agent_state: "unknown"` means only that the terminal/session is present and no machine-readable agent state is available; it never means healthy, idle, or finished. If machine-readable instrumentation reports that the agent produced final output and is waiting for another instruction, the provider SHOULD report `"idle"`; without that instrumentation it remains `"unknown"`.
- **`archived`** — whether the session has been retired from the working inventory (`true` or `false`). This is a filing decision, orthogonal to both axes above: a session MAY be archived while its machine is still winding down, and a session MUST NOT become archived implicitly because it exited, went idle, or aged out. Only `archive` and `unarchive` (or an equivalent gesture on the provider's own surface) change it.

Other fields:

- `exit_code` is present if and only if `state` is `"exited"` and the code is known.
- `archived` is optional on the wire; an absent `archived` MUST be read as `false`.
- `meta` is a flat string-to-string map of provider-defined display pairs. The keys `repo`, `branch`, and `profile` are well-known: a caller MAY interpret them (for example, to look up PR status for that repo/branch pair, or to show which identity a session is currently running as) when present — mirroring how `create_params` already designates well-known field names below. Providers are not required to supply `repo`, `branch`, or `profile`, and a caller MUST degrade gracefully when any are absent (falling back to opaque rendering, or simply showing nothing extra). Every other key, and `repo`/`branch`/`profile` themselves whenever a caller has no special handling for them, are rendered as opaque detail rows — the caller never interprets arbitrary `meta` keys or values beyond this well-known set. When present, `meta.profile` is the display name of the profile the session is currently running as (a plain string — the profile's `name`, not the full profile object below) — a provider that supports the `profile` and/or `set-profile` capabilities SHOULD keep it current across `create` and any later swap, so any other client of the same backend can see which identity a session runs as without maintaining its own state.

The condition worth notifying a human about is an **edge** in `agent_state` — a transition into `waiting_input` or `exited` — not the value in isolation.

### Archived sessions stay in the inventory

**A provider MUST return archived sessions from `list` and in the `events` snapshot, exactly as it returns active ones, and MUST NOT filter them out.** Archiving changes a field on the Session object; it never changes whether the session is enumerated.

Two things break if a provider filters them:

- **The drift rule misfires.** A session that vanishes from successive snapshots is, per Identity & drift below, a session that no longer exists. An archived session filtered out of `list` is indistinguishable from a deleted one, so archiving would silently mark work gone.
- **The caller loses the archived inventory.** Browsing archived sessions — to find one and revive it — requires that they be enumerable. A caller cannot browse what the provider refuses to name.

Which archived sessions a human actually sees is the caller's decision, not the provider's: a caller typically shows active sessions by default and archived ones behind a filter. That is display policy applied to a complete inventory, and it is the only place archived sessions are hidden.

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

**Optionality and degradation.** This field is entirely optional. A provider with no way to surface structured question data — including one with no concept of structured questions at all — simply never sets it and remains fully conformant; it MUST NOT fabricate a single-option question just to answer the general `waiting_input` case. A caller renders a session with `agent_state: "waiting_input"` and no `pending_question` exactly as it always has (a generic "needs input" state), and renders one with `pending_question` present with the richer card. No capability gates this field: it rides on the Session object returned by verbs (`create`, `list`, `events`) that already exist, rather than introducing a new verb, so it follows the same rule as `meta`'s well-known keys above — a provider either populates it or doesn't, and a caller that doesn't recognize it ignores it per the response-field forward-compatibility rule in Versioning below.

**Answering.** `pending_question` is display data only — it does not add a way to answer. Answering a pending question uses the mechanisms this contract already has: attach interactively and answer the prompt directly through the terminal (`attach`), or deliver the chosen option's text as input (`send`). There is no dedicated "answer" verb. A future answer verb, if one is ever added, would need to solve two things this field alone does not: submitting a choice when no terminal is attached (so `send`'s raw-keystroke delivery isn't available), and confirming which specific `pending_question.id` the answer was directed at (`send` has no notion of a question at all, so it can't tell the provider which pending question the bytes are meant to resolve).

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
  "contract_versions": [1, 2],
  "name": "example-provider",
  "provider_version": "0.4.2",
  "capabilities": ["stop", "log", "transcript", "send", "attach", "events", "rename", "profile", "set-profile", "archive", "unarchive", "land"],
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
- `capabilities` — which optional verbs/features (`stop`, `log`, `transcript`, `send`, `attach`, `events`, `rename`, `profile`, `set-profile`, `archive`, `unarchive`, `land`) this provider implements. Every capability string except `profile` names the verb of the same name: declaring it means the verb is implemented, and omitting it means the caller never invokes it and never offers the corresponding action. `profile` is the exception — it gates whether `create`'s `profile` field is honored (see `create` and the Profile object above), while `set-profile` gates the verb of the same name.
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

Returns `{"complete": true, "sessions": [Session, ...]}`.

The `sessions` array carries every session the provider knows about, archived ones included (see Archived sessions stay in the inventory, above).

Providers SHOULD keep exited sessions listable for at least 24 hours (with `state: "exited"`) rather than dropping them from the list immediately. A session disappearing from the list is indistinguishable from transport drift unless exited sessions stick around long enough to be told apart from a genuine loss.

A transport-overload or unreachable failure MUST be returned as a transient error (exit 3), never as a successful empty list. The caller keeps its last successful snapshot and marks the provider stale; an empty successful complete snapshot instead counts toward the two-absence rule and can incorrectly mark live sessions gone.

### Snapshot completeness

`complete` declares whether the array is the provider's **entire** inventory or only part of it. The same field, with the same meaning, rides on the `events` stream's `snapshot` event.

- `complete: true` — the provider enumerated everything it has. The snapshot is authoritative about absence as well as presence.
- `complete: false` — the provider could enumerate only part of its inventory. The snapshot is authoritative about presence only.
- Absent — MUST be read as `true`. A provider that always enumerates everything need never emit the field.

**What a caller may do with an incomplete snapshot.** It MAY adopt sessions it has not seen before, and it MAY update the state of sessions it already tracks — a session that appears in a partial view has been positively observed, and that observation is as good as any other.

**What a caller MUST NOT do with one.** It MUST NOT retire anything on the strength of an incomplete snapshot: no session may be advanced toward `gone`, marked removed, or dropped from the mirror because it is missing from a snapshot that never claimed to see everything (see Identity & drift below). And it MUST NOT treat an incomplete snapshot as **refreshing freshness** — the snapshot does not update the caller's "last successful snapshot" timestamp, does not clear a staleness indicator, and does not re-open any mutation gate that staleness had closed. A partial inventory presented as current would show a half-blind view as if it were the whole truth, and would re-enable mutations against sessions the caller cannot currently see.

**`complete` means complete with respect to the full set, archived sessions included.** A provider that can enumerate its active sessions but not its archived ones reports `complete: false`, even though the active half is exhaustive. Completeness is a claim about the inventory this contract mirrors, not about whichever subset was easiest to reach.

Reporting `complete: false` is always safe and never a failure: a provider whose discovery path is degraded, rate-limited, or partially unavailable SHOULD return what it can with `complete: false` in preference to either failing the whole call or passing a truncated list off as complete.

## `stop <id>` (optional)

Terminates a running session. Whether termination is graceful, forceful, or graceful-then-forceful is entirely the provider's business.

`stop` means exactly one thing: end the running compute. It does **not** retire the session from the inventory — that is `archive`, and the two are independent operations a caller may perform in either order or not at all. A stopped session remains listed, with `state: "exited"` and whatever `archived` value it already had.

`stop` is idempotent: stopping an id that is already dead, or unknown, exits 0 and returns the session in a terminal state — at minimum `{"id": "...", "state": "exited"}`.

The verb is optional and declared via the `stop` capability. Not every backend exposes termination: a platform that reclaims idle sessions on its own schedule, with no client-facing kill, can retire a session but cannot terminate one, and such a provider MUST NOT declare `stop`. A caller MUST NOT offer a stop action for a provider that hasn't declared it — there is no fallback, and a provider without `stop` is fully usable without one.

## `archive <id>` / `unarchive <id>` (optional)

`archive` retires a session from the working inventory by setting `archived: true` on it; `unarchive` returns it by setting `archived: false`. Response in both cases: the updated Session object.

**Normative semantics:**

- Both verbs are idempotent. Archiving an already-archived session, or unarchiving one that isn't archived, exits 0 and returns the session unchanged.
- Neither verb removes the session from `list` or from the `events` snapshot. Archiving is a field change, not a deletion.
- Neither verb is a statement about liveness. Archiving MAY have side effects the provider considers part of retiring a session (a platform whose archived sessions refuse new messages, for instance, is behaving correctly), but a caller MUST read liveness off `state` as always, and MUST NOT infer that an archived session is stopped or that an active session is unarchived.
- The `id` in each response MUST be the same `<id>` passed on the invocation line.

The two verbs are declared separately (`archive`, `unarchive`), because a backend may be able to retire a session without being able to bring it back. A provider that declares `archive` alone is conformant; a caller then offers archiving and simply has no unarchive action.

Failure follows the standard error model below — for example, exit 1 with `code: "not_found"` if `<id>` no longer exists.

## `log <id> [--lines N]`

Writes raw scrollback bytes to stdout: the last `N` lines (default 2000), with ANSI passthrough intact. This is display data for a read-only view, not a JSON envelope.

`log` exists for providers that host a terminal. A provider whose sessions have no terminal to scroll simply doesn't declare it.

Rendering scrollback to a human is not the thing the machine-interface rule (above) forbids — that rule is about *inferring `agent_state`* from rendered text. Showing the same text to a human to read is fine.

## `transcript <id> [--since <cursor>]` (optional)

Writes the session's conversation to stdout as Claude Code transcript JSONL — one JSON record per line, in the record format the agent itself writes: user turns, agent responses, and tool activity as structured data. Records only; no framing, no envelope, no trailing summary.

`--since <cursor>` requests only what accumulated after `<cursor>`. Invoked without it, the provider returns the transcript from the beginning.

**The continuation cursor is returned in a JSON envelope on stderr, not on stdout:**

```json
{"cursor": "opaque-provider-string"}
```

This is the single exception to "stderr is diagnostic only", and the split is deliberate. stdout carries data records and nothing else, so a response cut short by a dropped transport is recognizable as a truncated data stream. Were the cursor a trailing control record on stdout, its absence would have two indistinguishable causes — the stream ended early, or the provider has no incremental support and never emits one — and a caller with no way to tell those apart would either discard good data or silently accept a truncated transcript as the whole conversation.

**Cursors are opaque to the caller.** It stores whatever the provider last returned and passes that value back verbatim on the next call. A caller MUST NOT parse, order, compare, arithmetically manipulate, or construct a cursor, and MUST NOT carry one across providers or sessions.

A provider without incremental support emits no cursor envelope and remains fully conformant; the caller then refetches the whole transcript each time. A provider that emits a cursor MUST accept its own most recently issued cursor on a subsequent `--since`, and SHOULD treat a cursor it can no longer honor as a request to return the transcript from the beginning rather than as an error.

**`transcript` and `log` are different data, not two encodings of the same data.** `log` is raw ANSI scrollback bytes for a read-only terminal view; `transcript` is structured conversation records for a message-level view. Structured records poured into a scrollback view lose every tool card; ANSI bytes fed to a transcript renderer produce garbage. A provider MAY implement either, both, or neither, and a caller MUST NOT substitute one for the other.

The machine-interface rule applies here as everywhere: transcript records MUST come from the agent's own transcript data and MUST NEVER be reconstructed by parsing rendered terminal output.

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

## `land <id>` (optional)

Reports where a session's work lives, so a caller can reconstruct it as a local checkout. `land` answers a question — it performs no git operation, creates nothing, and changes no session state.

Response:

```json
{
  "remote_url": "git@github.com:acme/api.git",
  "branch": "claude/fix-flaky-ci",
  "resume_command": ["claude", "--teleport", "sess_01ABC"],
  "forks": true
}
```

- `remote_url` (required) — the git remote the session's work is pushed to.
- `branch` (required) — the branch that work is on.
- `resume_command` (optional) — argv the caller MAY run in the first pane of the reconstructed checkout to resume the conversation. It is argv, never a shell string: a caller executes it directly and never through a shell. Omitted when there is nothing to resume.
- `forks` (required) — whether local work continues to reach the remote session. `true` means the local copy and the remote session diverge from the moment of landing, and a caller MUST present that fork as a fork rather than implying that typing in one reaches the other.

**None of these fields are trusted input.** For an external provider they come from an executable the user registered; for one built into the caller they may come from session metadata stored on a remote server, including metadata written by another device. Either way they are attacker-influenceable strings that are about to meet a program that takes options and executes transports. Three rules are mandatory:

- **`branch` MUST be validated before it reaches git.** A caller MUST reject any value that does not satisfy every rule below, and providers can rely on a plain branch name always being accepted:
  - composed only of ASCII letters, digits, and the characters `.`, `_`, `-`, and `/`
  - does not begin with `-` (git would read it as an option rather than a ref), `.`, or `/`
  - does not end with `/`, `.`, or the suffix `.lock`
  - contains no `..`, no `//`, no `@{`, and no ASCII control characters or space
  - is not the single character `@`

  These rules are a strict subset of what `git check-ref-format --branch` accepts. A caller MAY additionally run that command, but MUST NOT rely on it alone: the pattern above is the contract, so a provider can predict acceptance without matching one git version's behavior. A provider that emits ordinary branch names — including the `<prefix>/<name>` shapes agents typically produce — will never see a rejection.
- **`remote_url` MUST only ever be compared, never passed to git as a remote argument.** A caller compares it against the local repository's already-configured remote and refuses to proceed on a mismatch. It MUST NOT hand the value to git as a remote: git's remote-URL grammar includes the `ext::` transport family, which executes a command, so a provider-supplied URL reaching git as a remote is command execution.
- **`resume_command` MUST come only from a registered provider executable** — one the user deliberately registered, or an implementation the caller itself ships. A caller MUST NEVER accept a resume command from repository content or any other channel that is not a registered provider.

Failure follows the standard error model below — `not_found` for an unknown `<id>`, and a permanent error when the session has no landable work (for example, nothing was ever pushed).

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
{"event": "hello", "contract_version": 2}
{"event": "snapshot", "complete": true, "sessions": [Session, ...]}
{"event": "session", "session": { ...Session object... }}
{"event": "removed", "id": "fix-flaky-ci"}
{"event": "ping"}
```

- Every connection MUST open with a `hello` event immediately followed by a `snapshot` event carrying the current session list, archived sessions included.
- The `snapshot` event carries `complete` with exactly the meaning and the caller rules specified for `list` above, including that an absent `complete` reads as `true` and that an incomplete snapshot neither retires sessions nor refreshes freshness.
- **Snapshot-on-connect is the entire resync mechanism — there are no cursors, sequence numbers, or replay-from-offset.** If a caller misses a transition, the cost is one reconnect, which re-establishes full state via the next snapshot.
- `session` events carry the complete session object, never a partial diff. This makes them idempotent and safely replayable in any order relative to other `session` events.
- `removed` means the session should no longer be tracked at all. It is distinct both from the session reaching `state: "exited"` and from it becoming `archived: true` — those are ordinary changes to a session that still exists, and both are delivered as `session` events.
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

Well-known `code` values: `auth_expired`, `auth_missing`, `not_found`, `already_exists`, `unreachable`, `invalid_params`, `credential_unresolvable`. Providers may return other codes; callers should treat unrecognized codes as opaque strings and still show `message`.

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

The contract version is a single integer major, exposed on every invocation as the `TBD_CONTRACT_VERSION` environment variable. The current major is **2**.

At registration, the caller invokes `describe`, intersects its own supported major versions with the provider's `contract_versions`, and picks the highest common value. If the intersection is empty, the caller refuses to use the provider and shows a clear error. Whatever major is chosen is what rides on every subsequent invocation via `TBD_CONTRACT_VERSION`.

**Major 2 is purely additive over major 1.** It adds no required verb — it has one fewer than major 1, since `stop` is capability-gated — and every field it adds to an existing shape is optional with a defined reading when absent (`complete` reads as `true`, `archived` as `false`). A provider that conforms to major 1 therefore already conforms to major 2 as written, and MAY declare `contract_versions: [1, 2]` without implementing anything new: a caller negotiating 2 against it sees exactly the behavior it saw at 1. Such a provider SHOULD add `stop` to its declared `capabilities`, since a verb it implements but does not declare is a verb the caller will not offer. A provider that declares only `[1]` keeps working untouched, negotiated down to 1 by a caller that supports both.

The one asymmetry runs the other way: a provider that **drops** `stop` altogether no longer conforms to major 1, where it is required, and so MUST declare `contract_versions: [2]` rather than `[1, 2]`. Declaring a major means conforming to it, and a caller negotiating down to 1 against such a provider would be entitled to invoke a verb that no longer exists.

Within a major version: providers may add new response fields at any time — a scalar or a structured object alike, such as `pending_question` on the Session object — and callers MUST ignore fields they don't recognize. This is symmetric: callers may send new optional fields in structured stdin (for example, `profile` on `create`) that an older provider doesn't recognize, and **providers MUST likewise ignore fields they don't recognize in structured stdin** rather than fail on them — the same forward-compatibility contract applies in both directions. Removing or renaming a field, or changing the semantics of a verb, requires a new major version. Adding a new optional verb — gated behind a new entry in `capabilities`, as `rename` and `set-profile` were — is likewise additive within a major version: a caller that doesn't recognize the capability string simply never invokes the verb, so no version bump is needed for it either.

## Identity & drift

- The provider mints session ids. An id MUST be opaque, unique within that provider, and durable across reboots of whatever the session runs on — derived from persisted state, not from a process id or an ephemeral index. The caller keys everything by the pair `(provider name, session id)`.
- The provider — via `list` and the `events` snapshot — is the source of truth for which sessions exist and their state. Any local record the caller keeps is a mirror, never authoritative.
- A session that is absent from **two consecutive** successful **complete** snapshots is considered gone by the caller — a distinct, visible state, not a silent deletion. A single absence is not enough to conclude this, since transports occasionally flake.
- **Incomplete snapshots (`complete: false`) never contribute to that conclusion.** Absence from a snapshot that never claimed to see everything is not evidence of anything: it does not advance a session toward `gone`, and it does not count as one of the two consecutive absences. Presence still counts for what it is worth — a session observed in an incomplete snapshot has been positively seen, so its accrued absences reset exactly as they would after a complete snapshot. An unbroken run of incomplete snapshots therefore leaves the mirror where it stands, neither retiring sessions nor refreshing the caller's freshness.
- An archived session is not a gone session. `archived: true` is a field on a session the provider still enumerates; `gone` is the caller's conclusion about a session the provider stopped enumerating. A caller MUST NOT collapse the two, and a provider MUST NOT produce the second when it means the first.
- If a caller observes a session id it has never seen before, it should adopt it — sessions created from elsewhere (another machine, or directly against the provider) are real and should be shown, not discarded.
- If the provider is unreachable, the caller's mirror goes stale-but-shown, with a staleness indicator. Unreachability of the provider is never equivalent to "the sessions are dead" — those are independent facts.
