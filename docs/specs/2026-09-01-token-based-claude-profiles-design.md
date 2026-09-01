# Token-based Claude profiles

**Date:** 2026-09-01
**Status:** Design

## Problem

A Claude profile in TBD is a persistent `CLAUDE_CONFIG_DIR` the user logs into.
Creating one is a five-step dance: save the profile, select a worktree in the
main window, open a login session, run `/login` in the pane, complete a browser
round-trip. Only then is the profile usable.

That is a lot of ceremony for a credential many users already hold. A
`claude setup-token` OAuth token (`sk-ant-oat01-…`) authenticates the same
account, is minted once, and is portable across machines — people already keep
them for CI, review automation, and scripts. TBD cannot currently point a
profile at one.

This adds a fourth credential kind so a profile can be authenticated by pasting
a token instead of by signing in.

## Background: why token profiles were removed

TBD used to deliver every profile's credential as an environment variable, and
an oauth profile injected a stored `CLAUDE_CODE_OAUTH_TOKEN`.
[`2026-05-19-alternate-profiles-redesign-design.md`](2026-05-19-alternate-profiles-redesign-design.md)
replaced that with one mechanism — a persistent config dir per profile — and
dropped token injection entirely. It gave two reasons:

1. **Billing.** Anthropic's 2026-06-15 change was expected to bill
   `setup-token` usage from a separate Agent-SDK credit pool rather than
   interactive subscription limits, so token profiles would stop behaving like
   ordinary subscription sessions.
2. **Shape divergence.** oauth and direct-apiKey profiles shared the host
   `~/.claude` while proxy-apiKey profiles got an isolated config dir. Two
   shapes bred environment-dependent bugs.

Reason 1 did not materialise: there is no separate pool. `setup-token` usage
draws on the same subscription windows as an interactive login, so a token
profile and a signed-in profile on one account share one set of limits.
Nothing about billing argues against token profiles.

Reason 2 is still correct and this design preserves it in full. A token profile
is structurally identical to a signed-in profile — same isolated config dir,
same mirror symlinks, same reconciler coverage. The only difference is which
credential authenticates it. The redesign's thesis, *profiles differ only in
credential and never in shape*, holds with four kinds exactly as it held with
three.

## Non-goals

- Failover or overflow between profiles. A token profile is a credential, not a
  capacity strategy — it shares the account's limits, so there is no second pool
  to fail over into.
- Converting an existing signed-in profile into a token profile in place.
- Reading account identity for a token profile. It is not available (see
  "Usage" below); the design works without it.

## Data model

`CredentialKind` gains a fourth case:

```swift
public enum CredentialKind: String, Codable, Sendable {
    case oauth        // config dir + /login
    case oauthToken   // config dir + CLAUDE_CODE_OAUTH_TOKEN   <- new
    case apiKey
    case bedrock
}
```

**No migration and no feature flag.** `model_profile.kind` is a free-form `TEXT`
column already read as `CredentialKind(rawValue: kind) ?? .oauth`
(`Sources/TBDDaemon/Database/ModelProfileRecord.swift:56`), so a new case is
purely additive at the storage layer. Nothing changes for a user who never
creates a token profile: creating one is itself the opt-in gesture, and the
feature acts only on profiles that exist because someone made them. There is no
autonomous behavior and no load-bearing path being replaced, so the default-off
flag rule does not apply.

### Decode leniency (required, not optional)

`ModelProfile.init(from:)` currently does a strict
`try c.decode(CredentialKind.self, forKey: .kind)`. A daemon that sends
`kind: "oauthToken"` to an older app would throw, and because the profile list
decodes as one array, **every** profile disappears rather than the one unknown
row. Change it to match what the DB record already does:

```swift
kind = CredentialKind(rawValue: try c.decode(String.self, forKey: .kind)) ?? .oauth
```

Degrading an unknown kind to `.oauth` is the right fallback: an old app shows
the profile as a signed-in profile with no usage rather than losing the list.
Test that a payload with an unrecognised kind decodes to `.oauth` and leaves
sibling profiles intact.

