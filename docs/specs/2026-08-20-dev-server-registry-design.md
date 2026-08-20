# Dev-server registry — design

TBD reads a machine-global registry of running development servers so it can
warn, before archiving a worktree, that archiving will strand something.

This document specifies the on-disk convention TBD reads, the liveness rule it
applies, and the boundaries it deliberately does not cross. It is written for a
reader implementing a *writer* — a launcher that starts dev servers and wants TBD
(and other consumers) to know about them.

## The problem

Archiving a worktree removes its checkout and closes the terminals its sessions
live in. A development server started inside that worktree does not necessarily
go with them. A supervisor started detached, or a process whose parent has
already exited, is reparented to `launchd` and keeps running — holding memory and
a port, with a working directory that no longer exists.

Nothing surfaces this. The row disappears from the sidebar and the process
carries on, discoverable only by reading `ps` by eye and recognising the argv.

Detection cannot close this. Inferring "is a dev server running for this
worktree" from the process table means matching argv patterns against a set of
server names, and the process that survives is usually the *supervisor* — a task
runner, a process manager, a package-manager wrapper — whose argv contains none
of them, while the recognisable server is its child and no longer a candidate
because its parent is gone. Whoever *starts* the process is the only party that
reliably knows what it is.

So the convention is declaration: the launcher writes a record.

## The convention

A record is a JSON file in:

```
${XDG_STATE_HOME:-~/.local/state}/dev-servers/
```

- **Machine-global, not inside the worktree.** A record placed in the worktree
  would be deleted with the worktree — destroying the only pointer to the process
  at the exact moment that process becomes an orphan. The registry's lifetime
  must be at least the process's, and the process's is unbounded.
- **No vendor segment in the path.** The directory is a surface several unrelated
  applications write to and read. A segment owned by one of them gives the next
  adopter a reason to create a second directory rather than join the first, and
  a convention with two directories is not a convention.
- **Not `$XDG_RUNTIME_DIR`,** which looks like the natural home and is wrong: it
  is cleared when the login session ends, and surviving the session is the entire
  problem.

### Record shape

The fields TBD reads:

- **`version`** — schema version, currently `1`. A version this build does not
  recognise reads *indeterminate*: its fields cannot be interpreted, so nothing
  may be concluded from them.
- **`label`** — a short name shown to the user, e.g. `dev`, `storybook`.
- **`root`** — absolute, symlink-resolved path of the worktree the server belongs
  to.
- **`command`** — display text describing what was started. **Never executed.**
- **`proc.pid`** and **`proc.start_epoch`** — the process identity: its pid, and
  its start time in whole Unix epoch seconds.

Records carry more than this — endpoints, an owning session, typed stop methods.
TBD ignores what it does not need; a reader must tolerate fields it does not
know, and a writer may add them.

Writers should create the file atomically (write a temporary file in the same
directory, then rename over the destination) so a reader never observes a partial
record.

## Liveness

**The record is not trusted to be current.** The common case is a writer that
died without cleaning up — that is the failure this whole feature exists for — so
a design that depends on the writer removing its own record, or refreshing a
heartbeat, reproduces the original problem inside the registry. A stale record is
the expected state, not an error.

Liveness is therefore asked of the kernel, using `(pid, start_epoch)` as the
identity:

- **running** — a process with that pid exists and its start time matches.
- **stale** — no process has that pid, *or* one does but started at a different
  time. Definitively gone.
- **indeterminate** — the record could not be read, or its version is not
  understood.

Two failure modes this specifically defeats:

- **Pid reuse.** A pid alone is recycled, so a record naming one would eventually
  describe a stranger — the flaw every `.pid` file scheme has. Pairing it with
  the start time makes the identity unforgeable by accident.
- **Unreaped exits.** A process that has exited but has not been waited for still
  appears in the process table and still reports its original start time, so the
  pair check alone would read a dead server as running forever. Whether one
  lingers is a property of the reaping parent, not of the OS, which is why it
  cannot be assumed away.

Comparison allows one second of slack, because implementations may differ on
truncating versus rounding when deriving whole seconds, and a cross-implementation
disagreement would otherwise report every live server as dead.

### Three states, not two

`stale` and `indeterminate` are different answers and only the first is evidence.
Collapsing them into "not running" would be harmless here — TBD only warns — but
the distinction is part of the convention rather than of this feature, because a
consumer that *acts* (stopping a process, reclaiming a resource) must never treat
"cannot tell" as "safe to act on".

## What TBD does with it

Before archiving a local worktree, TBD asks the registry which declared servers
in that worktree read `running`. If any do, it holds the archive and asks:

> `my-feature` still has storybook and dev running. Archiving removes the
> worktree but does not stop them, so they keep running with nothing pointing at
> them.

Confirming re-issues the archive; cancelling does nothing.

Only `running` prompts. A `stale` record describes nothing an archive could
strand, and an `indeterminate` one is not evidence either — prompting on those
teaches people to click through the prompt, which costs more than the warning
saves.

Remote rows are skipped without consulting the registry at all: their
`localPath` is a synthetic `remote://` URI rather than a filesystem path, and a
registry on this machine cannot speak for a worktree on another one.

## Boundaries

- **TBD never writes a record.** Writers own fields a reader would otherwise have
  to agree with them about, and a reader that writes becomes a second source of
  truth for a file it does not own.
- **TBD never stops anything through this.** Stopping belongs to whoever owns the
  process. This feature answers one question — *would archiving strand
  something?* — and leaves the rest alone.
- **No string from a record is ever executed.** `command` is display text.
  Records are written at runtime by any process, with no review, while TBD is
  long-running and trusted; executing a record-supplied string would let a
  process that cannot run arbitrary commands itself get one run on its behalf.
  A "path to an executable" field is the same hole with one level of indirection
  and is equally excluded. Where a consumer acts on a record at all, the
  vocabulary is a closed set of typed methods and the consumer supplies the
  executable.
- **Declaration is never complete, and the design says so.** Only a launcher that
  opts in declares anything; a server started by hand from a shell declares
  nothing. An empty result means "nothing declared", never "nothing running", and
  a consumer that reads it as a census has misread it.

## Rejected alternatives

- **A daemon or broker owning the registry.** The directory is the coordination
  point precisely so that adopting the convention costs a file write. A shared
  runtime dependency between unrelated applications is a reason not to adopt it.
- **Heartbeats or a TTL.** Both require the writer to keep behaving after the
  moment it stops behaving, which is the failure being modelled.
- **Health or readiness in the record.** Stale the instant it is written; ask the
  endpoint.
- **Detection instead of declaration.** Covered above: the surviving process is
  usually the one whose argv identifies nothing.
- **A per-worktree file.** Deleted with the worktree, at exactly the wrong moment.
