# TBD Diagnostics Strategy

## Problem

Every bug investigation follows the same painful loop: add `print()` statements,
reproduce, read output, remove the prints before commit, then re-add nearly
identical prints the next time something in the same area breaks. Diagnostic
work is thrown away after each session, and the next investigator starts from
zero. Meanwhile, the few logs that *do* survive are noisy enough that nobody
streams them by default.

We want the opposite: **rich diagnostics permanently in the code, silent unless
asked for, scoped narrowly enough that turning them on doesn't drown you.**

## Principle

> Every interesting event in TBD should already be logged. The default log
> stream should still be quiet enough to read. Turning on detail for one area
> should never require a rebuild.

Three rules follow from this:

1. **Never delete a log line to reduce noise.** Lower its level instead.
2. **Never add a `print()`.** If it's worth printing during a bug hunt, it's
   worth keeping at `.debug` forever.
3. **Categories are cheap.** One per meaningful subsystem boundary, not one
   per file. Bug hunts happen along feature seams, not file seams.

## Mechanism: os.Logger levels as the always-on/opt-in dial

`os.Logger` already gives us exactly what we need; we just have to use it on
purpose. macOS suppresses `.debug` and `.info` from the default stream and only
surfaces them when a developer asks for them with `log stream --level debug`.
That means `.debug` lines are **free at runtime and invisible by default** —
ideal for the kind of trace output that today gets written as `print()` and
deleted an hour later.

### Level taxonomy

| Level     | When to use                                                                                                              | Visible by default? |
|-----------|--------------------------------------------------------------------------------------------------------------------------|---------------------|
| `.debug`  | Per-event traces: "received X", "computed Y", "about to call Z". The stuff you'd `print()` during a bug hunt.            | No (ring buffer only — see below) |
| `.info`   | Lifecycle milestones inside a subsystem: "tmux server started", "resolved ssh agent at /tmp/...", "loaded N worktrees".  | No (briefly retained)             |
| `.notice` | Things a user-facing operator should see in Console.app without filtering: startup, shutdown, config changes, migrations.| **Yes** (default)   |
| `.error`  | Recoverable failures. The operation didn't happen but the process is fine.                                               | Yes                 |
| `.fault`  | Invariants violated, programmer errors, "this should never happen". Pair with `assertionFailure` in debug builds.        | Yes                 |

The promise to ourselves: **default log stream = `.notice` and up only.** If
you're tempted to demote a `.notice` because it's noisy, that means it should
have been `.info` from the start.

Note on persistence: only `.notice` and above are persisted to disk by default.
`.info` is retained briefly. `.debug` lives in an in-memory ring buffer and is
**not** persisted unless either (a) a `log stream` subscriber is active, or
(b) you've raised the subsystem's persistence with `log config` (see Streaming
Recipes). This affects the "reproduce then `log show --last 5m`" workflow:
without the config bump, `log show` will only return `.info`+ for past events.

Note on cost: `.debug` is *near*-free, not free. The format string is deferred,
but argument capture (value copies, autoclosure setup) still runs. Don't put
`.debug` inside per-byte NIO handlers, per-frame draw code, or other genuine
hot paths. Per-message / per-event is fine.

### Privacy interpolation (read this — it bites everyone once)

`Logger` redacts every dynamic interpolation as `<private>` by default. If you
write `logger.debug("opened url \(url)")` you will see `opened url <private>`
in Console and conclude logging is broken. It isn't.

Convention for TBD (an internal developer tool, not a shipping consumer app
handling user PII):

- **Default to `.public` for dynamic interpolations.** Be explicit: every
  dynamic interpolation gets a `privacy:` argument. No exceptions, even when
  `.public` is what you want — explicitness keeps reviewers honest.
- **Mark secrets `.private` or `.sensitive`**: API tokens, ssh key contents,
  anything from `~/.ssh`, environment variables that might contain creds.
- **File paths and URLs are `.public`** — they're the whole point of most TBD
  diagnostics.

```swift
logger.debug("link tap url=\(url, privacy: .public) mods=\(mods.rawValue, privacy: .public)")
logger.debug("ssh agent socket=\(path, privacy: .public)")
logger.error("auth failed token=\(token, privacy: .private)")
```

### Message format: prefer `key=value`

Use `key=value` pairs inside log messages so `log show --predicate
'eventMessage CONTAINS "url="'` stays grep-friendly across the codebase. The
worked example below follows this convention; everything new should too.

### Subsystem and category conventions

