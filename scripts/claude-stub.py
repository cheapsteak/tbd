#!/usr/bin/env python3
"""Run the real `claude` CLI against a fake model API — zero tokens, offline.

A mock/stub of the Anthropic Messages API stands in for the model, so a real
`claude` session (interactive TUI or `-p` headless) runs end to end without
spending tokens and without a real API key: `ANTHROPIC_BASE_URL` points at a
loopback server started here, and every answer is scripted locally. Nothing
leaves the machine.

The fake server itself is `stub_server.py` under
`.github/workflows/claude-review-v2/tests/e2e/` (SSE streaming, canned turns,
content-keyed routing); this wrapper makes it usable outside the review gate.
See `docs/fake-model-api.md`.
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[1]
E2E_DIR = REPO_ROOT / ".github" / "workflows" / "claude-review-v2" / "tests" / "e2e"
sys.path.insert(0, str(E2E_DIR))

import harness  # noqa: E402
from stub_server import StubServer, ToolCall, Turn  # noqa: E402

# Env the caller's terminal owns. The e2e harness forces TERM=dumb, which is
# right for `-p` and wrong for the TUI, so these pass through when set.
PASSTHROUGH_ENV = ("TERM", "COLORTERM", "LANG", "LC_ALL")

# Passed through from the caller's own shell, so --print-env leaves it out —
# re-exporting a plugin-laden PATH buries the four lines that matter.
UNEXPORTED_ENV = ("PATH",)

# The one dialog the e2e harness has no reason to pre-accept and the
# interactive TUI raises anyway: the custom-API-key approval, keyed on a
# fingerprint of ANTHROPIC_API_KEY. Headless `-p` never asks. The key is read
# back out of the harness rather than restated here, so the value approved in
# the config cannot drift from the value the environment actually carries.
STUB_API_KEY = harness.sandbox_env(Path("/"), "http://127.0.0.1:0")["ANTHROPIC_API_KEY"]

# The interactive TUI opens every session with a second, concurrent request
# that asks the model to name the session; headless `-p` sends none. Left
# unrouted it eats a scripted turn (and racing with the real request, a
# nondeterministic one), so it gets its own content-keyed route: the CLI wraps
# the user's message in <session>…</session> there and nowhere else. Observed
# on claude 2.1.258.
TITLE_SENTINEL = "</session>"
TITLE_LABEL = "session title"
TITLE_TURN = Turn(text="Stub session")


def turn_from_dict(entry: dict[str, Any]) -> Turn:
    """One scripted assistant turn: `{"text": ..., "tool_calls": [...]}`."""
    calls = [
        ToolCall(call["name"], call.get("input", {}), id=call.get("id", "toolu_stub"))
        for call in entry.get("tool_calls", [])
    ]
    return Turn(text=entry.get("text", ""), tool_calls=calls)


def parse_turns_document(document: Any) -> tuple[list[Turn], dict[str, list[Turn]]]:
    """A turn file is either a plain list of turns or `{turns, role_turns}`."""
    if isinstance(document, list):
        return [turn_from_dict(entry) for entry in document], {}
    if not isinstance(document, dict):
        raise ValueError("turn file must be a JSON list or object")
    turns = [turn_from_dict(entry) for entry in document.get("turns", [])]
    role_turns = {
        sentinel: [turn_from_dict(entry) for entry in entries]
        for sentinel, entries in (document.get("role_turns") or {}).items()
    }
    return turns, role_turns


def build_routes(role_turns: dict[str, list[Turn]]) -> dict[str, list[Turn]]:
    """Content-keyed routes, with `</session>` reserved for the title request.

    The reservation is over the key alone: a turn file that names `</session>`
    does not replace the wrapper's title turn. It does not change how the
    server matches, which is still a substring test over the first message, so
    a user sentinel that also happens to appear inside the CLI's title prompt
    can still win that request on its own.
    """
    return {**role_turns, TITLE_SENTINEL: [TITLE_TURN]}


def long_answer(lines: int) -> str:
    """A numbered multi-line answer — the shape that scrolls in the TUI."""
    return "\n".join(
        f"{n}. stub answer line {n} of {lines} "
        "— filler so the answer is long enough to scroll."
        for n in range(1, lines + 1)
    )


def resolve_turns(args: argparse.Namespace) -> tuple[list[Turn], dict[str, list[Turn]]]:
    """The scripted conversation: --turns, --text, or the default long answer."""
    if args.turns:
        return parse_turns_document(json.loads(Path(args.turns).read_text(encoding="utf-8")))
    if args.text is not None:
        return [Turn(text=args.text)], {}
    return [Turn(text=long_answer(args.lines))], {}


def parse_env_assignments(assignments: list[str]) -> dict[str, str]:
    env: dict[str, str] = {}
    for item in assignments:
        key, separator, value = item.partition("=")
        if not separator or not key:
            raise ValueError(f"--env expects KEY=VALUE, got {item!r}")
        env[key] = value
    return env


def build_env(
    sandbox: Path,
    base_url: str,
    parent_env: dict[str, str],
    extra_env: dict[str, str],
) -> dict[str, str]:
    """Harness isolation, with the caller's terminal env and --env on top."""
    env = harness.sandbox_env(sandbox, base_url)
    for key in PASSTHROUGH_ENV:
        if parent_env.get(key):
            env[key] = parent_env[key]
    env.update(extra_env)
    return env


