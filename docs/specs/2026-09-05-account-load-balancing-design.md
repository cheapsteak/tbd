# Account load balancing across Claude profiles

TBD already knows, per Claude profile, how much of the 5-hour and 7-day
windows an account has used, and it already knows which profile every session
runs under. What it does not do is act on either fact: a new session lands on
whichever profile the precedence chain names, and a session that hits its
limit sits dead until its window resets or a person swaps it by hand. This
design adds three behaviors on top of the facts TBD already gathers: a launch
policy that spreads new sessions across the profiles with the most room, an
automatic hand-over to another account when a running session hits a hard
limit, and a live-session count beside the usage bars so the person can see
the load the policy is balancing. All three run entirely on machinery that
exists today — the usage snapshots, the `terminal.profile_id` stamp, and the
in-place profile swap — and the two that act on their own ship behind
default-off flags.

## 1. What is wrong today

A person running many Claude Code sessions a day across several accounts hits
this shape repeatedly: one profile is the global default, so every new
session lands on it; its 5-hour window fills while the other accounts sit at
a fraction of theirs; a session dies with "You've hit your session limit";
the person notices minutes or hours later, opens the tab's context menu,
reads the usage suffix on each profile in the "Swap profile" submenu, picks
the emptiest, and waits for the resume. Every step of that is a human doing
by hand what the daemon has the facts to do itself.

The facts are all in place:

- **Usage per profile** – `OAuthProfileUsagePoller` refreshes every signed-in
  profile's `/api/oauth/usage` reading every 90 seconds and persists it as a
  `ProfileUsageSnapshot` (`oauth_profile_usage_snapshot`), with 5-hour,
  weekly-all and per-model-family buckets carrying `percent`, `resetsAt` and
  `severity`. Setup-token profiles get the same snapshot shape from the
  rate-limit headers of a zero-token probe after each turn.
- **Which profile a session runs under** – `Terminal.profileID`, stamped at
  spawn by the resolver's precedence chain and documented as the effective
  answer, never synthesized ([`2026-08-14-capacity-facts-contract-design.md`](2026-08-14-capacity-facts-contract-design.md)).
- **When a session hits a hard limit** – the `StopFailure` hook runs
  `tbd stop-failure`, `RateLimitDetection` distinguishes a hard limit from a
  transient error, and the daemon's `handleRateLimitDetected` records it,
  notifies, and (behind `autoResumeOnLimitReset`) types `continue` when the
  window resets.
- **Moving a live session to another account** – `terminal.swapProfile` in
  `.inPlace` mode interrupts the pane's Claude, carries the transcript into
  the destination profile's config dir, and respawns `claude --resume <id>`
  under the new profile in the same tmux window and the same terminal row.

What is missing is the policy that connects them, and one fact: how many
live sessions each profile is carrying right now. Nothing aggregates
`terminal.profile_id` today; the only profile-keyed signal is the
edge-triggered `working → idle` notification that drives token-profile usage
refreshes.

## 2. Goals and non-goals

Goals:

- A new Claude session, when the person has not pinned it to a profile, lands
  on the eligible profile with the most room, adjusted for how many sessions
  that account already carries.
- A session that hits a hard usage limit is offered — and, when the person
  has opted in, automatically given — a resume on another account with room,
  in the same tab, without losing the conversation.
- The person can see, per profile, the 5-hour and 7-day utilization and the
  number of live sessions, in the places they already look: the profile list
  in Settings, the spawn-time account picker, and the tab's swap menu.
- The person can keep a profile out of the pool without deleting it.
- Every choice the policy makes is explainable from facts the person can see
  on screen, and deterministic given those facts.

Non-goals:

- Learning which profiles are the same account from anything TBD does not
  already record. Two profiles are treated as one account only when their
  snapshots carry the same `organizationID` or their login identities match.
- Rotating an ambient session (`profileID == nil`) automatically. TBD cannot
  name the account such a session runs on, so it cannot rule out swapping it
  onto the account it just exhausted. It is offered the suggestion; it is
  never moved unasked.
- Rebalancing sessions that have not hit a limit. A working session stays
  where it is; the policy acts at two moments only — spawn and a hard limit.
- Reading utilization out of the statusline stdin payload. Setup-token
  profiles already have a per-turn signal, and signed-in profiles have a
  90-second one; widening the desk-only statusline tee to the fleet would
  displace the operator's own statusline in every session for a reading that
  is at most 90 seconds fresher.