Two subsystems exist today and should remain the only two:

- `com.tbd.app` — TBDApp (SwiftUI process)
- `com.tbd.daemon` — TBDDaemon (background process)

**Categories should map to feature areas, not file names.** Today we have
categories like `AppState+Notes`, `AppState+Repos`, `AppState+Worktrees`, etc.
That's a file taxonomy, and it makes "stream everything related to worktree
creation" impossible because the relevant log lines are split across categories
that share no naming convention.

Proposed taxonomy (each is one category, used by however many files
participate):

| Category            | Covers                                                          |
|---------------------|------------------------------------------------------------------|
| `worktrees`         | Create / list / rename / delete, git worktree shellouts          |
| `terminals`         | Terminal lifecycle as a *feature*: create/destroy, send/output, what the user asked for |
| `tmux`              | tmux as a *transport*: TmuxManager/TmuxBridge protocol traffic, libtmux command/response |

**Boundary rule for `terminals` vs `tmux`:** `terminals` is feature-level
intent ("user asked to create a terminal in worktree X"). `tmux` is the
protocol/transport layer ("sent `new-window` command, got pane id %42 back").
A single user action will usually produce one `terminals` line and several
`tmux` lines. When in doubt: if removing tmux from the architecture would
delete the line, it's `tmux`; if it would survive a transport swap, it's
`terminals`.
| `notifications`     | MacNotificationManager, daemon→app notification fanout           |
| `notes`             | Note CRUD, persistence                                           |
| `pr-status`         | PR polling, gh shellouts                                         |
| `conductor`         | ConductorManager, suggestion bar                                 |
| `ssh-agent`         | SSHAgentResolver and consumers                                   |
| `lifecycle`         | Suspend/resume, app launch, daemon handshake                     |
| `ipc`               | DaemonClient ↔ daemon NIO transport                              |
| `database`          | GRDB migrations, queries, state.db access                        |
| `markdown`          | Markdown rendering, link handling, viewer                        |

A category should be small enough that streaming it gives a coherent narrative
of one feature, large enough that you don't need to remember which of seven
sibling categories to enable.

### Streaming recipes

These should live in this doc and in `CLAUDE.md` so they're discoverable:

```bash
# Default-level events from both processes
log stream --predicate 'subsystem BEGINSWITH "com.tbd"'

# Everything (including .debug) from one feature area, both processes
log stream --level debug \
  --predicate 'subsystem BEGINSWITH "com.tbd" AND category == "markdown"'

# Just the daemon, info and above
log stream --level info \
  --predicate 'subsystem == "com.tbd.daemon"'

# ⚠️ READ FIRST before using `log show --last` for debug events:
# .debug is NOT persisted by default, so `log show` will return zero debug
# rows even if your code is logging them. To make replay work, raise debug
# persistence ONCE PER SUBSYSTEM (TBD has two: app + daemon):
sudo log config --subsystem com.tbd.app    --mode "level:debug,persist:debug"
sudo log config --subsystem com.tbd.daemon --mode "level:debug,persist:debug"
# Revert (also one per subsystem):
sudo log config --subsystem com.tbd.app    --reset
sudo log config --subsystem com.tbd.daemon --reset

# Replay the last 5 minutes of logs from one area (great for "I just
# reproduced the bug — show me what happened"). Requires the persist
# config above if you want .debug rows back.
log show --last 5m --level debug \
  --predicate 'subsystem BEGINSWITH "com.tbd" AND category == "terminals"'
```

The `log show --last` form is the killer feature: you don't have to start
streaming *before* the bug. Reproduce, then ask the system for the recent past.

## Activating verbose logging without rebuilding

`log stream --level debug` already does this for us — no env var, no defaults
key, no debug build. The detail is *always in the binary*, gated only by the
subscriber's level filter. That's the whole point of using os.Logger correctly:
the activation mechanism is the OS, not the app.

We do **not** want a `TBD_DEBUG=1` env var or a developer-mode toggle. Both
recreate the problem we're trying to solve (a separate code path that rots
because nobody uses it) and both lose os_log's structured-data and Console.app
integration.

### Ring buffer / on-demand dump

For situations where streaming isn't practical (intermittent bug, user reports
it after the fact, the app crashed and we want a tail), `log show --last 10m
--predicate ...` already gives us a system-managed ring buffer for free. We
should add one CLI convenience: `tbd diagnostics dump [--category X] [--last
10m]` that wraps `log show` with the right predicate and writes to a file.
That's a small follow-up, not a prerequisite.

