# Start admission

Before TBD starts or wakes a Claude Code or Codex session that a program asked for, it can run a
command you wrote. The command says yes or no. TBD holds a "no" and says why. Starts you make in
the TBD app are never held. Design: [`specs/2026-10-21-agent-start-admission-design.md`](specs/2026-10-21-agent-start-admission-design.md).

Off by default:

```
tbd config set start-admission on
tbd config get          # shows start-admission: on
```

## The command

`~/tbd/hooks/start-admission` (under `$TBD_HOME` when set). One file per machine. If the flag is off
or the file is absent, every start proceeds. The file must be executable.

TBD runs it with a 10 second limit, the daemon's own environment, and:

- **`TBD_START_KIND`** – `create` or `wake`.
- **`TBD_AGENT`** – `claude` or `codex`.
- **`TBD_ACTOR`** – who asked: `session`, `anonymous`, `supervisor`, or a kind a newer client
  declared.
- **`TBD_WORKTREE_ID`** – the worktree the start belongs to.
- **`TBD_TERMINAL_ID`** – the terminal, when the start names one.

Exit 0 admits the start. Any other exit holds it, and the reason is the first non-empty line of
stdout (cut to 200 characters), or `start-admission exited N`. A timeout, a signal or a file that
cannot run also holds, with a reason naming it: a gate that cannot decide holds.

```sh
#!/bin/sh
# Hold new agent starts while the machine is under heavy load.
load=$(sysctl -n vm.loadavg | awk '{print int($2)}')
if [ "$load" -ge 40 ]; then
  echo "load average is $load"
  exit 1
fi
```

## What a hold does

- The `tbd` command prints `held: <reason>` on stderr and exits 75 (`EX_TEMPFAIL`). Ask again later;
  TBD keeps no queue.
- The actuation record gets a `refused` outcome with reason `held`.
- A held create writes no terminal, worktree, branch or window.
- A held wake leaves the tab parked and notes the reason and time on it. The parked pane then reads
  "Automatic wake held at 9:12: <reason>". The next successful wake clears the note.

Not checked: shell and dev-server tabs, a wake of a tab that is not parked, `terminal.recreateWindow`,
`terminal.migrateTransport`, remote sessions, and TBD's own daemon rails. The actor is self-declared,
so this is a resource policy and not a security boundary.