- Overriding a repo's profile override or a per-spawn pick. Those are the
  person's explicit choices; the policy fills in only where the global
  default would otherwise have applied.

## 3. Placement

Following "Compile only what user-land cannot do well": the picker is a pure
function over facts the daemon already exposes, and the two acting behaviors
are compiled because both need the daemon's own moment-of-action — a spawn
resolves its profile inside the daemon, and a hard limit is reported to the
daemon by a hook with a sub-second window before the person would want the
hand-over to have already happened. A user-land script could read
`tbd profile list --json` and swap terminals, but it could not intercept a
spawn, and a hook that swaps a session from inside that session's own
`StopFailure` would be racing the daemon's recapture of the very session it is
replacing.

The picker itself lives in `TBDShared` so the app can run the same function
over the same facts to *show* what the daemon would choose — the account
picker's row order and the limit banner's suggestion come from one
implementation, not two heuristics that drift apart.

## 4. The pool

The pool is the set of profiles the launch policy and the rotation may choose
from. Membership is derived, with one explicit opt-out:

- **Kind** – `.oauth` and `.oauthToken` only. API-key and Bedrock profiles
  are billed and limited differently and have no usage snapshot to balance
  on; they stay reachable through explicit picks and overrides exactly as
  today.
- **Credential present** – a `.oauth` profile with a `loginIdentity`, or a
  `.oauthToken` profile whose snapshot is not `.needsLogin` or
  `.noCredentials`. A profile nobody has logged into cannot start a session.
- **Not opted out** – a new nullable column `model_profiles.pool_opt_out
  INTEGER`, NULL or `0` meaning "in the pool when otherwise eligible", `1`
  meaning "never choose this one for me". The column has no SQL default, per
  the migration rule, and is not a feature flag: NULL and `0` mean the same
  thing here, and there is nothing to graduate. The opt-out exists because
  a profile can be real and logged in and still not be somewhere the person
  wants unattended fleet sessions to land — a work account, say, or one
  reserved for a specific repo through a repo override.

### 4.1 Account groups

Two profiles can be two views of one account: a signed-in profile and a
setup-token profile minted from the same login share one set of windows. The
picker treats them as one account for load purposes. Its **account key** is
the snapshot's `organizationID` when present, else the profile's
`loginIdentity`, else the profile id. Live-session counts are summed per
account key before scoring, and a rotation away from a limited profile
excludes every profile sharing its account key, because moving a session
between two doors into the same exhausted room does nothing.

## 5. The picker

`ProfilePoolPicker` in `Sources/TBDShared/ProfilePoolPicker.swift` is a pure
function: candidates and a clock reading in, at most one profile id and a
reason out. It holds no state and touches no I/O.

Each **candidate** carries: `profileID`, `kind`, `hasCredential`,
`poolOptOut`, `accountKey`, the `ProfileUsageSnapshot?`, `liveSessions`
(count for this profile alone), `sortOrder`, and `isConfiguredDefault`.

**Eligibility**, in order, each with its own reason so a log line can say
why a profile was passed over:

1. Kind is `.oauth` or `.oauthToken`; otherwise `wrongKind`.
2. `hasCredential`; otherwise `noCredential`.
3. Not opted out; otherwise `optedOut`.
4. Not in the excluded account set (rotation only); otherwise `sameAccount`.
5. The snapshot exists and its `fetchedAt` is within the staleness window —
   five minutes for `.oauth`, fifteen for `.oauthToken`, the same
   cadence-relative thresholds `ProfileUsagePresentation.staleAge` uses;
   otherwise `noFreshReading`. A reading TBD would not present as current is
   not a reading it should route on.
6. Headroom is above the floor; otherwise `exhausted`.

**Headroom** is `1 − max(percent)/100` over the snapshot's `session`,
`weekly_all`, and active `weekly_scoped` buckets. The binding window is the
one that will refuse the next request, whichever it is, so the most-used
window decides. The floor is 5%: a profile at 96% of any window is treated as
full rather than ranked last, because a session landing there will die on its
first long turn.

**Score** is `(accountLiveSessions + 1) / headroom`, lower is better, where
`accountLiveSessions` is the sum of `liveSessions` across the candidate's
account key. Adding one models the session about to be placed. Two profiles
at 40% used with two and zero live sessions score 5.0 and 1.7; the empty one
wins even though their bars match, which is the point — a usage reading is
already minutes behind the sessions that will move it.

