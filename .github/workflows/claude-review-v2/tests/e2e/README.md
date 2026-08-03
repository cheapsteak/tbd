# Stub-API e2e tests

`stub_server.py` is a stdlib fake of the model API (`POST /v1/messages`, SSE
streaming). The e2e test (`test_session_contract.py`) points the **real**
`claude` CLI at it — sandboxed `HOME`/`CLAUDE_CONFIG_DIR`, throwaway git repo,
the real Stop hook and the real `validate.py` — and scripts the whole review
session as canned turns. Zero tokens, fully deterministic; it proves the
session contract (tool loop, findings files, `review-result.json`, Stop-hook
release, computed verdict), per the design spec §4
(`docs/specs/2026-08-03-pr-review-fanout-design.md`).

## Why SSE framing is non-negotiable

The CLI sends `stream: true`. If the stub answered with plain JSON, the CLI
would **silently retry a byte-identical request while executing nothing** — a
naive request counter reads that as progress. Hence the strict SSE event
sequence in `stub_server.py` and `loop_advanced()`, which rejects the
retry signature (first two request bodies byte-identical) and demands a real
`tool_result` block before calling the loop advanced.

## Running locally

```sh
python3 -m pytest .github/workflows/claude-review-v2/tests/e2e/ -q
```

The stub self-tests always run. The e2e self-skips when no `claude` binary is
on `PATH`, so CI without the toolchain cannot flake. `validate.py`'s
sub-assertion additionally needs `jsonschema` (skipped with a note otherwise).
