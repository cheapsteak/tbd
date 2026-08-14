# Capacity facts

TBD's machine-readable surface for **how much quota an account has left**, and
for **which account a session is running on**. It exists so a supervision
program that TBD does not run — a wake program, a sweep program, an operator's
cron script — can decide for itself whether to hold: not nudging agents that
are rate-capped, not piling interventions onto a saturated account.

This is the Enabled half of P1-1 in
[`specs/2026-07-26-fleet-supervision-requirements.md`](specs/2026-07-26-fleet-supervision-requirements.md).
The daemon enforces nothing here — there is no capacity choke point every wake
must pass through, deliberately (see
[`specs/2026-07-26-fleet-supervision-wake-program.md`](specs/2026-07-26-fleet-supervision-wake-program.md)).
What TBD owes a program author is that the facts are public, documented, and
stable. That is what this document states.

## The commands

- **`tbd profile list --json`** – the versioned capacity envelope: every model
  profile, its login identity, and its usage snapshot. This is the contract.
- **`tbd profile list --json --refresh`** – the same, after asking the daemon
  to refresh usage for stale logged-in OAuth profiles first. Fresh profiles
  and rate-limited ones are skipped, so `--refresh` is not a way to force a
  fetch; it is a way to say "don't hand me numbers that aged out while I
  slept." A refresh failure does not fail the command **when the daemon
  answered the refresh attempt** — it refused, or its answer was unreadable:
  the cause is noted on stderr, the listing still prints on stdout from
  persisted snapshots, and the exit code stays 0. Each snapshot's own
  `fetchedAt` and `statusKind` then say how old its numbers are, so a caller
  that needs fresh-or-nothing must decide that from those fields rather than
  from the exit code. An **unreachable** daemon is not tolerated: `--refresh`
  fails the command like any other invocation would, nonzero and with no
  listing, rather than promising one it cannot produce.
- **`tbd terminal list --json <worktree>`** – per-terminal rows, of which only
  `profileID` participates in this contract: it is the join from a running
  session to the profile whose capacity governs it.

Data goes to stdout, messages to stderr; both commands exit 0 on success and
nonzero with the refusing condition named on stderr.

## The versioning promise

`tbd profile list --json` prints a JSON object carrying a top-level
`schemaVersion`, currently **1**. Within a version:

- **Fields may be added** – a consumer MUST tolerate keys it does not
  recognize, at every level: new top-level fields, new per-profile fields, new
  snapshot fields, and new bucket `kind` values. Unknown bucket kinds flow
  through from the usage API untouched by design, so new windows appear
  without a TBD release.
- **A field never changes meaning within a version** – timestamps stay ISO
  8601, an enum value already emitted keeps its sense, and a field TBD computes
  keeps computing the same thing.
- **Provider values are passed through as data, not restated as TBD's** –
  `percent`, `severity`, and bucket `kind` come from the usage API and are
  emitted verbatim. TBD promises only not to reinterpret or rescale them
  within a version: the observed scale for `percent` is 0–100 utilization, and
  if the provider ever changed it, the new scale would surface here as-is
  rather than being silently converted. Read them as the provider's numbers,
  and prefer relative judgments (this profile against itself over time) over
  hard-coded absolute thresholds.
- **Removing a field, or changing what one means, requires a version bump** –
  a consumer that branches on `schemaVersion == 1` will not be surprised
  silently.

This is the convention newly versioned JSON surfaces in TBD adopt, stated for
the planned supervision surfaces in [`cli-supervise.md`](cli-supervise.md).
`tbd profile list --json` is its first shipped instance; TBD's older JSON
output predates the convention and carries no version, so do not expect a
`schemaVersion` from a command not documented as having one.

`tbd terminal list --json` is the exception: it prints a **bare JSON array** at
top level, so it has nowhere additive to put a version. It is unversioned and
documented as-is; only its `profileID` field is promised here.

## The envelope

Top level of `tbd profile list --json`:

- **`schemaVersion`** – integer, currently `1`.
- **`profiles`** – array of profile entries, described below.
- **`defaultID`** – UUID of the globally-configured default profile, or absent
  when no global default is set. It tells you which profile *new* sessions
  will be spawned under; it does not tell you what any *existing* session is
  running on, and it is never a substitute for a missing `profileID` (see
  "The terminal join").

The envelope also carries app-oriented configuration mirrors —
`primaryAgentPreference`, `globalEnvOverrides`, merge-automation defaults, and
similar. They are part of the same versioned output and the additive promise
covers them too, but the capacity contract only *interprets* the fields
documented here. Treat the rest as informational.

## Per profile

Each element of `profiles`:

- **`profile`** – the profile itself. `id` (UUID, the value `profileID` on a
  terminal joins to), `name` (operator-chosen label), `kind` (`oauth`,
  `apiKey`, or `bedrock`), plus configuration fields outside this contract.
- **`loginIdentity`** – the account email the profile is logged in as. Absent
  for non-OAuth kinds, and for an OAuth profile nobody has run `/login` into
  yet.
- **`configDirPath`** – absolute path of the profile's isolated Claude config
  directory. Absent for Bedrock profiles.
- **`usageSnapshot`** – the capacity facts, or **absent**. Its absence is
  meaningful; see next.

### Absence is not failure

The single most important distinction in this document. A missing
`usageSnapshot` and a failing one are different states, and a missing one is
itself two different states — three in all, each told apart from fields already
in the payload:

- **Durably untracked** – `kind` is not `oauth`, or `loginIdentity` is absent.
  API-key and Bedrock profiles have no usage API to poll at all, and an OAuth
  profile nobody is logged into has no credential to poll with. No numbers are
  coming without operator action — a login, or a different profile.
- **Tracked, not yet fetched** – `kind` is `oauth`, `loginIdentity` is present,
  and `usageSnapshot` is still absent. The poller has this profile but no
  attempt has landed yet: the daemon started moments ago, or the login just
  completed. This is transient and self-resolving; numbers are coming with no
  operator action. Retry later rather than concluding anything.
- **Tracked and failing** – `usageSnapshot` is present with a failing
  `statusKind`. TBD tracks the profile and its last attempt failed. There may
  still be numbers, from an earlier successful fetch, and the failure's
  recency is knowable from `lastAttemptAt`.

A program that collapses these into one "no data" bucket will treat an
untracked Bedrock lane, a daemon that has been up for ten seconds, and an
account whose token just expired as the same thing — and only the last of the
three warrants telling an operator anything.

**`loginIdentity` decides "untracked", even against a snapshot that is still
there.** A profile can briefly show an absent `loginIdentity` alongside a
present `usageSnapshot` — even one whose `statusKind` is `ok`. The poller
seeds persisted snapshots when the daemon starts and prunes the ones that are
no longer eligible on its next full sweep, so after a logout, or a restart
following one, the old snapshot outlives the credential for up to one sweep
interval. It is a ghost: the numbers describe an account nothing is running
under any more, and it disappears on its own. Take the absent `loginIdentity`
as authoritative and read that profile as durably untracked, whatever the
lingering snapshot says.

## The usage snapshot

Fields of `usageSnapshot`:

- **`buckets`** – the rate-limit windows from the last **successful** fetch.
  Empty when none has ever succeeded. Described below.
- **`fetchedAt`** – ISO 8601 instant of the last **successful** fetch.
  **Absent means no fetch has ever succeeded**, which is exactly when
  `buckets` is empty or meaningless. This is the field to judge staleness
  from — TBD persists snapshots across daemon restarts, so an otherwise
  healthy-looking snapshot can carry hours-old numbers.
- **`lastAttemptAt`** – ISO 8601 instant of the last attempt, successful or
  not. Always present. Compare it against `fetchedAt` to see how long the
  profile has been failing.
