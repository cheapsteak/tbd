# Account load balancing across Claude profiles

TBD already knows, per Claude profile, how much of the 5-hour and 7-day
windows an account has used, and it already knows which profile every session
runs under. What it does not do is act on either fact: a new session lands on
whichever profile the precedence chain names, and a session that hits its
limit sits dead until its window resets or a person swaps it by hand. This
design adds three behaviors on top of the facts TBD already gathers: a launch
policy that spreads new sessions across the profiles with the most room, a
one-click "Switch to …" offer naming an account with room when a running
session hits a hard limit, and a live-session count beside the usage bars so
the person can see the load the policy is balancing. All three run entirely
on machinery that exists today — the usage snapshots, the `terminal.profile_id`
stamp, and the in-place profile swap. The launch policy, the only one that
acts without a gesture, ships behind a default-off flag; the limit offer never
acts on its own.

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
- A session that hits a hard usage limit is offered, one click away, a
  resume on another account with room, in the same tab, without losing the
  conversation. The person makes that move; TBD never makes it for them.
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
- Moving a running session on its own. A session that has hit a limit is
  offered a switch; a session that has not is left alone. The policy acts
  without a gesture at one moment only — spawn.
- Resuming an interrupted turn on the person's behalf. After a switch the
  session waits at its prompt for the person, as it does after a manual swap.
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
function over facts the daemon already exposes, and the launch policy is
compiled because it needs the daemon's own moment-of-action — a spawn
resolves its profile inside the daemon, and a user-land script reading
`tbd profile list --json` could not intercept it. The limit offer is compiled
only as far as naming the suggestion in the existing limit notification and
delta; the action behind it is the existing swap RPC, which a script can
drive just as well.

The picker itself lives in `TBDShared` so the app can run the same function
over the same facts to *show* what the daemon would choose — the account
picker's row order and the limit banner's suggestion come from one
implementation, not two heuristics that drift apart.

## 4. The pool

The pool is the set of profiles the launch policy and the limit offer may choose
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
account key before scoring, and a suggestion away from a limited profile
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
4. Not in the excluded account set (limit suggestion only); otherwise
   `sameAccount`.
5. The snapshot exists and its `fetchedAt` is within the staleness window —
   five minutes for `.oauth`, fifteen for `.oauthToken`, the same
   cadence-relative thresholds `ProfileUsagePresentation.staleAge` uses;
   otherwise `noFreshReading`. A reading TBD would not present as current is
   not a reading it should route on. A reading that stays stale usually
   means a lapsed login or a failing poll, which only the person can fix, so
   the skip is surfaced rather than silent (§6.1).
6. Headroom is above the floor; otherwise `exhausted`.

**Headroom** is `1 − max(percent)/100` over the snapshot's `session`,
`weekly_all`, and active `weekly_scoped` buckets. The binding window is the
one that will refuse the next request, whichever it is, so the most-used
window decides. The floor is 5%: a profile at 95% or more of any window is treated as
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
in the numerator is exact at decision time — pick reservations (§6.2) count
every placement the daemon has made whose terminal row has not landed yet —
so a burst of spawns spreads on its own, and a deterministic pick is both
explainable and testable.

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

Only a fresh session is balanced: terminal create and worktree create when
they start a new conversation. A spawn that resumes an existing conversation
— terminal create with a resume id, worktree create restoring archived
sessions, reviving a closed terminal, and revive-fresh — resolves with
balancing off and gets the stable pre-balancing answer. A conversation
belongs to the account whose config dir holds its transcript, and the
history row does not record which one that is; a load-sensitive pick could
send `claude --resume` to an account that has never seen the session.
Hibernation wake does not call `resolve` at all — it pins to the row's
stamp — for the same reason.

### 6.1 Surfacing a stale account

An account skipped as `noFreshReading` is otherwise pool-eligible — it has a
credential and is not opted out — yet balancing cannot see it. Left silent,
the pool quietly shrinks to the accounts whose polls happen to be healthy.