def export_lines(env: dict[str, str], extra_env: dict[str, str] | None = None) -> list[str]:
    """`export` lines for --print-env, minus the PATH the caller already has.

    Only the *inherited* PATH is dropped. An explicit `--env PATH=...` is the
    caller asking for a different one, and the run mode honours it, so
    --print-env has to hand it over too or the two modes disagree.
    """
    overridden = extra_env or {}
    return [
        f"export {key}={shlex.quote(value)}"
        for key, value in sorted(env.items())
        if key not in UNEXPORTED_ENV or key in overridden
    ]


def write_config(sandbox: Path, project: Path) -> None:
    """Pre-accept every dialog, including the one only the TUI raises.

    A reused --sandbox is patched rather than rebuilt: its config dir also
    holds the session transcripts, which is what `claude --resume` reads. The
    keys re-asserted here are the ones a second run can find stale — a run
    from a different cwd needs its own trusted-project entry.
    """
    config_dir = sandbox / "config"
    config_path = config_dir / ".claude.json"
    if not config_dir.exists():
        harness.write_config(sandbox, project)
    config = json.loads(config_path.read_text(encoding="utf-8")) if config_path.exists() else {}
    config["hasTrustDialogAccepted"] = True
    config["hasCompletedOnboarding"] = True
    config.setdefault("projects", {})[str(project)] = {
        "hasTrustDialogAccepted": True,
        "hasCompletedProjectOnboarding": True,
    }
    # The CLI stores an approval under the key's last 20 characters rather than
    # the key itself; a key shorter than that is its own fingerprint.
    config["customApiKeyResponses"] = {"approved": [STUB_API_KEY[-20:]], "rejected": []}
    config_dir.mkdir(parents=True, exist_ok=True)
    config_path.write_text(json.dumps(config, indent=2), encoding="utf-8")


def summary_lines(server: StubServer, env: dict[str, str]) -> list[str]:
    """What the stub served, and whether claude was actually pointed at it.

    `env` is the environment claude was handed, not the server's own view:
    `--env ANTHROPIC_BASE_URL=...` can aim the CLI somewhere else entirely,
    and the loopback claim would be a lie about traffic the stub never saw.
    """
    capture = server.capture
    base_url = server.base_url
    claude_url = env.get("ANTHROPIC_BASE_URL", "")
    unexpected = harness.tolerated_unexpected_paths(capture.unexpected_paths)
    lines = [f"{len(capture.raw_bodies)} request(s) served at {base_url}"]
    counts: dict[str, int] = {}
    for route in capture.routes:
        label = TITLE_LABEL if route == TITLE_SENTINEL else (route or "(ordered turns)")
        counts[label] = counts.get(label, 0) + 1
    if len(counts) > 1:  # a single route is just the request count again
        for label, count in sorted(counts.items()):
            lines.append(f"  route {label}: {count}")
    lines.append(f"unexpected paths: {', '.join(unexpected) if unexpected else 'none'}")
    lines.append(f"client disconnects: {len(capture.client_disconnects)}")
    if claude_url == base_url:
        lines.append(
            f"no model request left this machine — ANTHROPIC_BASE_URL was {base_url} (loopback)"
        )
    else:
        lines.append(
            f"ANTHROPIC_BASE_URL was overridden to {claude_url}; the stub served "
            f"{len(capture.raw_bodies)} request(s), and requests to that URL are "
            "not counted here"
        )
    return lines


