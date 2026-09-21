# Account load balancing

When you run multiple Claude accounts through different TBD profiles, TBD can spread new sessions across your accounts, and when a session hits its usage limit it offers a one-click switch to an account with room.

## What it does

Three behaviors work together:

- **Balanced new sessions** – when you spawn a Claude session without specifying an account, TBD picks the profile with the most available capacity instead of always using the global default. Explicit picks, repo overrides, and scratch-session overrides all still win.
- **Live-session counts** – the profile list in Settings, the account picker, and the tab swap menu now show how many active sessions each account is carrying, so you can see the load being balanced.
- **One-click switch on limit** – when a session hits its hard usage limit, the notification names an account with room and a banner over the pane offers "Switch to …". Clicking it resumes the conversation on that account in the same tab; TBD never makes the switch for you.

Everything else stays the same: explicit per-spawn picks, per-repo profile locks, per-worktree scratch overrides, and hibernation wake all work exactly as before. Only brand-new sessions are balanced — resuming or reviving an existing conversation keeps the account TBD would have used before balancing, because the conversation's transcript lives with that account.

## The pool

The balancing pool is the set of profiles TBD can choose from. It includes:

- **Signed-in OAuth profiles** – profiles you've logged into with `/login`, plus profiles created from a setup token
- **With active credentials** – the profile must have a login identity that TBD can use to check usage. Bedrock and API-key profiles are excluded because their limits work differently.

You can keep a logged-in profile out of the pool without deleting it — useful for work accounts or repo-specific overrides you want to protect:

```sh
tbd profile pool Acme exclude
tbd profile pool Personal include
```

Or use **Include in balancing** in the ⋯ menu on each profile in Settings. The pool works by account: if you have both a signed-in profile and a setup-token profile on the same account (same organization ID or login), TBD treats them as one account for counting load.

## How the pick works

When balancing is on and a new session would land on the global default, TBD builds a score for each eligible profile:

- **Fresh reading** – TBD checks each profile's usage every 90 seconds (signed-in OAuth) or after each turn (setup-token). A reading older than 5 minutes (OAuth) or 15 minutes (setup-token) is too stale to route on, and the profile is skipped.
- **Headroom** – TBD measures the profile's available space on whichever rate-limit window is closest to full: your 5-hour session window, your weekly-all window, or your weekly per-model window. A profile at 96% or higher on any window is treated as full (the 5% floor) regardless of the others.
- **Account load** – the score is `(live sessions on this account + 1) / headroom`. Lower is better. Two accounts at equal usage still score differently if one carries more active sessions, because the live count is exact at decision time and the usage reading is minutes old.
- **Tie-break** – when scores tie, TBD picks the configured global default first, then the profile's sort order, then the profile ID. The tie-break is deterministic and explainable: nothing random.

If nothing qualifies, TBD falls back to the old behavior: global default if set, or no profile (ambient).

## Switching accounts on a limit hit

When a session hits a hard usage limit, you see a notification and a banner in the tab:

```
⚠ Session limit hit on Acme — resets 1:01pm
[ Switch to Personal — 5h 12% · 1 live ]  [ Dismiss ]
```

Clicking **Switch to** reopens your conversation on Personal in the same tab. The suggestion is always the best-scoring profile on a different account from the one that hit the limit; ambient sessions get a suggestion too. When no other account has room, the banner shows only the reset time.

TBD never switches accounts on its own and never resumes the dead turn for you after a switch: the button is the only way a session changes account at a limit. Send a message after switching to carry on. The older "auto-resume when the limit resets" toggle still types `continue` at reset time on the original account, and is unaffected by the suggestion.

## Flags and configuration

One feature flag, default **off** and soaking:

**`profile_balancing_enabled`** – spreads new sessions across accounts. Enable with:

```sh
tbd profile balancing on
```

or **Balance new Claude sessions across accounts** in Settings → Model Profiles. The help text reminds you that repo overrides and explicit picks still win.

A second column, `limit_rotation_enabled` (`tbd profile rotation on|off`), is still stored and reported, but no behavior reads it: a limit hit only ever offers the switch button.

The flag is tri-state: `NULL` (never chosen), `0` (explicit off), or `1` (explicit on). The shipped default is `NULL` on every install. Flipping the source default graduates the flag to everyone who hasn't explicitly chosen, while preserving every intentional opt-out. The per-profile pool opt-out is a setting, not a flag, with no graduation.

## Seeing the load

**Settings** – each profile row now shows live sessions beside usage: "5h 61% · 7d 38% · 2 live".

**Account picker and swap menu** – live counts appear in the usage summary. When balancing is on, the picker reorders rows to match the balanced pick, and the row TBD would choose carries a "balanced pick" caption.

**CLI** – use `tbd profile list --json` to see all profiles, their live counts, and the current flag state:

```sh
tbd profile list --json | grep -E '"name"|"live|"enabled"'
```

Check the design spec in `docs/capacity-facts.md` for the full schema and the `balancing` object in the output.

**Logs** – the daemon logs each balanced decision at info level with the chosen profile, headroom, account load, and why each rejected candidate was skipped. See troubleshooting below.

## Troubleshooting

**"Why did TBD pick profile X?"** – the daemon logs one line per spawn at `com.tbd.daemon / modelProfileResolver`. See the picked profile, its headroom, and each rejected candidate's reason:

```sh
log show --predicate 'subsystem == "com.tbd.daemon" AND category == "modelProfileResolver"' --last 10m
```

or stream live decisions:

```sh
log stream --level info --predicate 'subsystem == "com.tbd.daemon" AND category == "modelProfileResolver"'
```

**A profile is never chosen** – check:
- **Is it in the pool?** No fresh reading (not logged in, or usage poller failing) → no pick. Wait 5–15 min, then check `tbd profile list`.
- **Opted out?** Use `tbd profile pool <name> include` or uncheck **Include in balancing**.
- **At the floor?** A profile at 96%+ headroom is treated as full and passed over.
- **Balancing off?** `tbd profile balancing on` to enable it.

**No "Switch to" button on the limit banner** – no profile on another account qualified. The same rules as a balanced pick apply (fresh reading, not opted out, below the floor), and every profile on the exhausted account is excluded.