Beyond the `log show` shellout, the proper Swift API is `OSLogStore(scope:
.currentProcessIdentifier)`, which lets the app tail its own logs in-process —
useful for an in-app log viewer, a crash-time tail attached to bug reports, or
embedding recent logs in `tbd notify` payloads. Treat this as the v2 of
`tbd diagnostics dump`, not v1.

### Signposts (Instruments)

For genuine performance work — "why does worktree creation take 4 seconds",
"why is the terminal panel janky" — use `OSSignposter` rather than logs. Add
signposts at the same seams as the categories above (around the top-level
operation in each manager). Then any developer can open Instruments, pick the
os_signpost track, and see a flame graph without anyone having to
hand-instrument timing. This is additive; don't block on it.

Prefer the closure form `signposter.withIntervalSignpost("worktree.create") {
... }` (macOS 12+) over manual `beginInterval` / `endInterval` — it auto-
balances on early return and throw, which manual pairs do not. Dangling
intervals make Instruments choke. Put payload data on the begin call, not the
end call.

## Migration path

This is intentionally a slow, no-big-bang migration. The proposal is the
guardrails; the cleanup happens opportunistically.

1. **Stop the bleeding (immediately).** Add a `CLAUDE.md` rule that `print(`
   is forbidden in `Sources/` and new code uses `Logger` only. We rely on
   CLAUDE.md rather than a CI grep gate because all authoring in this repo
   flows through Claude — the rule is enforced at write time, not merge time.
   If that ever stops being true, a two-line `grep` step in CI is the
   belt-and-suspenders fallback.
2. **Collapse categories at the file you're already touching.** When you edit a
   file with `category: "AppState+Worktrees"`, change it to `category:
   "worktrees"` as part of the same commit. No standalone rename PR. Within a
   release or two the taxonomy converges.
3. **Re-level existing calls as you read them.** Most current `logger.log(...)`
   and `logger.info(...)` calls should be `.debug`. A call is `.notice` only if
   you'd be happy seeing it in Console.app on a stranger's machine.
4. **Convert surviving `print()` calls** (25 occurrences across ~22 files at
   time of writing) to `.debug` on the appropriate category. This is the
   biggest single payoff and can be done in one mechanical pass.
5. **Document the streaming recipes** in `CLAUDE.md` next to the existing
   "Quick Reference" section, so the next investigator's first instinct is
   `log stream` instead of `print()`.

No file needs to be touched purely for this migration. Every change rides
along with work that's happening anyway.

## Worked example: the cmd+click markdown link bug

A parallel investigation is chasing a bug where cmd+clicking a link in the
markdown viewer doesn't open the link. Here's how the two worlds compare.

### Today

1. Reproduce. Nothing in the logs.
2. Open the markdown viewer source. Add `print("link clicked: \(url)")` at the
   suspected handler.
3. Rebuild, relaunch, reproduce. See nothing — the handler isn't even being
   called.
4. Add three more `print()`s further up the event chain. Rebuild, relaunch,
   reproduce. Find the gesture is being swallowed by an enclosing view.
5. Fix the bug. Delete all four `print()`s. Commit.
6. Two weeks later, a different cmd+click bug appears. Go to step 1.

Each rebuild/relaunch cycle is ~30s of dead time, and the diagnostic
scaffolding is destroyed the moment it stops being useful.

### With this strategy

Every link-click code path already has lines like:

```swift
private let logger = Logger(subsystem: "com.tbd.app", category: "markdown")

logger.debug("link tap received url=\(url, privacy: .public) modifiers=\(modifiers.rawValue)")
logger.debug("forwarding to NSWorkspace.open")
```

…that were added the *first* time someone debugged this area and never
deleted. The investigation becomes:

```bash
log stream --level debug \
  --predicate 'subsystem == "com.tbd.app" AND category == "markdown"'
```

Reproduce the bug. One of three things happens:

- **No log line at all** → the gesture never reached the handler. Look upward
  in the view hierarchy. (This is what the current bug actually is.)
- **Log line but no `forwarding to NSWorkspace.open`** → the handler ran but
  bailed early. Check the conditional.
- **Both lines but the link doesn't open** → it's an `NSWorkspace` /
  URL-scheme issue, not a TBD issue.

No rebuild. No code edit. No cleanup commit. And the next person who
investigates anything in the markdown viewer gets the same head start.

That's the whole pitch: the diagnostic work you do today should be a permanent
asset, not a disposable scaffold.