When a balanced pick skips such an account, the daemon posts one
`.attentionNeeded` notification on the spawning worktree: "Usage for
Personal hasn't refreshed in 42 min — balancing is skipping it; check its
login" ("has no usage reading yet" when there has never been one). A small
in-memory latch keyed by profile holds it to once: the latch clears when a
balanced pick next sees that account with a fresh reading, so a relapse
notifies again. A daemon restart clears the latch too, which costs at most
one repeat notification. Because the notification comes from the pick, it
fires only while balancing is on and only for accounts in the pool.

Settings carries the same fact without waiting for a spawn: while balancing
is on, a profile row whose candidate verdict is `noFreshReading` shows a
"stale — skipped by balancing" badge beside its usage line. The app computes
it from the same shared candidate rule and picker the daemon uses (§3).

### 6.2 Pick reservations

A spawn resolves its profile well before its terminal row is written — the
tmux window and the Claude process come first — and the only lock on the
spawn path is per worktree. Two spawns into different worktrees can therefore
both resolve against the same live counts, and without a correction both land
on the same account: exactly the burst the policy exists to spread.

The daemon keeps one in-memory `ProfilePickReservations` actor, shared by
every resolver. A balanced resolve does all of its reads first — profiles,
snapshots, live counts — and then makes one non-suspending call into the
actor. That call adds each profile's outstanding reservations to its live
count, runs the picker, and records a reservation for the winner. Because
the call never suspends, no second pick can interleave with it, which actor
isolation alone would not guarantee across an `await`.

The resolved profile carries its reservation's id, and the spawn path
settles that reservation by id as soon as it has written the terminal row.
Settling by id rather than by matching rows means an unrelated session
landing on the same profile — an explicit pick, a repo override — never
cancels a reservation it did not make. Between the row insert and the settle
the session counts twice, which errs toward spreading. A reservation also
stops counting when it is two minutes old, so a spawn that fails after
picking cannot hold a phantom session forever. Reservations live only in memory: a daemon restart drops
them, and by then every placed session is either a row or never started.
Only the spawn-time pick reserves; the limit suggestion (§7) names an account
without placing anything on it.

## 7. The switch offer on a hard limit

Whenever a hard limit is reported for a terminal, `handleRateLimitDetected`
runs the picker with the limited profile's account key excluded. If a
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
one click away at the moment it is wanted. The swap resumes the conversation
on the new account and leaves it at its prompt; the person sends the next
message, exactly as after a manual swap. The banner is app-side state derived
from a daemon delta, not a persisted column: a hard limit is a transient
condition of a live process, and a restart of the app while one is open loses
only a convenience — the notification row and the tab menu's swap submenu are
still there.

An ambient session (no stamp) gets the same banner and the same suggestion
with no account excluded. The person can judge whether the suggestion is the
same account; the daemon cannot.

The offer is the whole of the limit behavior. The handler never swaps a
session and never types into one on its own: moving a session to another
account and resuming its interrupted turn are the person's moves. The existing
reset-time resume (`autoResumeOnLimitReset`) is untouched and independent —
when it is on, its schedule and the switch offer ride in the same
notification, and that feature's own checks — the transcript-growth cancel,
Claude in the foreground — still govern whether its `continue` fires.

## 8. Surfaces

### 8.1 Settings → Model Profiles

One toggle under the global-default picker, reading from
`DaemonCapabilitiesResult` and writing through a new config RPC, following
the `queuedPromptToggle` shape:

- **Balance new Claude sessions across accounts** –
  `config.setProfileBalancingEnabled`. Help text: "When a new session would
  use the global default, pick the signed-in profile with the most room
  instead. Repo overrides and explicit picks still win. Off by default
  (soaking)."

The limit offer (§7) has no toggle: it acts only on a click, so there is
nothing for a switch to make safer.

Each profile row gains a checkbox in its `⋯` menu, **Include in balancing**,
checked unless `poolOptOut` is set, writing `modelProfile.setPoolOptOut`.
Rows show a `live` count beside the usage line — "5h 61% · 7d 38% · 2 live"
— computed app-side from `appState.terminals` (Claude, unparked, matching
`profileID`), and, while balancing is on, the stale badge of §6.1. No RPC
carries the count: the app already holds every terminal.

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
indicator and are unchanged. The limit banner (§7) is new.