**Tie-break** is deterministic: the configured default first, then
`sortOrder`, then the profile id's string. Nothing random. The reference
shape this borrows from (a fleet credential pool on a remote host) uses
power-of-two-choices because its readings can be ten minutes old and a
restart wave would otherwise stampede one account. Here the live-session count
in the numerator is exact and updates on the very spawn being decided — each
placed session is stamped before the next resolves — so a burst of spawns
spreads on its own, and a deterministic pick is both explainable and
testable.

The result names the profile and a `PickReason`
(`leastLoaded`, or nil when nothing was eligible) plus the per-candidate
verdicts, so the resolver can log one line per decision and the app can show
"balanced pick" on the row it would land on.

## 6. The launch policy

A new tri-state config flag, `profile_balancing_enabled` (shipped default
`false`, constant `Config.profileBalancingEnabledDefault`, resolved in
`ConfigRecord.toModel()`), gates one change in
`ModelProfileResolver.resolve(repoID:override:)`:

- **Steps 0, 1 and 1.5 are untouched.** An explicit per-spawn override, a
  repo's override, and the scratch override still win outright. They are the
  person saying "this one", and the policy never argues with that.
- **At step 2 and step 3** — where the chain would return the global default
  or nothing — when the flag is on, the resolver builds the candidate set
  (profiles, snapshots, live counts) and asks the picker. A pick resolves that
  profile through `loadResolved` exactly as the default would have been. No
  pick falls through to today's behavior: the global default if configured,
  else ambient. The policy fails toward the behavior the person had before
  enabling it, never toward a refusal — a single-user tool with nothing
  eligible should still spawn a session.

The candidate set is assembled by a small daemon-side helper,
`ProfilePoolCandidateSource`, from `ModelProfileStore.list()`,
`OAuthUsageSnapshotStore`, `ClaudeProfileConfigDirManager.loginIdentity`, and
a new `TerminalStore.liveSessionCountsByProfile()` — one query,
`SELECT profile_id, COUNT(*) FROM terminal WHERE kind = 'claude' AND
profile_id IS NOT NULL AND hibernated_at IS NULL AND suspended_at IS NULL
GROUP BY profile_id`. A parked session holds no window; only running ones
count.

The resolver logs each balanced decision at `.info`: the chosen profile, its
headroom and account load, and each rejected candidate's reason. The spawn
result is unchanged; the terminal row's `profileID` stamp is the record of
what was chosen, as it is for every other resolution.

Every spawn path that calls `resolve` inherits the policy: terminal create,
worktree create, and revive-fresh. Hibernation wake does not call `resolve` —
it pins to the row's stamp — and must not: a woken session belongs to the
account whose transcript it carries.

## 7. Rotation on a hard limit

`handleRateLimitDetected` gains two behaviors, one ungated and one gated.

### 7.1 Always: name the way out

Whenever a hard limit is reported for a terminal with a stamped profile, the
handler runs the picker with that profile's account key excluded. If a
candidate exists, the `.limitReached` notification names it — "Session limit
hit on Acme — resets 1:01pm. Personal has room (5h 12%)" — and the handler
broadcasts a new `terminalLimitHit` delta carrying the terminal id, the reset
instant, the limit type, and the suggested profile id. The app keeps that
per-terminal fact in memory (cleared when the terminal starts working again,
changes profile, or goes away) and renders a banner over the pane:

```text
┌──────────────────────────────────────────────────────────────────────┐
│ ⚠ Session limit hit on Acme · resets 1:01pm                          │
│   [ Switch to Personal — 5h 12% · 1 live ]  [ Dismiss ]              │
└──────────────────────────────────────────────────────────────────────┘
```

"Switch to" calls `swapTerminalProfile(terminalID:newProfileID:mode:
.inPlace)` — the existing action behind the tab menu's "Swap profile", now
one click away at the moment it is wanted. The banner is app-side state
derived from a daemon delta, not a persisted column: a hard limit is a
transient condition of a live process, and a restart of the app while one is
open loses only a convenience — the notification row and the tab menu's
swap submenu are still there.

An ambient session (no stamp) gets the same banner and the same suggestion
with no account excluded. The person can judge whether the suggestion is the
same account; the daemon cannot, which is why §7.2 never acts on one.

