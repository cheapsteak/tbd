# Resolving `projects/` collisions so every profile links

**Date:** 2026-10-28
**Status:** Design (refines the collision rule in
`2026-05-20-file-level-collisions-design.md` and
`2026-05-20-recursive-projects-merge-design.md`)

## Problem

Each TBD profile's isolated config dir mirrors the host's `~/.claude/projects`
by symlink. Until that link exists, a session spawned on the profile writes its
transcript and its auto-memory notes into a copy only that account can see.
Another profile cannot `--resume` the session, and memory notes drift apart
from one account to the next.

The migration that creates the link moves the profile's real `projects/` into
the host store first. It aborts as soon as any file exists under the same path
on both sides. That rule assumed such collisions were near-impossible, since
session ids are UUIDs. Field measurement says otherwise. When a session moves
between profiles, its transcript exists in both stores. When a tool copies
memory notes across accounts, the notes do too. On one developer machine, two
of thirteen profiles had never linked. Their colliding paths were:

- about 140 byte-identical files;
- 10 transcripts whose two copies differ, each time with the shorter copy a
  strict byte-prefix of the longer one (one side kept growing after the session
  moved);
- 4 auto-memory notes whose two copies differ;
- 9 `memory` directory symlinks that a separate tool had placed in the profile,
  each pointing back at the host's own `memory` directory for the same project.

The `keybindings.json` file has a similar gap. It is a host customization like
`settings.json`, but it is not a mirror slot, so no profile session sees it.

## Design

Collisions are resolved file by file. The migration still has two passes, and
its atomicity is unchanged. Pass 1 only reads and builds a plan. If any part of
the plan cannot be resolved, nothing changes and no link is made. Pass 2
carries out the resolutions, moves everything else as before, and creates the
link.

Each path that exists in the profile tree is classified in this order:

- **Profile-side symlink** – never followed. A link that resolves to its own
  host counterpart is an alias of the host entry, so only the link is removed.
  This holds whether or not the host entry exists, so a link is never moved
  onto its own target. Following the link instead would compare each host file
  with itself as an "identical duplicate", then delete the host file through
  the link. A link that points anywhere else is moved as-is when the host path
  is free, and is a conflict when it is not.
- **Host path free** – nothing to resolve; the entry moves as before. A
  dangling host symlink is not a free path: it counts as a conflict.
- **File on one side, directory on the other** – conflict.
- **Directories on both sides** – recurse.
- **Byte-identical files** – the profile copy is removed. The host already
  holds the same bytes.
- **Transcripts (`.jsonl`) of different lengths** – the longer copy ends up at
  the host path. The other is kept beside it as `<name>.backup`, or
  `<name>.backup-2` and so on when that name is taken. Claude Code only appends
  to a transcript, so the longer copy is the more complete one, and no bytes are
  lost either way. The suffix does not end in `.jsonl`, so Claude Code's resume
  list and TBD's own transcript scanners skip it.
- **Any other pair of differing files** – conflict. This covers memory notes,
  settings, and two transcripts of equal length that differ.

If there are any conflicts, the migration logs a warning that names every
conflicting path and makes no changes. Whoever owns those files resolves them,
and the next spawn on that profile retries the migration. The only removals are
byte-identical profile duplicates and alias links. No file that differs from
its counterpart is ever deleted.

A `.backup` file is kept on purpose, and no sweep reclaims it. It holds the
only copy of bytes that differ from the transcript beside it, so removing it is
the user's call. Backups cannot pile up: the migration runs only while a
profile's `projects` slot is a real directory, and once the slot links, the
next spawn finds the link and returns before planning anything. A profile
therefore gains at most one backup for each transcript pair that differed at
the moment it linked.

`keybindings.json` joins the mirror slots and follows the file-slot rules that
`settings.json` and `CLAUDE.md` already use. When the host has no such file,
the slot is skipped. When the profile holds a real file, it moves to a
`.profile-local` sidecar before the link is made.

## Rejected alternatives

- **Newest modification time wins a transcript** – copies and moves reset
  modification times, so they say little about which copy is more complete.
  Length matches the append-only way transcripts are written.
- **Merging differing memory notes** – notes are prose that a person or the
  tool that owns them wrote. A mechanical merge would guess. Naming the conflict
  leaves the choice with that owner.
- **Linking the resolvable part and leaving the rest** – the slot is one
  symlink. It cannot be half-linked, and a partial move would leave two stores
  that each hold part of a project.
- **A default-off flag** – this finishes a migration that already runs on
  every spawn, and it adds no new autonomous behavior. Its only removals are
  byte-identical duplicates and alias links, and every differing byte survives
  under a name of its own.

## Assumptions

- Claude Code never rewrites a transcript to be shorter. If that ever stops
  being true, "keep the longer copy" can choose the stale copy. The other copy
  is still kept as a backup.
- The migration does not check for a live session on the profile. A session
  that is still writing a profile-side transcript whose host copy is longer
  will write its later turns through the new link into the host copy. This is
  the same exposure the migration already had for files that moved without a
  collision.

## Acceptance criteria

- **AC1** – An identical file on both sides: the profile copy is gone, the host
  bytes are unchanged, and the profile's `projects` is a link to the host.
- **AC2** – Differing transcripts with the profile copy longer: the host path
  holds the profile bytes, and the old host bytes are at `<name>.backup`.
- **AC3** – Differing transcripts with the host copy longer: the host path is
  unchanged, and the profile bytes are at `<name>.backup`.
- **AC4** – When `<name>.backup` is taken, `<name>.backup-2` is used and the
  existing backup is untouched.
- **AC5** – A differing non-transcript file, or two differing transcripts of
  equal length, aborts the migration. Nothing moves, including resolvable
  collisions elsewhere in the same profile, and no link is made.
- **AC6** – A profile `memory` symlink to the host's own `memory` directory is
  removed, and the host notes survive byte for byte. When the host directory
  does not exist, the link is still only removed, never moved onto its target.
- **AC7** – A profile symlink that points elsewhere, where the host path is
  occupied, aborts the migration.
- **AC8** – `keybindings.json` is linked when the host has it and skipped when
  it does not.