Note that an older *daemon* reading a `"oauthToken"` row already degrades it to
`.oauth` through the same fallback, so a downgrade loses token injection without
crashing — the profile stops authenticating rather than misbehaving.

Adding the case makes the compiler surface every exhaustive switch over
`CredentialKind`. There are three such files today — `TBDShared/Models.swift`,
`TBDApp/Settings/ModelProfilesSettingsView.swift`, and
`TBDDaemon/Claude/ClaudeProfileConfigDirManager.swift` — so the blast radius is
small and fully enumerated by the build rather than by grep.

## Spawn

`ClaudeSpawnCommandBuilder` treats `.oauthToken` exactly as it treats `.oauth`,
plus one injected variable. In the non-bedrock branch:

- The secret gate widens from `profileKind == .apiKey` to
  `.apiKey || .oauthToken`, choosing `ANTHROPIC_API_KEY` for the former and
  `CLAUDE_CODE_OAUTH_TOKEN` for the latter.
- `CLAUDE_CODE_OAUTH_TOKEN` is **not** added to `routingKeys`. Like
  `ANTHROPIC_API_KEY` it rides tmux's `-e` only, so it never appears in the
  inline `export` prefix and never lands in the pane's `ps` argv. Routing keys
  are re-exported inline because rc files clobber them; a secret is not routing
  and must not be.
- `CLAUDE_CONFIG_DIR` is injected as for any other non-bedrock profile.

Secret storage reuses `ModelProfileKeychain` unchanged — same
`<uuid>.token` file, same 0600 mode, same validation rejecting newlines and NULL
bytes that would break tmux's single-line argument parsing.

Config-dir provisioning reuses `ClaudeProfileConfigDirManager` unchanged. A
token profile gets `~/tbd/profiles/<id>/claude` with the usual mirror symlinks
for `projects/`, `plugins/`, `skills/`, `agents/`, `commands/`, `hooks/`,
`CLAUDE.md` and `settings.json`, and a per-profile `.claude.json`. It simply
never grows a `.credentials.json`, because nothing logs into it.

### Reconciler coverage

No new kind of durable resource. A token profile's config dir is a
`~/tbd/profiles/<id>/` directory already swept by `OrphanGC` under
`gcProfileDirsEnabled`, and its secret file is already reclaimed on profile
delete alongside every `apiKey` profile's. Nothing here creates a git ref, tmux
server, process, or file outside those two paths.

### The shadowed-login hazard

