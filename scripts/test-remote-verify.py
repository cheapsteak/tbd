"""Tests for scripts/remote_verify.py (stdlib only).

The ticket pool is exercised against real `flock`s in a temp directory, never
the real `~/tbd/runtime`: the pool's whole job is to bound how many remote
runs exist at once, and a mocked lock would prove nothing about that.

One case takes a ticket in a separate process, because a lock that only holds
within one interpreter would bound nothing — forty agent lanes are forty
processes.  That child is killed by the exact pid recorded at spawn; a
pattern kill would match unrelated sessions on this machine.
"""

from __future__ import annotations

import contextlib
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parent.parent
MODULE_PATH = REPO_ROOT / "scripts" / "remote_verify.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("remote_verify", str(MODULE_PATH))
    assert spec is not None and spec.loader is not None, f"no import spec for {MODULE_PATH}"
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


remote_verify = _load_module()


# Takes a ticket, announces its index on stdout, and holds it until stdin
# closes.  Run as a separate process so the flock is contended across
# processes rather than within one interpreter.
TICKET_HOLDER = """
import sys
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location("remote_verify", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with module.take_dispatch_ticket(Path(sys.argv[2]), int(sys.argv[3])) as index:
    print(index, flush=True)
    sys.stdin.readline()
"""


class DispatchTicketTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.runtime = Path(self.temp.name) / "runtime"

    def tearDown(self):
        self.temp.cleanup()

    def test_tickets_are_bounded_by_the_slot_count(self):
        with remote_verify.take_dispatch_ticket(self.runtime, 2):
            with remote_verify.take_dispatch_ticket(self.runtime, 2):
                with self.assertRaises(remote_verify.NoTicket):
                    with remote_verify.take_dispatch_ticket(self.runtime, 2):
                        pass

    def test_a_released_ticket_is_reusable(self):
        with remote_verify.take_dispatch_ticket(self.runtime, 1):
            pass
        with remote_verify.take_dispatch_ticket(self.runtime, 1) as index:
            self.assertEqual(index, 1)

    def test_a_ticket_is_released_when_the_body_raises(self):
        with contextlib.suppress(RuntimeError):
            with remote_verify.take_dispatch_ticket(self.runtime, 1):
                raise RuntimeError("the remote run blew up")
        with remote_verify.take_dispatch_ticket(self.runtime, 1) as index:
            self.assertEqual(index, 1)

    def test_zero_slots_refuses_immediately(self):
        with self.assertRaises(remote_verify.NoTicket):
            with remote_verify.take_dispatch_ticket(self.runtime, 0):
                pass

    def test_the_ticket_files_are_named_for_their_index(self):
        with remote_verify.take_dispatch_ticket(self.runtime, 2):
            with remote_verify.take_dispatch_ticket(self.runtime, 2):
                pass
        self.assertTrue((self.runtime / "remote-verify-1.lock").exists())
        self.assertTrue((self.runtime / "remote-verify-2.lock").exists())

    def test_a_ticket_held_by_another_process_is_not_reissued(self):
        holder = subprocess.Popen(
            [sys.executable, "-c", TICKET_HOLDER, str(MODULE_PATH), str(self.runtime), "2"],
            text=True,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
        )
        holder_pid = holder.pid
        try:
            assert holder.stdout is not None
            self.assertEqual(holder.stdout.readline().strip(), "1")
            with remote_verify.take_dispatch_ticket(self.runtime, 2) as index:
                self.assertEqual(index, 2, "the other process's ticket was reissued")
            with self.assertRaises(remote_verify.NoTicket):
                with remote_verify.take_dispatch_ticket(self.runtime, 1):
                    self.fail("ticket 1 was issued while another process held it")
        finally:
            with contextlib.suppress(ProcessLookupError):
                os.kill(holder_pid, signal.SIGKILL)
            holder.wait(timeout=10)
            for stream in (holder.stdin, holder.stdout):
                if stream is not None:
                    stream.close()


class SlotCountTests(unittest.TestCase):
    def test_the_default_is_two_slots(self):
        self.assertEqual(remote_verify.configured_slots({}), 2)

    def test_an_empty_setting_takes_the_default(self):
        self.assertEqual(
            remote_verify.configured_slots({"TBD_REMOTE_VERIFY_SLOTS": ""}), 2
        )

    def test_the_setting_overrides_the_default(self):
        self.assertEqual(
            remote_verify.configured_slots({"TBD_REMOTE_VERIFY_SLOTS": "3"}), 3
        )

    def test_an_unreadable_setting_is_rejected_by_name(self):
        with self.assertRaises(ValueError) as caught:
            remote_verify.configured_slots({"TBD_REMOTE_VERIFY_SLOTS": "two"})
        self.assertIn("TBD_REMOTE_VERIFY_SLOTS", str(caught.exception))

    def test_a_negative_setting_is_rejected_by_name(self):
        with self.assertRaises(ValueError) as caught:
            remote_verify.configured_slots({"TBD_REMOTE_VERIFY_SLOTS": "-1"})
        self.assertIn("TBD_REMOTE_VERIFY_SLOTS", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
