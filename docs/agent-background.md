# Agent background priority

`tbd agents background` moves every agent process tree TBD owns to macOS background priority, and
back, on a lease that ends by itself. A terminal at background priority still takes input and shows
output; it computes more slowly and its disk I/O is throttled. Design:
[`specs/2026-10-21-agent-start-admission-design.md`](specs/2026-10-21-agent-start-admission-design.md).

Off by default:

```
tbd config set agent-background on
```

## Commands

```
tbd agents background on --for 10m    # 90s, 10m or 1h; at most 2h. Again = renew.
tbd agents background off             # restore now
tbd agents background status [--json] # active, when it ends, how many processes are lowered
```

`on` fails while the flag is off. `off` and `status` always work, so you can restore after turning
the flag off.

## What it touches

For each agent (Claude Code or Codex) tab that is not parked, TBD finds the root of the tab's process
tree and lowers that process and everything below it. It never lowers the holder or the tmux server.
It never lowers the TBD daemon either: if the daemon was started from inside an agent tab, that tab's
walk leaves out the daemon, everything below it and every process it runs under.
A process already in the background is left alone, and TBD restores only what it lowered itself.

While the lease is on, the daemon repeats the walk every 60 seconds, so agents started or woken
during the lease are lowered too. When the lease ends (or on `off`) TBD restores each recorded
process that is still the same process. A process an agent started during the lease inherited
background priority and keeps it until it exits.

The lease and the record of lowered processes live in `~/tbd/agent-background.json` (under
`$TBD_HOME` when set). At daemon start an expired lease is restored and the file deleted; a live one
is kept and swept. If the daemon never returns, lowered processes stay lowered until they exit.
