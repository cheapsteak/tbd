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

That last constraint decides the whole split with `scripts/remote-verify.sh`.
The shell front-end answers "should we, and against which ref" — preconditions
and ref choice — and then `exec`s this module, which holds one ticket for the
entire remote round trip: push, dispatch, correlate, wait, render. A subshell
that returned early would drop the ticket while its run was still burning
GitHub's two-run allowance.

PUSHING HAPPENS HERE, AFTER THE TICKET, and not in the front-end. A ref pushed
before a ticket was granted is a durable resource created for a run that never
happened; taking the ticket first means the only refs that exist are ones a
dispatch was authorised for.

THE VERDICT IS READ FROM STRUCTURED RESULTS, NEVER FROM THE JOB LOG. One failed
run of `test.yml` produces 5.3 MB across 32,228 lines in which parallel passes
interleave and compiler diagnostics print source context that reads exactly like
test output; two extraction attempts over a real failed log both named the wrong
failure. So the workflow uploads xUnit XML and this module parses it.
"""

from __future__ import annotations

import argparse
from collections.abc import Callable, Iterator, Mapping, Sequence
import contextlib
from dataclasses import dataclass
import fcntl
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


SLOTS_SETTING = "TBD_REMOTE_VERIFY_SLOTS"
DEFAULT_SLOTS = 2

WORKFLOW_FILE = "test.yml"
RESULTS_ARTIFACT = "xunit-results"
DEFAULT_REMOTE = "origin"

# Exit codes, and the contract every caller reads.  78 is the one that matters:
# it means "no verdict, go back to the local queue", which is what keeps the
# valve an optimisation rather than a gate.
EXIT_PASSED = 0
EXIT_FAILED = 1
EXIT_REFUSED = 78

# Poll cadence and bounds.  Every one is overridable so the harness can drive
# the same code paths without waiting on a wall clock.
POLL_SETTING = "TBD_REMOTE_VERIFY_POLL_SECONDS"
DEFAULT_POLL_SECONDS = 10.0
CORRELATE_SETTING = "TBD_REMOTE_VERIFY_CORRELATE_SECONDS"
DEFAULT_CORRELATE_SECONDS = 180.0
RUN_SETTING = "TBD_REMOTE_VERIFY_RUN_SECONDS"
# The observed worst-case remote run is 32 minutes; 45 leaves room without
# letting a wedged run hold a dispatch ticket indefinitely.
DEFAULT_RUN_SECONDS = 2700.0

# A red run naming three thousand tests is the 5.3 MB problem again in a
# smaller font, so the render is bounded and says how much it withheld.
MAX_RENDERED_FAILURES = 50


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


class Refused(Exception):
    """No verdict could be had, so this lane must go back to the local queue.

    Every refusal carries the condition that caused it, because a silent
    fallback reintroduces the long stall at the moment it is least visible.
    """


def _positive_seconds(environ: Mapping[str, str], name: str, default: float) -> float:
    """A duration setting, refused by name rather than quietly defaulted."""
    raw = environ.get(name, "")
    if not raw:
        return default
    try:
        seconds = float(raw)
    except ValueError:
        raise ValueError(f"{name} must be a number of seconds, not {raw!r}") from None
    if seconds < 0:
        raise ValueError(f"{name} must not be negative, but is {seconds}")
    return seconds


# --- running commands --------------------------------------------------------


@dataclass(frozen=True)
class Completed:
    """What a `git` or `gh` invocation returned."""

    status: int
    stdout: str
    stderr: str


RunCommand = Callable[[Sequence[str]], Completed]


def system_runner(directory: Path) -> RunCommand:
    """Run commands inside the repository, capturing both streams.

    `gh` resolves which repository it is talking to from the working directory,
    so binding that here rather than at each call site keeps every subprocess on
    the same repo the preconditions were checked against.
    """

    def run(argv: Sequence[str]) -> Completed:
        finished = subprocess.run(  # noqa: S603 - argv is built here, never a shell string
            list(argv),
            cwd=str(directory),
            capture_output=True,
            text=True,
            check=False,
        )
        return Completed(finished.returncode, finished.stdout, finished.stderr)

    return run


def _report(message: str) -> None:
    """Progress is diagnostics: stderr, so stdout carries only the verdict."""
    print(message, file=sys.stderr, flush=True)


# --- correlating a dispatch to its run ---------------------------------------


def select_run(runs: Sequence[Mapping[str, object]], sha: str) -> dict[str, object] | None:
    """The newest dispatched run for `sha`, or None.

    `gh workflow run` returns no run id, so the run has to be found by what it
    is running.  Two guards earn their place:

    - **`event == "workflow_dispatch"`.** The same commit may also have a
      `pull_request` run; watching that one would report a verdict the valve
      never asked for and would race its own dispatch.
    - **`databaseId` must be a real integer, and `bool` is not one.** A JSON
      `true` satisfies `isinstance(x, int)` in python and would coerce to run
      id 1 — a real, unrelated run whose verdict would be reported as this
      lane's.

    A completed older dispatch of the same sha is a legitimate answer: the
    verdict is a statement about the commit, and two lanes on one commit
    deliberately share it.
    """
    for run in runs:
        if run.get("headSha") != sha:
            continue
        if run.get("event") != "workflow_dispatch":
            continue
        identifier = run.get("databaseId")
        if isinstance(identifier, bool) or not isinstance(identifier, int):
            continue
        return dict(run)
    return None


def _decode_json(result: Completed, what: str) -> object:
    if result.status != 0:
        raise Refused(f"{what} failed ({result.status}): {result.stderr.strip() or 'no output'}")
    try:
        return json.loads(result.stdout or "null")
    except ValueError:
        raise Refused(f"{what} returned output that is not JSON") from None


def list_runs(run_command: RunCommand, *, limit: int = 40) -> list[Mapping[str, object]]:
    """Recent runs of the verification workflow, newest first."""
    result = run_command(
        [
            "gh", "run", "list",
            "--workflow", WORKFLOW_FILE,
            "--limit", str(limit),
            "--json", "databaseId,headSha,status,conclusion,event,url",
        ]
    )
    parsed = _decode_json(result, "gh run list")
    if not isinstance(parsed, list):
        raise Refused("gh run list did not return a list of runs")
    return [entry for entry in parsed if isinstance(entry, Mapping)]


def await_dispatched_run(
    run_command: RunCommand,
    sha: str,
    *,
    timeout: float,
    poll: float,
    sleep: Callable[[float], None] = time.sleep,
    monotonic: Callable[[], float] = time.monotonic,
    report: Callable[[str], None] = _report,
) -> dict[str, object]:
    """Wait for the dispatched run to register, bounded.

    GitHub creates the run asynchronously, so it is normal for the first look
    to find nothing.  The bound exists so a dispatch that never registers ends
    as a named refusal rather than a process that waits forever holding a
    ticket.
    """
    deadline = monotonic() + timeout
    while True:
        run = select_run(list_runs(run_command), sha)
        if run is not None:
            return run
        if monotonic() >= deadline:
            raise Refused(
                f"no dispatched run appeared for {sha} within {timeout:g}s"
            )
        report(f"remote-verify: waiting for the dispatched run for {sha} to register")
        sleep(poll)


def await_completion(
    run_command: RunCommand,
    run_id: str,
    *,
    timeout: float,
    poll: float,
    sleep: Callable[[float], None] = time.sleep,
    monotonic: Callable[[], float] = time.monotonic,
    report: Callable[[str], None] = _report,
) -> dict[str, object]:
    """Wait for a run to reach `completed`, bounded."""
    deadline = monotonic() + timeout
    while True:
        result = run_command(
            ["gh", "run", "view", run_id, "--json", "status,conclusion,url,jobs"]
        )
        parsed = _decode_json(result, f"gh run view {run_id}")
        if not isinstance(parsed, Mapping):
            raise Refused(f"gh run view {run_id} did not return a run")
        if parsed.get("status") == "completed":
            return dict(parsed)
        if monotonic() >= deadline:
            raise Refused(
                f"run {run_id} was still {parsed.get('status')} after {timeout:g}s"
            )
        report(f"remote-verify: run {run_id} is {parsed.get('status')}")
        sleep(poll)


def verdict_for(conclusion: object) -> int | None:
    """`EXIT_PASSED`, `EXIT_FAILED`, or None when the run said neither.

    Only an unambiguous conclusion is a verdict.  A cancelled, skipped or
    timed-out run says nothing about the code, and reporting it as a failure
    would make the valve worse than no valve — it would invent red.  None sends
    the lane back to the local queue, where it gets a real answer.
    """
    if conclusion == "success":
        return EXIT_PASSED
    if conclusion == "failure":
        return EXIT_FAILED
    return None


def failed_job_names(run: Mapping[str, object]) -> list[str]:
    """Which jobs of a red run were red, for the one-line attribution."""
    jobs = run.get("jobs")
    if not isinstance(jobs, list):
        return []
    names = []
    for job in jobs:
        if not isinstance(job, Mapping):
            continue
        if job.get("conclusion") in ("failure", "timed_out", "cancelled"):
            name = job.get("name")
            if isinstance(name, str):
                names.append(name)
    return names


# --- rendering xUnit results -------------------------------------------------


@dataclass(frozen=True)
class Failure:
    """One failing test, in the shape a local run would have printed it."""

    classname: str
    name: str
    message: str

    def line(self) -> str:
        return f"{self.classname}.{self.name}: {self.message}"


def result_files(directory: Path) -> list[Path]:
    """Every xUnit file in a downloaded artifact, in a stable order.

    Globbed rather than named. `test.yml` writes one file per pass — three
    today — and SwiftPM may split a pass again between its XCTest and Swift
    Testing writers, so the count is a property of the run, not a constant.  A
    run that died early simply publishes fewer, which is not an error here.
    """
    return sorted(path for path in directory.rglob("*.xml") if path.is_file())


class MalformedResults(Exception):
    """A result file that cannot be believed, rather than one with no failures.

    The two are worlds apart here: "no failures in this file" is a claim about
    the code, and a truncated or empty file must never be allowed to make it.
    """


class _ResultParser(HTMLParser):
    """The xUnit reader, deliberately not `xml.etree`.

    ElementTree needs `pyexpat`, a C extension that some perfectly ordinary
    python installations cannot load: a package-manager build whose `pyexpat`
    is linked against an older system `libexpat` raises ImportError on every
    parse, which is exactly what the `python3` first on PATH did while this was
    written. A renderer that works in CI and dies on the laptop it exists to
    unblock is no renderer, and `html.parser` is pure python and always there.
    The dialect these files use needs nothing more: flat elements, attribute
    values, no namespaces, no DTD.
    """

    def __init__(self, fallback_classname: str):
        super().__init__(convert_charrefs=True)
        self.fallback_classname = fallback_classname
        self.failures: list[Failure] = []
        self.root_opened = False
        self.root_closed = False
        self._seen: set[Failure] = set()
        self._case: dict[str, str] = {}
        self._message: str | None = None
        self._text: list[str] = []

    def handle_starttag(self, tag, attrs):
        values = {name: value or "" for name, value in attrs}
        if tag in ("testsuites", "testsuite"):
            self.root_opened = True
        elif tag == "testcase":
            self._case = values
        elif tag in ("failure", "error"):
            self._message = values.get("message", "")
            self._text = []

    def handle_data(self, data):
        if self._message is not None:
            self._text.append(data)

    def handle_endtag(self, tag):
        if tag in ("failure", "error"):
            if self._message is None:
                return
            self._record(self._message or "".join(self._text).strip())
            self._message = None
            self._text = []
        elif tag == "testcase":
            self._case = {}
        elif tag in ("testsuites", "testsuite"):
            self.root_closed = True

    def _record(self, message: str) -> None:
        failure = Failure(
            classname=self._case.get("classname") or self.fallback_classname,
            name=self._case.get("name") or "(unnamed test)",
            message=message or "(no message)",
        )
        if failure in self._seen:
            return
        self._seen.add(failure)
        self.failures.append(failure)


def failures_in(path: Path) -> list[Failure]:
    """Failing tests in one xUnit file, in document order, without duplicates.

    Both writers this repo meets are handled: SwiftPM's XCTest generator emits
    `<testcase classname=… name=…><failure message=…>` unindented, and Swift
    Testing's own generator emits the same elements indented with `<skipped />`
    for a disabled test. A passing case carries no failure child and is ignored.

    Raises `MalformedResults` for a file that opened no result element or never
    closed one — an empty or half-written file, which a run that was killed
    mid-pass leaves behind.
    """
    parser = _ResultParser(fallback_classname=path.stem)
    parser.feed(path.read_text(encoding="utf-8", errors="replace"))
    parser.close()
    if not parser.root_opened:
        raise MalformedResults("no test results in the file")
    if not parser.root_closed:
        raise MalformedResults("truncated: the result element never closed")
    return parser.failures


@dataclass(frozen=True)
class Report:
    """What the result files said, and how to print it."""

    total: int
    unreadable: tuple[str, ...]
    lines: tuple[str, ...]


def render_results(paths: Sequence[Path], *, limit: int = MAX_RENDERED_FAILURES) -> Report:
    """The failing tests across every result file, counted and printable.

    Renders what it has.  A file that is missing, empty or half-written is
    reported by name and the rest are still rendered — a run that died early
    publishes exactly that, and losing the failures it did record would put us
    back to reading the log.
    """
    sections: list[tuple[Path, list[Failure]]] = []
    unreadable: list[tuple[Path, str]] = []
    total = 0
    for path in paths:
        try:
            failures = failures_in(path)
        except (MalformedResults, OSError) as error:
            unreadable.append((path, str(error)))
            continue
        total += len(failures)
        if failures:
            sections.append((path, failures))

    lines: list[str] = []
    if total:
        plural = "" if total == 1 else "s"
        lines.append(
            f"remote-verify: {total} failing test{plural} "
            f"in {len(paths)} result file(s)"
        )
    elif not unreadable:
        lines.append(
            "remote-verify: the remote run failed but published no failing tests — "
            "the failure is outside the test passes (build, lint, or a run that "
            "died before writing results)"
        )
    else:
        lines.append("remote-verify: the remote run failed and its results are unreadable")

    shown = 0
    for path, failures in sections:
        lines.append(f"  {path.name}")
        for failure in failures:
            if shown >= limit:
                break
            lines.append(f"    {failure.line()}")
            shown += 1
        if shown >= limit:
            break
    if total > shown:
        lines.append(f"  … and {total - shown} more failing tests, withheld to stay readable")
    for path, error in unreadable:
        lines.append(f"  {path.name} — unreadable: {error}")
    return Report(
        total=total,
        unreadable=tuple(path.name for path, _ in unreadable),
        lines=tuple(lines),
    )


def download_results(
    run_command: RunCommand, run_id: str, destination: Path
) -> tuple[list[Path], str | None]:
    """Unpack the run's xUnit artifact, or say why it could not be had.

    A missing artifact is not a refusal: the run failed, and that verdict
    stands whether or not it managed to publish results.
    """
    result = run_command(
        ["gh", "run", "download", run_id, "--name", RESULTS_ARTIFACT, "--dir", str(destination)]
    )
    if result.status != 0:
        detail = (result.stderr.strip() or result.stdout.strip() or "no output")
        return [], f"could not download the {RESULTS_ARTIFACT} artifact: {detail}"
    return result_files(destination), None


# --- the driver --------------------------------------------------------------


def push_ref(
    run_command: RunCommand, *, sha: str, ref: str, inert: bool, remote: str = DEFAULT_REMOTE
) -> None:
    """Put `sha` on `<remote>/<ref>`, or refuse by name.

    An inert `preflight/*` ref is a throwaway that any lane may move to any
    commit, so it is forced.  A real branch is not: a non-fast-forward push
    there would discard somebody's work to run a test, so it is allowed to fail
    and the lane goes back to the local queue.
    """
    argv = ["git", "push"]
    if inert:
        argv.append("--force")
    argv += [remote, f"{sha}:refs/heads/{ref}"]
    result = run_command(argv)
    if result.status != 0:
        raise Refused(
            f"could not push {sha} to {remote}/{ref}: "
            f"{result.stderr.strip() or result.stdout.strip() or 'no output'}"
        )


def dispatch_run(run_command: RunCommand, *, ref: str) -> None:
    """Ask GitHub for a run of the verification workflow on `ref`."""
    result = run_command(
        ["gh", "workflow", "run", WORKFLOW_FILE, "--ref", ref, "-f", "scope=full"]
    )
    if result.status != 0:
        raise Refused(
            f"could not dispatch {WORKFLOW_FILE} on {ref}: "
            f"{result.stderr.strip() or result.stdout.strip() or 'no output'}"
        )


def drive(
    *,
    ref: str,
    sha: str,
    inert: bool,
    runtime_dir: Path,
    slots: int,
    run_command: RunCommand,
    poll: float,
    correlate_timeout: float,
    run_timeout: float,
    sleep: Callable[[float], None] = time.sleep,
    monotonic: Callable[[], float] = time.monotonic,
    report: Callable[[str], None] = _report,
    write: Callable[[str], None] = print,
) -> int:
    """Hold a ticket for one whole remote verification, and return its verdict.

    Order is the point: ticket, then push, then dispatch.  Nothing durable and
    nothing metered happens until this lane is one of the two the pool allows.
    """
    try:
        with take_dispatch_ticket(runtime_dir, slots) as ticket:
            report(f"remote-verify: took dispatch ticket {ticket} of {slots}")
            push_ref(run_command, sha=sha, ref=ref, inert=inert)
            dispatch_run(run_command, ref=ref)
            report(f"remote-verify: dispatched {WORKFLOW_FILE} on {ref} at {sha}")
            found = await_dispatched_run(
                run_command, sha,
                timeout=correlate_timeout, poll=poll,
                sleep=sleep, monotonic=monotonic, report=report,
            )
            run_id = str(found["databaseId"])
            url = found.get("url")
            report(f"remote-verify: watching run {run_id} {url or ''}".rstrip())
            completed = await_completion(
                run_command, run_id,
                timeout=run_timeout, poll=poll,
                sleep=sleep, monotonic=monotonic, report=report,
            )
            url = completed.get("url") or url or ""
            verdict = verdict_for(completed.get("conclusion"))
            if verdict is None:
                raise Refused(
                    f"run {run_id} finished {completed.get('conclusion')}, "
                    f"which is no verdict {url}".rstrip()
                )
            if verdict == EXIT_PASSED:
                write(f"remote-verify: the remote run passed {url}".rstrip())
                return EXIT_PASSED
            _write_failure_report(
                run_command, run_id=run_id, url=str(url),
                completed=completed, write=write,
            )
            return EXIT_FAILED
    except NoTicket:
        report(
            f"remote-verify: all {slots} dispatch slots are in flight; "
            "staying in the local queue"
        )
        return EXIT_REFUSED
    except Refused as refusal:
        report(f"remote-verify: {refusal}")
        return EXIT_REFUSED


def _write_failure_report(
    run_command: RunCommand,
    *,
    run_id: str,
    url: str,
    completed: Mapping[str, object],
    write: Callable[[str], None],
) -> None:
    write(f"remote-verify: the remote run FAILED {url}".rstrip())
    jobs = failed_job_names(completed)
    if jobs:
        write(f"remote-verify: failing jobs: {', '.join(jobs)}")
    with tempfile.TemporaryDirectory(prefix="remote-verify-results.") as scratch:
        paths, problem = download_results(run_command, run_id, Path(scratch))
        if problem:
            write(f"remote-verify: {problem}")
            write("remote-verify: open the run above for the failure")
            return
        for line in render_results(paths).lines:
            write(line)


def _resolve_runtime_dir(environ: Mapping[str, str]) -> Path:
    """Where the ticket files live, following `TBD_HOME` like everything else."""
    home = environ.get("TBD_HOME") or str(Path.home() / "tbd")
    return Path(home).expanduser() / "runtime"


def main(argv: Sequence[str] | None = None, environ: Mapping[str, str] | None = None) -> int:
    environ = os.environ if environ is None else environ
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)

    driver = subcommands.add_parser("drive", help="run one remote verification")
    driver.add_argument("--repo-dir", required=True)
    driver.add_argument("--ref", required=True)
    driver.add_argument("--sha", required=True)
    driver.add_argument(
        "--inert",
        action="store_true",
        help="the ref is a throwaway preflight ref and may be force-pushed",
    )

    renderer = subcommands.add_parser(
        "render", help="render already-downloaded xUnit results"
    )
    renderer.add_argument("paths", nargs="+")

    options = parser.parse_args(list(argv) if argv is not None else None)

    if options.command == "render":
        paths: list[Path] = []
        for raw in options.paths:
            path = Path(raw)
            paths.extend(result_files(path) if path.is_dir() else [path])
        report = render_results(paths)
        for line in report.lines:
            print(line)
        return EXIT_FAILED if report.total or report.unreadable else EXIT_PASSED

    repo_dir = Path(options.repo_dir)
    try:
        slots = configured_slots(environ)
        poll = _positive_seconds(environ, POLL_SETTING, DEFAULT_POLL_SECONDS)
        correlate = _positive_seconds(environ, CORRELATE_SETTING, DEFAULT_CORRELATE_SECONDS)
        run_timeout = _positive_seconds(environ, RUN_SETTING, DEFAULT_RUN_SECONDS)
    except ValueError as error:
        _report(f"remote-verify: {error}")
        return EXIT_REFUSED
    return drive(
        ref=options.ref,
        sha=options.sha,
        inert=options.inert,
        runtime_dir=_resolve_runtime_dir(environ),
        slots=slots,
        run_command=system_runner(repo_dir),
        poll=poll,
        correlate_timeout=correlate,
        run_timeout=run_timeout,
    )


if __name__ == "__main__":
    raise SystemExit(main())