### 7.2 Gated: hand the session over

A second tri-state flag, `limit_rotation_enabled` (shipped default `false`,
constant `Config.limitRotationEnabledDefault`), turns the suggestion into an
action. When it is on and all of the following hold, the handler performs the
swap itself before notifying:

- the terminal has a stamped `profileID` (see the ambient non-goal);
- it is a live, unparked Claude session on the `.tmux` transport with a
  `claudeSessionID` — the in-place swap refuses holder rows and parked rows
  already, and a blank session has nothing to hand over;
- the picker, with the limited account excluded, returned a candidate.

The swap is the existing `handleTerminalSwapProfile` in `.inPlace` mode,
invoked with an `ActuationActor` of kind `daemon` and rail `limit-rotation`
so the actuation log attributes it. The handler then arms the session: it
schedules a `continue` through `LimitResumeScheduler` with `resetsAt` set to
now and `limitType` `rotation`, so the actuator's existing eligibility checks
— pane not in copy mode, Claude foreground, transcript not already advanced —
gate the keystroke exactly as they do for a reset-time resume. The person's
dead turn resumes on the new account roughly a minute after the limit, with
no gesture.

That `continue` belongs to the rotation feature, not to the reset-time one.
The scheduler re-checks a row's governing toggle at fire time and every toggle
cancels only its own rows when switched off, so a `rotation` row is governed by
`limit_rotation_enabled` — `Config.autoResumeEnabled(forLimitType:)` maps it
there, and turning rotation off cancels pending `rotation` rows and no others.
Without that mapping a person who enabled rotation but never touched the older
`autoResumeOnLimitReset` toggle would see the swap succeed and the `continue`
silently cancelled at fire time, which is the manual-gesture dependency this
feature exists to remove. The notification reads "Session limit hit on Acme — switched to
Personal (5h 12%)".

If the swap fails for any reason, the handler logs it and falls through to
§7.1 and to today's reset-time behavior, so a failed hand-over degrades to
the current experience rather than to silence. A successful rotation does
**not** also schedule the reset-time resume: the session is no longer on the
limited account, and typing `continue` into it at that account's reset would
be a stray keystroke into a working session.

Rotation runs once per limit report. The pending-resume latch already
prevents a repeat `StopFailure` on the same limit from scheduling twice; a
rotated session that hits a limit on its *new* account produces a fresh
report against that account and is handled afresh, which is correct — it is
a different account's limit.

### 7.3 Why not rotate everything

The two constraints above — stamped profile, tmux transport — are the
boundary of what TBD can hand over *safely*, which is what the request asked
for. A holder-backed session has no in-place respawn yet (the swap handler
refuses it for the reasons in its own comment), and an ambient session's
account is unknowable. Both still get the banner. Widening either is a
separate change with its own evidence; this design does not pretend to a
guarantee it cannot keep.

## 8. Surfaces

### 8.1 Settings → Model Profiles

Two toggles under the global-default picker, reading from
`DaemonCapabilitiesResult` and writing through two new config RPCs, following
the `queuedPromptToggle` shape:

- **Balance new Claude sessions across accounts** –
  `config.setProfileBalancingEnabled`. Help text: "When a new session would
  use the global default, pick the signed-in profile with the most room
  instead. Repo overrides and explicit picks still win. Off by default
  (soaking)."
- **Switch account when a session hits its limit** –
  `config.setLimitRotationEnabled`. Help text: "When a session hits a hard
  usage limit, resume it in the same tab on another profile with room and
  continue the turn. Off by default (soaking)."

Each profile row gains a checkbox in its `⋯` menu, **Include in balancing**,
checked unless `poolOptOut` is set, writing `modelProfile.setPoolOptOut`.
Rows show a `live` count beside the usage line — "5h 61% · 7d 38% · 2 live"
— computed app-side from `appState.terminals` (Claude, unparked, matching
`profileID`). No RPC carries the count: the app already holds every
terminal.

### 8.2 Account picker and swap menu

`AccountPickerSheet` rows and `SwapProfileMenu.menuLabel` append the live
count to the usage summary. The picker's sort order becomes the picker
function's order when balancing is on (the row it would choose is first and
carries a "balanced pick" caption); when off, the existing display-only
`sortedForPicker` order is unchanged. Nothing is auto-selected in the sheet
in either state — the sheet exists for the person to choose.

