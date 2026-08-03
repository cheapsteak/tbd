# Stub-API e2e tests

`stub_server.py` is a stdlib fake of the model API (`POST /v1/messages`, SSE
streaming). The e2e tests point the **real** `claude` CLI at it — sandboxed
`HOME`/`CLAUDE_CONFIG_DIR` (`harness.py`), throwaway git repo, the real Stop
hook and the real `validate.py` — and script whole review sessions as canned
turns. Zero tokens, fully deterministic; they prove the session contract per
the design spec §4 (`docs/specs/2026-08-03-pr-review-fanout-design.md`).

Scenarios:

- `test_session_contract.py` — single-specialist baseline (tool loop, findings
  file, `review-result.json`, Stop-hook release, computed verdict).
- `test_fanout_contract.py` — two parallel Task specialists via
  content-keyed routing; asserts overlap (true parallelism), all four files,
  zero retries, no Stop-hook nudges, `validate.py --expected-specialists`.
- `test_resume_loop.py` — the between-invocation retry loop: stall to the
  Stop hook's 5-nudge ceiling, then `claude -p --resume <session_id>` with a
  corrective prompt; asserts the counter reset, same-session semantics, and
  that the contract completes across the process boundary.

## Why SSE framing is non-negotiable

The CLI sends `stream: true`. If the stub answered with plain JSON, the CLI
would **silently retry a byte-identical request while executing nothing** — a
naive request counter reads that as progress. Hence the strict SSE event
sequence in `stub_server.py` and `loop_advanced()`, which rejects the retry
signature (first two request bodies byte-identical) and demands a real
`tool_result` block before calling the loop advanced.

## Content-keyed routing

Parallel subagents race for `/v1/messages`, so request-order turn indexing is
nondeterministic across them. In routing mode (`StubServer(role_turns=...)`)
each request is keyed by a `ROLE-<NAME>` sentinel found in **messages[0] text
only** — a subagent's first user message is its Task prompt and never moves,
while the orchestrator's history carries *every* sentinel inside its assistant
Task blocks, so matching anywhere in the body would misroute. Matched requests
are served from that role's own turn list with a per-role index; unmatched
requests fall back to the ordered orchestrator turns. `role_delays` can slow a
role's first response to simulate a straggling specialist.

## Empirical CLI behaviors these tests encode (observed on claude 2.1.220)

- **Task results are async.** A Task tool_use returns immediately with
  "Async agent launched" metadata; subagents run in the background and their
  completions arrive later as system-notification turns (count varies run to
  run — the stub's `STUB-TERMINAL` overflow absorbs the tail). A real
  orchestrator prompt must therefore wait for completions before merging.
- **Process exit blocks on pending background subagents.** Even after the
  Stop hook permits (or gives up on) the session end, the CLI waits for
  in-flight subagents; their files still land. Nothing gets killed at the
  boundary.
- **Resume loops must reset the Stop-hook nudge counter.** The counter lives
  at `${TMPDIR:-/tmp}/claude-review-v2-block-count`, outside session state, so
  a resumed session inherits a burned-out counter and the hook would allow its
  very first stop attempt — `harness.reset_nudge_counter()` between
  invocations is load-bearing.
- The CLI sends one `/api/hello` connectivity preflight per invocation and
  tolerates the stub's 404 (`harness.tolerated_unexpected_paths`).

## Running locally

```sh
python3 -m pytest .github/workflows/claude-review-v2/tests/e2e/ -q
```

The stub self-tests always run. The e2e scenarios self-skip when no `claude`
binary is on `PATH`, so CI without the toolchain cannot flake. `validate.py`'s
sub-assertions additionally need `jsonschema` (skipped with a note otherwise).