def report(lines: list[str]) -> None:
    for line in lines:
        print(f"claude-stub: {line}", file=sys.stderr)
    # Flushed rather than left to stderr's buffering: the `serving` line is
    # what a caller (and the tests) wait on to know the server is up, so it
    # has to reach a redirected stderr as soon as it is written.
    sys.stderr.flush()


class Terminated(Exception):
    """A stop signal arrived with nothing else to hand it to.

    Raised out of the signal handler so the signal unwinds through `main`'s
    cleanup instead of the interpreter dying where it stands.
    """

    def __init__(self, signum: int) -> None:
        super().__init__(f"terminated by signal {signum}")
        self.signum = signum


class SignalTargets:
    """Who owns a stop signal right now, as the run moves through its phases.

    The handler tests these in order: once the run is `finishing` there is
    nothing left to signal and the signal is swallowed; a live `claude` owns
    the signal and is handed it by `deliver`; a spawn in flight queues it (to
    be handed over the same way once the child has a name), because the
    fork may already exist under a name nothing has been handed yet; a
    `--print-env` server stops serving; otherwise nothing is running that can
    take it, so the signal becomes a `Terminated`.
    """

    def __init__(self) -> None:
        self.child: subprocess.Popen | None = None
        self.spawning = False
        self.pending_signum: int | None = None
        self.serving_event: threading.Event | None = None
        # Set once the child has been waited for, the `--print-env` server has
        # stopped, or `main` has reached its cleanup by any route at all:
        # from there on the wrapper is only unwinding.
        self.finishing = False
        # A stop signal that arrived during that unwind, kept for the summary.
        self.late_signum: int | None = None


SIGNAL_TARGETS = SignalTargets()
# SIGINT is one of these rather than being left to Python's default
# `KeyboardInterrupt`, so a Ctrl-C gets the same phase-aware treatment as the
# other two: held off across `mkdtemp`, queued across the spawn, turned into a
# clean stop while `--print-env` is serving, and swallowed while finishing.
# Under the default disposition it could land between `mkdtemp` creating the
# directory and the name reaching `sandbox` (the sandbox then leaks), or
# between the fork inside `Popen` and the child reaching `SIGNAL_TARGETS`
# (the sandbox is then removed out from under a still-running `claude`).
STOP_SIGNALS = (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)


def forward(child: subprocess.Popen, signum: int) -> None:
    """Hand `signum` to the child, tolerating a child that just exited.

    Every forwarding site races the child's own exit: between deciding to
    forward and the `kill(2)` the child can die and be reaped, and signalling
    a pid that is gone raises `ProcessLookupError`. There is nothing left to
    signal, which is the outcome that was wanted, so it is not an error.
    """
    try:
        child.send_signal(signum)
    except OSError:  # the child died between the check and the signal
        pass


def deliver(child: subprocess.Popen, signum: int) -> None:
    """Forward `signum` to the child, unless the terminal already has.

    Only SIGINT can have reached the child on its own: a tty delivers it to
    every process in the foreground group, and `claude` deliberately shares the
    wrapper's group so it can own the tty. A second one would read as the
    double Ctrl-C the TUI exits on, so the rule is by position rather than by
    sender: when the wrapper is the terminal's foreground process group, a
    SIGINT is treated as a Ctrl-C the child already received and is not
    forwarded, whatever sent it. A `kill -INT` aimed at a foreground wrapper is
    indistinguishable from the keypress and is dropped with it. A SIGINT that
    arrives while the wrapper has no controlling terminal or is not the
    foreground group — from a script, `nohup`, `start_new_session` — is
    forwarded (`sigint_reached_child_already`).

    SIGTERM is the signal for stopping a wrapped session from outside: it, like
    every stop signal that is not SIGINT, is forwarded unconditionally, and
    nothing reaches the child by any route but this one.
    """
    if signum == signal.SIGINT and sigint_reached_child_already():
        return
    forward(child, signum)


def handle_stop_signal(signum: int, _frame: Any) -> None:
    if SIGNAL_TARGETS.finishing:
        # The child has already been waited for and the wrapper is at most a
        # few milliseconds from returning through its own cleanup, so nothing
        # here can take the signal and nothing needs to. Raising `Terminated`
        # instead would clobber the status the child actually exited with, and
        # could unwind out of `shutil.rmtree` mid-walk and strand half a
        # sandbox. Record it for the summary and swallow it.
        SIGNAL_TARGETS.late_signum = signum
        return
    child = SIGNAL_TARGETS.child
    if child is not None:
        # PEP 475 retries the interrupted `wait()` once this returns, so the
        # wrapper's own status follows however the child answers the signal.
        deliver(child, signum)
        return
    if SIGNAL_TARGETS.spawning:
        SIGNAL_TARGETS.pending_signum = signum
        return
    event = SIGNAL_TARGETS.serving_event
    if event is not None:
        event.set()
        return
    raise Terminated(signum)