Claude Code's auth precedence puts `CLAUDE_CODE_OAUTH_TOKEN` (#5) above a
stored credential in the config dir (#6). If a user runs `/login` inside a token
profile's pane the login succeeds, writes a credential, and is then silently
ignored on every subsequent spawn — the token keeps winning.

This is not preventable at the spawn layer, so it is handled in the UI: token
profiles never offer the "Open login session" affordance, and the `Token` badge
plus the `Token •••• <tail>` caption say plainly which credential is in force.
Document it; do not try to detect it.

The known `apiKeyHelper` limitation is unchanged and applies identically: a
helper defined in the shared `settings.json` resolves at precedence #4 and would
outrank a profile's token, exactly as it already outranks a profile's login.

## Usage

The existing usage path does not work for tokens, and the substitute is a
different mechanism rather than a different URL.

Measured behavior of a `claude setup-token` credential:

- `GET /api/oauth/usage` and `GET /api/oauth/profile` return **403**. Setup
  tokens lack the `user:profile` scope. `ClaudeUsageFetcher` and
  `LiveProfileUsageFetcher` therefore cannot serve token profiles at all.
- `POST /v1/messages` with `"max_tokens": 0`, `Authorization: Bearer <token>`
  and `anthropic-beta: oauth-2025-04-20` returns **200**, bills roughly eight
  input tokens and zero output tokens, and carries usage in its **response
  headers**.
- `POST /v1/messages/count_tokens` returns no usage headers and is not a
  substitute.

The headers that matter:

- **`anthropic-ratelimit-unified-5h-utilization`** and **`-7d-utilization`** —
  fraction of the window consumed, `0..1`.
- **`anthropic-ratelimit-unified-5h-reset`** and **`-7d-reset`** — epoch seconds
  at which the window resets.
- **`anthropic-ratelimit-unified-status`**, and a per-window `-status` for each
  of the two windows — `allowed`, `allowed_warning`, or a rejected state.
- **`anthropic-organization-id`** — stable per account. Captured and persisted
  but deliberately not rendered; see "Capturing the organization id" below.

### Mapping onto the existing snapshot

These map onto `ClaudeUsageLimitBucket` without changing its shape:

- 5-hour window – `kind: "session"`, `group: "session"`.
- 7-day window – `kind: "weekly_all"`, `group: "weekly"`.
- `utilization × 100` – `percent`.
- reset epoch – `resetsAt`.
- `allowed_warning` – `severity: "warning"`; `allowed` – `"normal"`; a rejected
  status – `"critical"`.

There is **no `weekly_scoped` bucket**: headers carry no per-model breakdown. A
token profile therefore renders two bars where a signed-in profile renders three
or more. This needs no rendering change: `UsageBarsView` draws the 5-hour and
weekly bars from optional lookups and then loops over the scoped buckets, so an
empty scoped set simply contributes no rows.

### A new fetcher, not a new snapshot type

Add `TokenProfileUsageFetcher` conforming to the existing `ProfileUsageFetching`
protocol, keyed on the profile's stored secret rather than a config-dir path.
`ProfileUsageFetching` currently takes `configDirPath:`; widen it to a small
enum credential source (`.configDir(String)` / `.token(String)`) so
`OAuthProfileUsagePoller` can dispatch on profile kind without knowing how
either fetcher works. Everything downstream — `ProfileUsageSnapshot`,
`OAuthUsageSnapshotStore`, `ProfileUsagePresentation`, the hover cards, the
account picker — is untouched.

### Capturing the organization id

`anthropic-organization-id` is the only stable account discriminator available
for a token profile — the identity endpoint is 403, so there is no email. It is
worth capturing now even though nothing displays it yet: it costs one header
read, and without it there is no way to later tell that a token profile and a
signed-in profile are two views of the same account's limits rather than two
independent pools. Deciding *where* to surface that is deferred; capturing it is
not, because a field that was never recorded cannot be backfilled for usage that
already happened.

Store it on the snapshot rather than the profile:

```swift
public struct ProfileUsageSnapshot {
    ...
    /// Organization id from the last successful fetch's
    /// `anthropic-organization-id` response header. nil when the endpoint sent
    /// none, or the snapshot predates this field. Captured for account
    /// correlation; nothing renders it yet.
    public var organizationID: String?
}
```

The snapshot is the right home for three reasons. It is derived from the fetch
that observed the header, so it refreshes naturally when a profile's token is
replaced with one for a different account. It is persisted as a regenerating
JSON blob (`oauth_profile_usage_snapshot`), so an optional field needs **no
migration** and stays decode-compatible in both directions — `decodeIfPresent`
yields nil for older stored JSON, and an older app ignores the unknown key. And
it already reaches the app inside `ModelProfileWithUsage.usageSnapshot`, so
**no RPC change is required**.

Threading it through takes one seam. `ProfileUsageFetchStatus.ok` widens to
carry it:

```swift
case ok([ClaudeUsageLimitBucket], organizationID: String?)
```

Every `case .ok` site is then a compile error until updated — the enumeration is
done by the build, not by grep. If a second header ever warrants capturing,
replace the two associated values with a small reading struct rather than
growing the case further.

**Both fetchers read the header opportunistically.** The token probe is known to
return it. Whether `/api/oauth/usage` also returns it on the signed-in path is
unverified, so `LiveProfileUsageFetcher` reads the same header and records nil
when absent. That costs nothing, and it means signed-in profiles pick the value
up for free if the endpoint does supply it — rather than the design asserting an
answer it has not measured.

The value is an account identifier. Log it at `.public` like other profile
routing facts — it is not a credential — but it must never appear in an error
string that also carries token bytes.

### Rejected tokens reuse `.needsLogin`

Do **not** add a `ProfileUsageStatusKind` case for a rejected token.
`statusKind` is decoded with `decodeIfPresent`, which **throws** on an
unrecognised raw value rather than returning nil, so widening the enum breaks
snapshot decode on any older app. The state is the same shape anyway — the
credential was rejected and the user must supply a new one — and the UI already
knows `profile.kind`, so it words the affordance as "Replace token…" instead of
"Open login session". A 401 or 403 from the probe records `.needsLogin`.

## Polling: activity-gated, with a five-minute floor

Unlike the read-only usage endpoint, the probe is a real billed API request. At
`OAuthProfileUsagePoller`'s current 90-second cadence a single token profile
would issue about 960 requests and 7,700 input tokens per day, purely to draw a
progress bar. The token cost is trivial; the request volume is not obviously so,
and each probe is an inference request that can itself be rate-limited.

Blind polling is also unnecessary: **a profile's utilization changes only when a
session using it does work.** TBD already observes that. `Terminal.profileID`
links a terminal to its profile, and `Terminal.activityState` is a hook-derived
machine fact carrying `activityStateSource` and `activityStateObservedAt`.

So:

- **Token profiles are excluded from the 90-second cadence sweep.** The loop's
  eligibility filter (`kind == .oauth && loginIdentity != nil`) already excludes
  them; leave it that way rather than widening it.
- **A `working → idle` transition on a terminal whose `profileID` names a token
  profile schedules a refresh** for that profile — the moment a turn completed
  and utilization actually moved.
- **The refresh is `sweepNow(only: profileID)` with `skipFresherThan: 300`.**
  The five-minute floor is the existing freshness parameter, not new machinery,
  so a burst of turns collapses into at most one probe per five minutes.
- **Failure backoff is unchanged.** The existing per-profile schedule and its
  `Retry-After` override apply, so a rejected or rate-limited token is not
  hammered by activity.
- **One probe on profile creation**, so a freshly pasted token shows bars
  immediately and a bad paste is caught at once rather than at first spawn.
- **Manual refresh** in the profile row's `⋯` menu, subject to the same floor.

An idle token profile issues zero requests. A continuously busy one issues at
most 288 per day, and each is fresher than a timer's would be because it fires
after work rather than between it.

The transition-observing code takes an injected clock per the repo's timer rule;
the five-minute floor is a `TimeInterval` constant on the poller beside
`refreshFreshness`.

## Staleness display

`ProfileUsagePresentation.stalenessNote` already appends `updated 7m ago` once a
snapshot passes `staleAge`, and `secondaryLine` already refuses to present stale
numbers as current. But `staleAge` is a single five-minute constant whose
comment ties it to the 90-second cadence
(`Sources/TBDApp/Helpers/ProfileUsagePresentation.swift:442`). A token profile
polling on a five-minute floor would cross that threshold constantly and render
as stale the moment it was fetched — a permanent false alarm on correct data.

Make the threshold **cadence-relative**: derive it per kind at roughly three
times that kind's polling interval, keeping five minutes for `.oauth` and
fifteen for `.oauthToken`. The rendering, wording, and call sites are unchanged.

## User interface

### Adding a profile

`AddModelProfileSheet` keeps its three top-level segments (Claude, Proxy,
Bedrock). Inside the Claude segment a second, smaller picker chooses how to
authenticate:

```
┌─ Add Model Profile ──────────────────────────────┐
│  ┏━━━━━━━━┓┌───────┐┌─────────┐                  │
│  ┃ Claude ┃│ Proxy ││ Bedrock │                  │
│  ┗━━━━━━━━┛└───────┘└─────────┘                  │
│                                                  │
│  Name      ┌────────────────────────────────┐    │
│            │ Acme                           │    │
│            └────────────────────────────────┘    │
│                                                  │
│  Sign in   ┌─────────────┓━━━━━━━━━━━━━━━━━┓     │
│            │ Sign in     ┃ Paste a token   ┃     │
│            └─────────────┗━━━━━━━━━━━━━━━━━┛     │
│                                                  │
│  Token     ┌────────────────────────────────┐    │
│            │ ••••••••••••••••••••••••••••   │    │
│            └────────────────────────────────┘    │
│            Run `claude setup-token` and paste    │
│            the sk-ant-oat01-… value here.        │
│                                                  │
│  Model     ┌────────────────────────────────┐    │
│            │ e.g. opus                      │    │
│            └────────────────────────────────┘    │
│                            [Cancel]  [ Add ]     │
└──────────────────────────────────────────────────┘
```

This models the truth — one account type, two ways to authenticate it — rather
than presenting the same product twice at top level. Choosing "Sign in" hides
the token field and keeps today's behavior exactly, including the post-save
"Profile Created → Open login session" step. Choosing "Paste a token" skips that
step entirely, which is the friction this feature exists to remove: the profile
is usable the moment the sheet closes.

The sub-picker is deliberately a visible control rather than an inferred mode. A
design where a non-empty token field silently selects the kind was rejected: it
is undiscoverable, and it makes the kind awkward to reason about when editing.

### The profile list

```
Model Profiles

  Acme                 [OAuth]       [Edit] [⋯]
  a@acme.com
  5h 61% · 7d 38% · resets 14:20

  Acme (token)         [Token]       [Edit] [⋯]
  Token •••• 4f2a
  5h 61% · 7d 38% · resets 14:20

  Local proxy          [API key]     [Edit] [⋯]
  http://127.0.0.1:3456
```

- **Badge** — `ModelProfile.kindLabel` gains `"Token"`. It is left alone for
  `.oauth`, which renders `OAuth` today; renaming that badge is a separate
  question from this change.
- **Caption** — `Token •••• <last 4>`. Honest about which credential is
  installed without claiming an identity TBD cannot verify, and enough to tell
  two token profiles apart. `ProfileLoginPresentation.settingsCaption` grows the
  case.
- **No identity line.** The profile endpoint is 403 for setup tokens, so there
  is no email to show. This is a real limitation of the credential, not a gap to
  paper over.
- **`ProfileLoginPresentation.needsLogin` returns false** for `.oauthToken`, so
  the "Open login session" link never appears.
- **Rejected token** — the caption becomes a warning with an inline
  `Replace token…` link opening the edit sheet, mirroring the shape of today's
  "Open login session" affordance:

```
  Acme (token)         [Token]       [Edit] [⋯]
  Token rejected — Replace token…
```

### Editing

`ModelProfileRow`'s edit-button partition (bedrock → proxy → Claude-direct)
routes `.oauthToken` to `EditClaudeDirectSheet`, which gains a conditional
"Replace token" `SecureField` shown only for that kind. Leaving it blank keeps
the stored token; a non-empty value replaces it. Rotation matters — setup tokens
expire — so this is the only way to recover a profile whose token has aged out.

## Error handling

- **Bad token at creation** — the creation-time probe fails with 401/403; the
  sheet surfaces the error and the profile is still created (so the user can fix
  it via Replace token rather than starting over), with the row showing the
  rejected state.
- **Token rejected later** (revoked, expired) — the probe records `.needsLogin`;
  the row shows `Token rejected — Replace token…`. Spawning still works as far
  as TBD is concerned; the session itself will fail to authenticate, and the row
  is where the user finds out first.
- **Probe rate-limited (429)** — existing backoff with `Retry-After` override.
  Bars keep showing last-known values with a staleness note; they are never
  presented as current.
- **Network failure** — `.networkError`, retried, last-known buckets retained.
- **Missing secret file** — `.noCredentials`. Reachable if the secret file is
  removed out from under the profile.

## Testing

Both branches of every conditional this adds, per the repo's branching rule.

- **Spawn** — `.oauthToken` injects `CLAUDE_CODE_OAUTH_TOKEN` via tmux `-e`;
  the token appears in **no** inline `export` and in **no** command string. The
  existing "never contains `CLAUDE_CODE_OAUTH_TOKEN`" assertions become
  kind-scoped rather than deleted: still asserted for `.oauth`, `.apiKey` and
  `.bedrock`. A `.oauthToken` profile also gets `CLAUDE_CONFIG_DIR`, and it
  *is* a routing key while the token is not.
- **Decode leniency** — an unknown `kind` string decodes to `.oauth`, and
  sibling profiles in the same array survive.
- **Usage header parsing** — fixture header sets covering `allowed`,
  `allowed_warning`, a rejected status, missing headers, and a malformed
  utilization value. Assert the composed buckets, not individual field
  extraction.
- **Organization id capture** — a response carrying
  `anthropic-organization-id` lands it on the snapshot; a response without the
  header yields nil rather than an empty string; a snapshot JSON blob written
  before the field existed decodes with nil; and a profile whose token is
  replaced with one for a different account has the new value after the next
  successful fetch, not the old one.
- **Polling gate** — a `working → idle` transition on a token profile's terminal
  schedules exactly one probe; a second transition inside five minutes schedules
  none; one after five minutes schedules one. A transition on a `.oauth`
  profile's terminal schedules none. The cadence sweep never targets a token
  profile.
- **Staleness threshold** — a token profile fetched four minutes ago renders no
  staleness note; a signed-in profile fetched four minutes ago does.
- **Presentation** — `needsLogin` is false for `.oauthToken` regardless of
  `loginIdentity`; the caption renders the masked tail; the rejected state
  renders the replace affordance.

Clock and date seams per the repo's rule: the polling gate's floor is a
`Duration` behavior seam taking an injected clock, while `fetchedAt` comparisons
use the existing date seam.

## Rejected alternatives

- **Attaching a token to an existing signed-in profile as a second credential,
  with a mode switch or automatic overflow.** Attractive when the premise was a
  separate quota pool, and pointless without one: both credentials draw on the
  same windows, so there is nothing to switch between or overflow into. It would
  also force every consumer — spawn, poller, pickers, login state — to learn a
  sub-mode.
- **A fourth top-level segment in the Add sheet.** Mirrors the data model
  exactly and keeps each form flat, but presents two segments for the same
  account type as though they were different products, and crowds a 520pt sheet.
- **Inferring the kind from a non-empty optional token field.** Least chrome,
  but an implicit mode chosen by a field's blankness is undiscoverable and hard
  to reverse when editing.
- **Sharing the host `~/.claude` instead of an isolated config dir**, as
  pre-migration token profiles did. Reintroduces exactly the two-shape
  divergence the 2026-05-19 redesign removed, and makes the profile share
  `.claude.json` onboarding state with the host.
- **Harvesting rate-limit headers from the session's own API traffic** instead
  of probing. This would be free, and it does not work here: TBD is not the
  requester. Claude Code makes those calls inside the pane and the headers never
  reach anywhere TBD can read. The transcript JSONL carries `message.usage`
  token counts and no rate-limit fields; the statusline carries rendered text,
  and reading utilization out of it would be TUI screen-scraping, which this
  repo bans. Token counts cannot be converted to utilization in any case — the
  window denominators are not published.
- **A fixed five-minute timer** instead of activity gating. Simpler, but it
  probes idle profiles forever and is *less* fresh than activity gating at the
  moment freshness matters, since it fires between turns rather than after them.

## Open questions

None blocking. Two things to watch once this is in use:

- Whether `anthropic-beta: oauth-2025-04-20` remains the correct beta header.
  If it changes, the probe 4xx's and every token profile reports `.needsLogin`,
  which is misleading — a distinct "probe unsupported" state may be worth adding
  if that happens.
- Where to surface `anthropic-organization-id`. The value is captured and
  persisted by this design but rendered nowhere. The obvious use is telling the
  user that a token profile and a signed-in profile are the same account, so
  their bars are two views of one set of limits rather than two independent
  pools — but that wants a real UI decision, and it can be made once field data
  shows how often people actually keep both.