### 8.3 The tab

The tab label already reads `<profile name> <n>` and the hover card already
names the pinned identity and usage; both are the "this session's profile"
indicator and are unchanged. The limit banner (§7.1) is new.

### 8.4 CLI

- `tbd profile balancing on|off` and `tbd profile rotation on|off` – the two
  flags, under the profile noun per the soak-flag convention.
- `tbd profile pool <name> include|exclude` – the per-profile opt-out.
- `tbd profile list` gains a `live` column and, in `--json`, a
  `liveSessions` integer per profile plus a top-level `balancing` object
  `{ enabled, rotationEnabled }`. This is an additive change to the
  capacity-facts contract and is recorded in `docs/capacity-facts.md` as
  such.

## 9. Data model

Three migrations, each one `.sql` file with no `DEFAULT` clause:

- `config.profile_balancing_enabled INTEGER` – tri-state flag.
- `config.limit_rotation_enabled INTEGER` – tri-state flag.
- `model_profiles.pool_opt_out INTEGER` – per-profile opt-out, NULL ≡ 0.

`ConfigRecord`, `Config`, `DaemonCapabilitiesResult`, `ModelProfileRecord`
and `ModelProfile` gain the matching fields, decoded with `decodeIfPresent`
and the shipped default so older JSON and rows still decode. `ModelProfile`
gains `poolOptOut: Bool` defaulting to `false`.

One new `StateDelta` case, `terminalLimitHit(TerminalLimitHitDelta)`,
appended after the existing cases (case names are wire-visible).

No new durable external resource is created. The swap path this reuses
respawns into an existing tmux window and row, both already reconciled by
`WorktreeLifecycle+Reconcile` and `AgentReaper`; the transcript copy into the
destination config dir is the same best-effort carry the manual swap performs
today, under a directory `OrphanGC` already sweeps.

## 10. Testing

Both branches of every flag, per the repo rule.

- **Picker** (`Tests/TBDSharedTests/ProfilePoolPickerTests.swift`) – each
  eligibility rule rejects with its own reason and admits when satisfied:
  wrong kind, missing credential, opted out, excluded account, stale
  snapshot for each kind at its own threshold, exhausted at the floor.
  Scoring: an empty profile beats a loaded one at equal usage; a lower-usage
  profile beats a higher one at equal load; the binding window is the
  maximum across buckets, with an inactive scoped bucket ignored. Account
  grouping: two profiles sharing an `organizationID` pool their live counts,
  and excluding one excludes the other. Tie-break: default, then sort order,
  then id, and the same input always yields the same output. Empty and
  all-ineligible inputs return nil with the verdicts populated.
- **Flags** (`Tests/TBDDaemonTests/Config/ProfileBalancingFlagTests.swift`,
  `LimitRotationFlagTests.swift`) – the three-state roster the
  retained-transcripts flag uses: NULL before any gesture, NULL survives a row
  written before the migration, explicit `false` survives a default flip
  while NULL follows it, shipped default off, setter round-trips, cross-flag
  isolation (balancing on does not turn rotation on, and vice versa).
- **RPC** – wire-name pins and round trips for the two config setters and
  `modelProfile.setPoolOptOut`; the opt-out records an explicit `1`, and
  clearing it records `0`, not NULL.
- **Resolver** – with balancing off, steps 2 and 3 behave exactly as today
  (pinned by the existing resolver tests). With it on: an explicit override
  and a repo override still win; at step 2 the picker's choice replaces the
  default; at step 3 it replaces ambient; with nothing eligible, step 2
  returns the default and step 3 returns nil; the live-count query excludes
  parked rows and non-Claude rows.
- **Rate-limit handler** – with rotation off: the notification names the
  suggestion when one exists and omits it when none does, the delta is
  broadcast, and the reset-time path is unchanged. With rotation on: a
  stamped tmux session with a candidate is swapped, a `continue` is
  scheduled at now with `limitType` `rotation`, and no reset-time resume is
  scheduled; an ambient session is not swapped; a parked or holder session
  is not swapped; a swap failure falls through to the off-path notification
  and the reset-time schedule; no candidate falls through likewise.
