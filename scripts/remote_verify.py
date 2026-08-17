"""Remote verification valve: verify this commit on GitHub instead of holding
the machine-global build slot.

THE TICKET POOL IS LOCAL ON PURPOSE. Every contender runs on this one laptop,
so a local lock file arbitrates GitHub's capacity authoritatively — there is no
distributed consensus problem here. GitHub caps five concurrent macOS jobs per
account and `test.yml` spends two per run, so roughly two runs fit; without this
bound every queued lane would dispatch at once into a queue TBD cannot observe,
prioritise, or abandon.

The ticket is an flock rather than a hand-rolled occupancy file: the kernel
releases it when this process exits by any means, so a ticket cannot outlive its
run and needs no sweep. It is held in python rather than the shell because macOS
ships no `flock(1)` and `/bin/bash` here is 3.2, which cannot allocate the file
descriptor such a lock would need.
"""

from __future__ import annotations

from collections.abc import Iterator, Mapping
import contextlib
import fcntl
import os
from pathlib import Path


SLOTS_SETTING = "TBD_REMOTE_VERIFY_SLOTS"
DEFAULT_SLOTS = 2


class NoTicket(Exception):
    """Every dispatch slot is taken, so this lane must keep waiting locally."""


def configured_slots(environ: Mapping[str, str] | None = None) -> int:
    """How many remote runs may be in flight at once.

    Unset or empty means the shipped default, so an untouched environment gets
    the sizing the spec measured. An unreadable value is refused by name rather
    than quietly falling back: silently sizing the pool differently from what
    somebody asked for is how a stampede gets shipped.
    """
    environ = os.environ if environ is None else environ
    raw = environ.get(SLOTS_SETTING, "")
    if not raw:
        return DEFAULT_SLOTS
    try:
        slots = int(raw)
    except ValueError:
        raise ValueError(f"{SLOTS_SETTING} must be a whole number, not {raw!r}") from None
    if slots < 0:
        raise ValueError(f"{SLOTS_SETTING} must not be negative, but is {slots}")
    return slots


@contextlib.contextmanager
def take_dispatch_ticket(runtime_dir: Path, slots: int) -> Iterator[int]:
    """Hold one dispatch ticket for the duration of the block.

    Yields the index of the ticket taken, and raises `NoTicket` at once when
    every slot is held — this never queues, because a lane that cannot go
    remote has a local queue to return to.
    """
    runtime_dir.mkdir(parents=True, exist_ok=True)
    for index in range(1, int(slots) + 1):
        handle = (runtime_dir / f"remote-verify-{index}.lock").open("a+", encoding="utf-8")
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            handle.close()
            continue
        try:
            yield index
        finally:
            handle.close()  # closing releases the flock
        return
    raise NoTicket