- **`status`** – human-readable outcome of the last attempt: `"ok"`, or a
  failure description such as
  `"stale since 2026-07-07T12:34:56Z; fetch failed: HTTP 401"`. Written for
  people. Do not branch on it — its wording is not a contract.
- **`statusKind`** – the machine-readable classification to branch on:
  - **`ok`** – last fetch succeeded; `buckets` are current.
  - **`rateLimited`** – HTTP 429. The poller is backing off and will retry.
  - **`needsLogin`** – the credential exists but the server rejected it and
    automatic token refresh could not recover; the profile needs `/login`.
  - **`noCredentials`** – no stored credential at all (never logged in, or the
    keychain item is gone).
  - **`networkError`** – transport-level failure (DNS, timeout, offline).
    Transient; retried.
  - **`decodeError`** – the server replied 200 but the body did not parse.
    Retried.
  - **`unknown`** – some other HTTP status, or a snapshot written by an older
    daemon that did not classify. Treat as a generic retryable failure.

**Buckets and status are independent.** Buckets come from the last successful
fetch; status describes the last attempt. A snapshot can therefore carry a
failing `statusKind` *and* a full set of buckets — those numbers are simply
old. Read truth-of-last-outcome from `statusKind`, and age from `fetchedAt`.

### Buckets

Each element of `buckets` is one rate-limit window as the usage API names it:

- **`kind`** – `session` (the rolling 5-hour window), `weekly_all` (weekly,
  all models), `weekly_scoped` (weekly, one model family), or a kind TBD has
  never seen. Unknown kinds are passed through verbatim; do not assume the
  list is closed.
- **`modelDisplayName`** – for `weekly_scoped`, the model family the window
  applies to (e.g. `"Fable"`). Absent when the bucket is not model-scoped.
- **`group`** – the API's grouping label (`session`, `weekly`). Absent if the
  API omits it.
- **`percent`** – utilization of this window, a JSON number carrying the
  provider's own value. On observed responses the scale is 0–100, where `100`
  means the window is spent. TBD does not rescale it (see "The versioning
  promise").
- **`resetsAt`** – ISO 8601 instant when the window resets. **Absent when the
  API sent null**, which happens for a scoped window that has not been used.
  Absent is not "resets now."
- **`severity`** – the API's label: `normal`, `warning`, `critical`. Passed
  through as sent; absent when the API omits it. It is the provider's
  judgment, not TBD's threshold.
- **`isActive`** – whether this is the window currently binding the account.
  Absent when the API omits it.

## The terminal join

`tbd terminal list --json <worktree>` emits a bare array of terminal rows. One
field on each row participates in this contract: **`profileID`**, the join from
a session to the profile whose capacity governs it. It has three states, not
two — the join can fail as well as be absent:

- **`profileID` PRESENT and it joins** – the UUID of the profile this session
  is actually running under. It is the **already-resolved** answer: the daemon
  runs the full precedence chain at spawn time — explicit per-spawn override,
  then the repo's override, then the scratch override for repo-less spawns,
  then the global default — and stamps the result. Waking a hibernated session
  pins to this stamped profile, and ordinarily refuses to wake at all if it no
  longer resolves, so the value survives a park/wake cycle. (Reviving a
  *closed* terminal re-runs the chain, so it may come back stamped
  differently.) Join it to `profiles[].profile.id` for that session's capacity
  facts.
- **`profileID` PRESENT but it joins to nothing** – the pin is dangling: no
  entry in `profiles[]` carries that id. Deleting a profile does exactly this,
  immediately, to every terminal row that references it — awake, parked, or
  closed. Nothing rewrites those stamps, deliberately: the stamp records which
  account a session was started under, and an already-running process keeps
  using the credentials it was handed, so overwriting the record would
  misreport what that process is doing. (A parked session pinned to a deleted
  profile ordinarily refuses to wake at all; the explicit fallback that
  overrides the refusal resumes it on ambient credentials, still under the old
  stamp.) Read a dangling pin exactly like the absent case — no capacity facts
  exist for this terminal — and never as an error or a corrupt payload. It is a
  normal state with a normal cause.
- **`profileID` ABSENT** – the honest reading is again **"no capacity facts
  exist for this terminal."** Either it is not a Claude session at all (shell
  and codex kinds carry no profile), or resolution produced nothing at spawn —
  no override and no global default configured — and the session is running on
  ambient credentials, an account TBD's usage poller does not track.