- **Limit parsing** – `RateLimitDetectionTests` already covers the
  structured path, the weekly and session text wordings, zone conversion and
  the transient exclusions. This adds the cases the rotation newly depends
  on: a structured `rejected` record carries its `rateLimitType` through as
  the `limitType` the handler reports; a structured record whose `resetsAt`
  is not a number falls back to the text rules rather than being dropped;
  and a rejected record with no usable reset and no parseable text detects
  nothing, so no rotation can fire on a message the detector could not
  place in time.
- **App** – the live count counts unparked Claude terminals for the profile
  only; the banner appears on `terminalLimitHit`, disappears when the
  terminal reports `.working`, and its action calls the swap with
  `.inPlace`; the picker sheet's order follows the picker when balancing is
  on and `sortedForPicker` when off.

## 11. Rollout

Both flags ship off. To soak:

```text
tbd profile balancing on
tbd profile rotation on
```

or the two toggles in Settings → Model Profiles. Graduation for each is a
one-line change to its `Default` constant, which reaches everyone who never
touched the toggle and preserves every explicit opt-out; the flag is deleted
once the soak has shown the picker's choices match what the person would
have chosen, and the rotation has not moved a session anyone wanted left
alone. The per-profile opt-out is not a flag and has no graduation.

## 12. Rejected alternatives

- **Power-of-two-choices with randomization.** Right for a fleet reading
  ten-minute-old quota snapshots where a restart wave would pile onto one
  account. Here the live count is exact at decision time and each spawn
  stamps its row before the next resolves, so a deterministic argmin
  spreads a burst on its own and is explainable from the screen.
- **Failing closed when no profile is eligible.** Correct for an unattended
  fleet where a wrong account is worse than no session. Wrong for a person at
  a keyboard, who would rather have a session on the default and a
  notification than no session; and the fallback is precisely the behavior
  they had before enabling the flag.
- **Balancing above repo overrides.** Tempting because it balances more, but
  a repo override is the person telling TBD which account a repo's work
  belongs on. Overriding it silently is the kind of surprise a load
  balancer must not produce.
- **Rotating ambient sessions.** TBD cannot name the account, so it cannot
  exclude it, so it could move a session onto the account it just exhausted.
  A suggestion the person can judge is the honest ceiling.
- **A persisted limit-hit column on `terminal`.** A hard limit is a
  transient state of a live process, and every consumer of it is the running
  app. A column would need clearing on every state transition that ends the
  condition, and a stale one would show a banner on a session that has long
  since recovered. The delta plus in-memory app state has one failure mode —
  an app restart forgets the banner — and the notification row survives it.
- **Reading utilization from the statusline payload fleet-wide.** The tee
  would displace the operator's own statusline in every session (the reason
  it is desk-only today), for a reading at most 90 seconds fresher than the
  poller's for signed-in profiles, and no fresher than the per-turn probe for
  token profiles.
- **Pooling all profiles regardless of kind.** API-key and Bedrock profiles
  have no comparable window readings; ranking them alongside subscription
  profiles would be comparing a number to its absence.

## 13. Decisions taken from the request, and what remains open

The request named the shape: a pool with usage awareness, a least-used
launch policy with a visible per-session profile, rotation on a limit hit
with at minimum a one-click relaunch and automatic hand-over where safe, a
per-profile usage view with live counts, and tests for the picker and the
limit parsing. The design above follows that shape; where it had to choose,
it chose as follows, and each is a point the person can overturn.

- **Two flags, not one.** Balancing new spawns and moving a running session
  are different risks — the second sends input to a session — so each soaks
  on its own. A single "load balancing" switch would force the cautious
  person to take both or neither.
- **The pool is opt-out, not opt-in.** A person enabling balancing wants it
  to balance; making every profile opt in would ship a flag that does nothing
  until a second gesture per profile.
- **Headroom on the binding window, not the 5-hour window alone.** A profile
  with 5-hour room and no weekly room dies on its next long turn; the
  weekly limit is the one that takes days to clear.
- **The rotation types `continue` through the existing actuator.** A resumed
  session sits idle at its prompt; without the keystroke the hand-over
  leaves the person's dead turn dead on a healthier account. Routing it
  through `LimitResumeScheduler` reuses every safety check that rail already
  has.

Open, for the person to confirm during the soak:

- Whether the 5% headroom floor and the 90-second-relative staleness
  thresholds are the right constants, or whether the floor should scale with
  the number of live sessions an account already carries.
- Whether balancing should also apply to the scratch override tier (step
  1.5). This design leaves it as an explicit choice that wins.