### 8.4 CLI

- `tbd profile balancing on|off` – the flag, under the profile noun per the
  soak-flag convention.
- `tbd profile pool <name> include|exclude` – the per-profile opt-out.
- `tbd profile list` gains a `live` column and, in `--json`, a
  `liveSessions` integer per profile plus a top-level `balancing` object
  `{ enabled }`. This is an additive change to the
  capacity-facts contract and is recorded in `docs/capacity-facts.md` as
  such.

## 9. Data model

Two migrations, each one `.sql` file with no `DEFAULT` clause:

- `config.profile_balancing_enabled INTEGER` – tri-state flag.
- `model_profiles.pool_opt_out INTEGER` – per-profile opt-out, NULL ≡ 0.

`ConfigRecord`, `Config`, `DaemonCapabilitiesResult`, `ModelProfileRecord`
and `ModelProfile` gain the matching fields, decoded with `decodeIfPresent`
and the shipped default so older JSON and rows still decode. `ModelProfile`
gains `poolOptOut: Bool` defaulting to `false`.

One new `StateDelta` case, `terminalLimitHit(TerminalLimitHitDelta)`,
appended after the existing cases (case names are wire-visible).

No new durable external resource is created. Pick reservations and the
stale-notification latch live in daemon memory. The swap path the limit
offer reuses
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
- **Flag** (`Tests/TBDDaemonTests/Config/ProfileBalancingFlagTests.swift`) –
  the three-state roster the retained-transcripts flag uses: NULL before any
  gesture, NULL survives a row written before the migration, explicit
  `false` survives a default flip while NULL follows it, shipped default
  off, setter round-trips.
- **Credential rule** – one shared function decides credential presence for
  both the daemon's and the app's candidates, each branch tested, so the
  app's "balanced pick" cannot disagree with the daemon's.
- **RPC** – wire-name pins and round trips for the config setter and
  `modelProfile.setPoolOptOut`; the opt-out records an explicit `1`, and
  clearing it records `0`, not NULL.
- **Resolver** – with balancing off, steps 2 and 3 behave exactly as today
  (pinned by the existing resolver tests). With it on: an explicit override
  and a repo override still win; at step 2 the picker's choice replaces the
  default; at step 3 it replaces ambient; with nothing eligible, step 2
  returns the default and step 3 returns nil; the live-count query excludes
  parked rows and non-Claude rows.
- **Pick reservations** – two balanced resolves with no terminal row written
  between them, against two otherwise identical profiles, choose different
  profiles (the interleaving of two concurrent spawns; this fails without
  reservations); settling a reservation stops it counting; unrelated rows
  landing on a reserved profile do not erase its reservations; an expired
  reservation stops counting; concurrent resolves split evenly. A resolve
  with balancing off — the resume paths — returns the default and reserves
  nothing.
- **Stale surfacing** – a balanced pick that skips an otherwise-eligible
  account for `noFreshReading` notifies once on the spawning worktree; a
  second skip does not notify again; a fresh reading clears the latch so a
  relapse notifies; an account skipped for any other reason, or any skip with
  balancing off, never notifies. The Settings badge shows for a stale pool
  account only while balancing is on.
- **Rate-limit handler** – the notification names the suggestion when one
  exists and omits it when none does; the limited account is excluded for a
  stamped session and nothing is excluded for an ambient one; the delta is
  broadcast with the suggestion; the reset-time path is unchanged; and no
  swap and no `continue` ever originate from the handler.
- **Limit parsing** – `RateLimitDetectionTests` already covers the
  structured path, the weekly and session text wordings, zone conversion and
  the transient exclusions. This adds the cases the limit offer newly
  depends on: a structured `rejected` record carries its `rateLimitType` through as
  the `limitType` the handler reports; a structured record whose `resetsAt`
  is not a number keeps that structured type when the reset instant comes
  from the text rules; and a rejected record with no usable reset and no parseable text detects
  nothing, so no offer is made on a message the detector could not place in
  time.