def install_signal_handlers() -> dict[int, Any]:
    """Take every stop signal; return what they were, for restoring after."""
    return {sig: signal.signal(sig, handle_stop_signal) for sig in STOP_SIGNALS}


def restore_signal_handlers(previous: dict[int, Any]) -> None:
    for sig, handler in previous.items():
        if handler is not None:  # None = a handler Python cannot reinstate
            signal.signal(sig, handler)


def sigint_reached_child_already(stdin_fd: int = 0) -> bool:
    """True when the wrapper sits where the terminal delivers SIGINT itself.

    A tty sends its SIGINT to every process in the terminal's foreground
    process group, and `claude` deliberately stays in the wrapper's own group
    so it can own the tty — so when the wrapper is that foreground group, a
    Ctrl-C reached the child directly. Forwarding a second one is not harmless:
    the TUI exits on a double Ctrl-C, so the wrapper would be answering the
    user's first press with the confirmation for a second.

    This is a test of *position*, not of provenance, and it cannot be anything
    else: a Python handler is handed a signal number and no siginfo, so a
    `kill -INT <wrapper pid>` and a keypress are the same event here. The rule
    the wrapper commits to is therefore stated in those terms — in the
    foreground-group case a SIGINT is treated as a terminal Ctrl-C the child
    already has, whatever sent it, and is not forwarded. Use SIGTERM to stop a
    wrapped session from outside; that is forwarded from every position.

    False whenever the foreground reasoning does not hold — stdin is not a tty,
    there is no controlling terminal, or the wrapper is in the background
    (a script, `nohup`, `start_new_session`) — because nothing but this wrapper
    can have handed the child that signal. False is the safe answer either
    way: it forwards.
    """
    try:
        return os.isatty(stdin_fd) and os.tcgetpgrp(stdin_fd) == os.getpgrp()
    except OSError:  # no controlling tty, or a closed or unreadable fd
        return False


def run_claude(binary: str, claude_args: list[str], env: dict[str, str]) -> int:
    """Run claude with stdio inherited; signals reach it, we still summarize.

    The child deliberately stays in this process's own group and session: the
    interactive TUI has to remain in the terminal's foreground process group to
    own the tty, so it cannot be put behind `start_new_session`. That shared
    group is why `deliver` does not forward a SIGINT the wrapper takes while it
    is the foreground group: there the terminal delivered it to the child too,
    so it is treated as a Ctrl-C the child already has whatever sent it, and
    SIGTERM is the signal for stopping the pair from outside. All this has to
    do is publish the child for the handlers `main` installed before any
    resource existed. Without those a stop signal to the wrapper would take the
    interpreter's default disposition — the process dies where it stands,
    `main`'s `finally` never runs, the sandbox is left on disk, and `claude`
    keeps running with nobody waiting on it.

    PEP 475 retries the interrupted `wait()` once a handler returns, so the
    call resumes and returns the child's status as soon as the forwarded
    signal lands.

    The spawn itself is the one moment the child cannot be named: a signal
    landing inside `Popen` — after the fork, before the object comes back —
    would unwind past a process nothing can signal or wait for, orphaning it.
    Masking the signals across the spawn is not the fix, because the mask
    survives `exec` and would hand `claude` a blocked SIGTERM. So the handler
    queues instead, and the signal is delivered by hand once the child has a
    name.
    """
    SIGNAL_TARGETS.pending_signum = None
    SIGNAL_TARGETS.spawning = True
    child: subprocess.Popen | None = None
    try:
        child = subprocess.Popen([binary, *claude_args], env=env)
        # Published before `spawning` is cleared, so no signal can fall
        # between the two and find nothing willing to take it.
        SIGNAL_TARGETS.child = child
    except FileNotFoundError:
        report([f"claude binary not found: {binary}"])
    finally:
        SIGNAL_TARGETS.spawning = False

    queued = SIGNAL_TARGETS.pending_signum
    if child is None:
        if queued is not None:
            raise Terminated(queued)
        # Nothing was spawned and nothing else will be, so the same rule as
        # below applies: a stop signal from here on has nothing to act on.
        SIGNAL_TARGETS.finishing = True
        return 127

    try:
        if queued is not None:
            deliver(child, queued)
        # No `except KeyboardInterrupt` here: SIGINT is in STOP_SIGNALS, so
        # `handle_stop_signal` owns it for the whole of this call — installed
        # by `main` before any resource existed and restored only in `main`'s
        # outermost `finally`. Python raises KeyboardInterrupt from the default
        # SIGINT disposition alone, and that disposition is not installed here,
        # so the wait can only be interrupted and then resumed by PEP 475.
        status = child.wait()
    finally:
        # The child has been waited for, so from here the wrapper is only
        # unwinding — a few milliseconds of summary, sandbox removal, and
        # return. A stop signal landing in that window has nothing to reach,
        # so the handler swallows it rather than replacing the child's status
        # with a `Terminated` or interrupting the sandbox removal.
        #
        # Latched before the child is dropped, never after: the handler tests
        # `finishing` first and `child` second, so this order leaves no
        # bytecode gap in which a signal finds neither. The reverse order has
        # one, and a signal landing in it raises `Terminated`.
        SIGNAL_TARGETS.finishing = True
        SIGNAL_TARGETS.child = None
    # Popen.wait reports a signal death as a negative signal number; callers
    # reading an exit status expect the shell's conventional 128 + signal.
    return status if status >= 0 else 128 - status