**A consumer MUST NOT resolve an absent or dangling `profileID` against
`defaultID`.** The default is what the *next* session would get, not what this
one got; a session spawned before a default was configured, or under
credentials TBD never sees, would be attributed to an account whose numbers
describe a different quota entirely. Synthesizing an effective profile also
erases the ambient-versus-profile distinction that the wake-refusal path
depends on.

A holding program should treat both as **unknown**, which is neither
"exhausted" nor "free" — and choose which way to fail from its own conduct,
not from a guess TBD made for it. Practically: look the id up, and take a
miss as unknown rather than retrying or reporting a fault.

## Worked example

Abridged output of `tbd profile list --json` — three profiles: one healthy,
one whose fetch is failing but still holds yesterday's numbers, and one TBD
tracks no usage for at all.

```json
{
  "schemaVersion": 1,
  "defaultID": "6f1b0e6c-2f8a-4a5e-9c3d-1a2b3c4d5e6f",
  "profiles": [
    {
      "profile": {
        "id": "6f1b0e6c-2f8a-4a5e-9c3d-1a2b3c4d5e6f",
        "name": "primary",
        "kind": "oauth"
      },
      "loginIdentity": "operator@example.com",
      "usageSnapshot": {
        "status": "ok",
        "statusKind": "ok",
        "fetchedAt": "2026-07-07T17:41:03Z",
        "lastAttemptAt": "2026-07-07T17:41:03Z",
        "buckets": [
          {
            "kind": "session",
            "group": "session",
            "percent": 42.5,
            "severity": "normal",
            "isActive": true,
            "resetsAt": "2026-07-07T18:00:00Z"
          },
          { "kind": "weekly_all", "group": "weekly", "percent": 17 },
          {
            "kind": "weekly_scoped",
            "group": "weekly",
            "percent": 3,
            "modelDisplayName": "Fable"
          }
        ]
      }
    },
    {
      "profile": {
        "id": "9a7d4c11-55b2-4f0e-8b6a-7c5d3e2f1a0b",
        "name": "spillover",
        "kind": "oauth"
      },
      "loginIdentity": "spillover@example.com",
      "usageSnapshot": {
        "status": "stale since 2026-07-06T22:10:00Z; fetch failed: HTTP 401",
        "statusKind": "needsLogin",
        "fetchedAt": "2026-07-06T22:10:00Z",
        "lastAttemptAt": "2026-07-07T17:41:04Z",
        "buckets": [
          { "kind": "session", "group": "session", "percent": 88 }
        ]
      }
    },
    {
      "profile": {
        "id": "1c2d3e4f-6a7b-48c9-90d1-e2f3a4b5c6d7",
        "name": "bedrock-lane",
        "kind": "bedrock"
      }
    }
  ]
}
```

Read this the way a holding program should:

- **`primary`** – fresh (`fetchedAt` is seconds old), 42.5% through its
  5-hour window, which resets at 18:00Z. Safe to act on.
- **`spillover`** – the 88% is from yesterday and the token is rejected now.
  `statusKind: needsLogin` says the numbers will not improve on their own.
  A program should hold sessions on this profile and surface the login need,
  not retry into it.
- **`bedrock-lane`** – no `usageSnapshot` key at all, and `kind` is not
  `oauth`, so it is durably untracked rather than merely not fetched yet. TBD
  tracks no capacity for it; sessions joined to it are unknown, not free.

A terminal whose row carries no `profileID` — or one that matches none of these
three ids — is in that same unknown category, regardless of what `defaultID`
says.