- **App** – the live count counts unparked Claude terminals for the profile
  only; the banner appears on `terminalLimitHit`, disappears when the
  terminal reports `.working`, and its action calls the swap with
  `.inPlace`; the picker sheet's order follows the picker when balancing is
  on and `sortedForPicker` when off.

## 11. Rollout

The flag ships off. To soak:

```text
tbd profile balancing on
```

or the toggle in Settings → Model Profiles. Graduation is a one-line change
to `Config.profileBalancingEnabledDefault`, which reaches everyone who never
touched the toggle and preserves every explicit opt-out; the flag is deleted
once the soak has shown the picker's choices match what the person would
have chosen. The limit offer ships on, since it acts only on a click. The
per-profile opt-out is not a flag and has no graduation.

## 12. Rejected alternatives

- **Power-of-two-choices with randomization.** Right for a fleet reading
  ten-minute-old quota snapshots where a restart wave would pile onto one
  account. Here the live count is exact at decision time — rows plus pick
  reservations (§6.2) — so a deterministic argmin spreads a burst on its own
  and is explainable from the screen.
- **Failing closed when no profile is eligible.** Correct for an unattended
  fleet where a wrong account is worse than no session. Wrong for a person at
  a keyboard, who would rather have a session on the default and a
  notification than no session; and the fallback is precisely the behavior
  they had before enabling the flag.
- **Balancing above repo overrides.** Tempting because it balances more, but
  a repo override is the person telling TBD which account a repo's work
  belongs on. Overriding it silently is the kind of surprise a load
  balancer must not produce.
- **Handing a limited session over automatically.** The daemon has every
  fact it would need to swap a limited session to an account with room and
  type `continue`, and that would remove the last gesture. It would also
  make TBD move a person's work between accounts and send input to a session
  nobody was watching, on the strength of a usage reading that can be
  minutes old. A switch the person clicks keeps both of those decisions with
  the person, at the cost of one click, and the banner puts that click where
  they are already looking.
- **Serializing whole spawns across worktrees.** A daemon-wide spawn lock
  would close the concurrent-pick window too, but it would hold every spawn
  behind every other's tmux and process start, which take seconds. A
  reservation closes the same window around the only step that needs it.
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

## 13. Decisions

The requester answered each of these; the design above states them as its
own.

- **An eligible account is in the pool unless the person excludes it.**
  Turning balancing on balances immediately; the opt-out is for accounts the
  person wants kept out of unattended fleet work.
- **An explicit account choice always wins.** A per-spawn pick, a repo
  override and a scratch override are the person saying "this one", and
  balancing fills in only where the global default would have applied.
- **At a hard limit, TBD offers a switch and never makes one.** No automatic
  hand-over and no automatic resume of the interrupted turn: the banner's
  "Switch to …" is the person's move, and the next message is theirs. The
  older reset-time auto-resume is a separate feature and is unchanged.
- **One flag, and the switch button always shows.** With automatic hand-over
  out, the only thing left at a limit is a button that does nothing without
  a click, so it needs no soak switch of its own; balancing new sessions is
  the one behavior that acts on its own, and it is the one that is flagged.
- **Headroom is measured on the binding window.** The fuller of the 5-hour
  and weekly windows decides: a profile with 5-hour room and no weekly room
  dies on its next long turn, and the weekly limit takes days to clear.
- **Full means 95% of any window.** The 5% headroom floor is fixed; a
  profile past it is skipped rather than ranked last, because a session
  placed there dies on its first long turn.
- **A reading is current for five minutes (signed-in) or fifteen
  (setup-token)** — the thresholds the UI already uses to mark a reading
  stale. An account skipped for a stale reading is surfaced once as a
  notification and continuously as a Settings badge (§6.1), because only the
  person can fix what keeps it stale.
- **If nothing is eligible, the session starts where it would have without
  balancing** (§12, failing closed).