def serve_until_signalled(
    env: dict[str, str], binary: str, extra_env: dict[str, str] | None = None
) -> None:
    """--print-env: hand the caller exports, keep serving until a stop signal.

    No handler is installed here: every stop signal is already `main`'s, and
    publishing the event is what turns one into a clean stop rather than a
    `Terminated` unwind. Ctrl-C takes that same route, since SIGINT is a stop
    signal like the other two — the handler sets the event and returns, the
    `wait()` resumes and sees it set, and the caller still gets the closing
    summary.
    """
    for line in export_lines(env, extra_env):
        print(line)
    print(f"# eval these in another pane, then run: {shlex.quote(binary)}")
    print(f"# run claude from this directory (the sandbox trusts it): {Path.cwd()}")
    sys.stdout.flush()
    stop = threading.Event()
    # Published before the line that announces it, never after: the `serving`
    # line is what a caller waits on to know the server is up, and a signal
    # arriving between the line and the event would find no target and raise
    # `Terminated` instead of stopping the server cleanly.
    SIGNAL_TARGETS.serving_event = stop
    try:
        report(["serving; Ctrl-C (or SIGTERM) to stop"])
        stop.wait()
    finally:
        SIGNAL_TARGETS.serving_event = None
        # Same as after the child is waited for: serving is over, so a stop
        # signal arriving during the summary and the sandbox removal has
        # nothing left to stop and must not unwind the cleanup.
        SIGNAL_TARGETS.finishing = True


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="claude-stub.py",
        description=(
            "Run the real claude CLI against a fake model API on loopback. "
            "Zero tokens, no network, runs without a real API key. Arguments "
            "after `--` go to claude (none = interactive TUI; `-p PROMPT` = "
            "headless)."
        ),
        epilog=(
            "Requests past the end of the scripted turns are answered with the "
            "server's overflow turn, whose text is STUB-TERMINAL, so a session "
            "never hangs waiting for a turn that was never written."
        ),
    )
    script = parser.add_mutually_exclusive_group()
    script.add_argument("--turns", metavar="FILE.json", help="JSON list of turns, or {turns, role_turns}")
    script.add_argument("--text", help="serve a single text turn with this content")
    parser.add_argument("--lines", type=int, default=200, help="lines in the default long answer (default: 200)")
    parser.add_argument("--sandbox", help="sandbox dir (default: a fresh temp dir; an explicit one is kept)")
    parser.add_argument("--keep", action="store_true", help="keep the sandbox dir at exit")
    parser.add_argument("--env", action="append", default=[], metavar="KEY=VALUE", help="extra env for claude (repeatable)")
    parser.add_argument("--print-env", action="store_true", help="print `export` lines and keep serving instead of running claude")
    parser.add_argument("--claude-binary", default="claude", help="claude executable (default: claude from PATH)")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    """Serve the fake API for one run, and reclaim the sandbox afterwards.

    The stop-signal handlers go on first, before a single resource exists, so
    any of SIGTERM, SIGHUP and SIGINT arriving anywhere below — building the
    sandbox, binding the stub server, spawning claude — unwinds through the
    cleanup instead of taking the interpreter's default disposition. Once the
    run is finishing — the child waited for, the `--print-env` server stopped,
    or the run failing its way into the cleanup below — a stop signal is
    instead recorded and swallowed, so the last few milliseconds of summary and
    sandbox removal cannot be interrupted either, and the status stays the one
    the child exited with. The guarantee is the same for all three: only
    SIGKILL or a hard crash can leave the sandbox on disk or the child
    unwaited-for.

    What the three do differs only for SIGINT, and only by where the wrapper
    sits: as the terminal's foreground process group it treats a SIGINT as a
    Ctrl-C `claude` already received and does not forward it, whatever sent it,
    while a SIGINT arriving with no controlling terminal or from the background
    is forwarded like any other. SIGTERM is the signal for stopping the wrapper
    and its child from outside.
    """
    previous_handlers = install_signal_handlers()
    try:
        if "--" in argv:
            split = argv.index("--")
            argv, claude_args = argv[:split], argv[split + 1 :]
        else:
            claude_args = []
        args = parse_args(argv)
        turns, role_turns = resolve_turns(args)

        keep = args.keep or args.sandbox is not None
        routes = build_routes(role_turns)
        sandbox: Path | None = None
        # The sandbox is created inside the cleanup scope, not before it: a
        # corrupted `.claude.json` in a reused sandbox, an unwritable path, or
        # a signal would otherwise fail between creation and the `finally`,
        # stranding a fresh temp dir that nothing ever removes.
        try:
            # The one gap a stop signal must not land in: `tempfile.mkdtemp`
            # creates the directory and only then returns its name, and a
            # handler runs between the two, so a `Terminated` raised there
            # would unwind past a sandbox nobody can name, let alone remove.
            # Held off across the assignment the signal merely stays pending,
            # and lands the moment the sandbox is reachable by the `finally`.
            blocked = signal.pthread_sigmask(signal.SIG_BLOCK, STOP_SIGNALS)
            try:
                sandbox = (
                    Path(args.sandbox)
                    if args.sandbox
                    else Path(tempfile.mkdtemp(prefix="claude-stub-"))
                )
            finally:
                signal.pthread_sigmask(signal.SIG_SETMASK, blocked)
            sandbox.mkdir(parents=True, exist_ok=True)
            (sandbox / "tmp").mkdir(exist_ok=True)
            write_config(sandbox, Path.cwd())
            with StubServer(turns, role_turns=routes) as server:
                base_url = server.base_url
                extra_env = parse_env_assignments(args.env)
                env = build_env(sandbox, base_url, dict(os.environ), extra_env)
                if args.print_env:
                    serve_until_signalled(env, args.claude_binary, extra_env)
                    status = 0
                else:
                    status = run_claude(args.claude_binary, claude_args, env)
                report(summary_lines(server, env))
        finally:
            # Armed here for every path into this block, not just the two that
            # arm it themselves: by the time control reaches it any child has
            # been waited for or never existed, and the wrapper is a few
            # milliseconds from returning. An exception out of `mkdir`,
            # `write_config` or the server's socket bind would otherwise get
            # here with the latch unset, and a stop signal landing during the
            # `rmtree` below would raise `Terminated` out of a half-walked
            # sandbox. `run_claude` and `serve_until_signalled` still latch on
            # their own way out — that covers the window between the child
            # exiting and control reaching this line.
            SIGNAL_TARGETS.finishing = True
            if sandbox is not None:
                if keep:
                    report([f"sandbox kept at {sandbox}"])
                else:
                    shutil.rmtree(sandbox, ignore_errors=True)
        if SIGNAL_TARGETS.late_signum is not None:
            report(
                [
                    f"signal {SIGNAL_TARGETS.late_signum} arrived while exiting; "
                    "nothing left to stop"
                ]
            )
        return status
    except Terminated as terminated:
        report([f"stopped by signal {terminated.signum}"])
        return 128 + terminated.signum
    except KeyboardInterrupt:
        # A belt for the instants either side of the handler's reign: SIGINT is
        # a stop signal, so a Ctrl-C from here on arrives as `Terminated` like
        # any other, and only one landing before `install_signal_handlers` has
        # returned — or after `restore_signal_handlers` puts the default back —
        # can still take the KeyboardInterrupt disposition. Same outcome as the
        # `Terminated` above: report the signal, keep the cleanup the `finally`
        # blocks already did, and answer 130 rather than a traceback.
        report([f"stopped by signal {int(signal.SIGINT)}"])
        return 128 + int(signal.SIGINT)
    finally:
        restore_signal_handlers(previous_handlers)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
