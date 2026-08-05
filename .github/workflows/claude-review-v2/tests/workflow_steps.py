"""Pull one step's shell body out of the v2 review workflow, BY STEP NAME.

The workflow's "Post review comment and enforce verdict" step implements
safety-shaped ordering in shell — the verdict gate before anything is posted,
the minimize sweep before the post, the REJECT exit after it — and shell that
nothing executes is correct only by inspection. These helpers extract a named
step's `run:` block so a test can run it under bash against a stubbed `gh`.

Lookup is by EXACT step name and raises when the name is absent: renaming a
step fails the tests loudly rather than silently leaving them asserting on
nothing.

Stdlib only, and the parse is deliberately literal rather than a YAML load —
the CI job that runs this suite installs pytest and jsonschema, nothing else.
Steps are the `- name:` entries at the shallowest such indentation in the file
(this workflow has one job), and a run body is the block scalar under `run: |`.

Not a test module — pytest does not collect it.
"""

from __future__ import annotations

import re
import textwrap
from pathlib import Path

# .../.github/workflows/claude-review-v2/tests/ -> .../.github/workflows/
_WORKFLOWS_DIR = Path(__file__).resolve().parents[2]
WORKFLOW_PATH = _WORKFLOWS_DIR / "claude-code-review-v2.yml"

_STEP_RE = re.compile(r"^(?P<indent> *)- name: (?P<name>.+?) *$")
_RUN_RE = re.compile(r"^(?P<indent> *)run: \| *$")


class StepNotFound(LookupError):
    """No step in the workflow carries the requested name."""


def read_workflow(path: Path = WORKFLOW_PATH) -> str:
    return path.read_text(encoding="utf-8")


def _split_steps(text: str) -> list[tuple[str, list[str]]]:
    """Every step as (name, its own lines), in file order."""
    lines = text.split("\n")
    heads = [(i, m) for i, line in enumerate(lines) if (m := _STEP_RE.match(line))]
    if not heads:
        return []
    # Deeper `- name:` lines (were one ever to appear inside a prompt or a
    # nested mapping) are not steps.
    step_indent = min(len(m.group("indent")) for _, m in heads)
    heads = [(i, m) for i, m in heads if len(m.group("indent")) == step_indent]

    steps: list[tuple[str, list[str]]] = []
    for position, (start, match) in enumerate(heads):
        end = heads[position + 1][0] if position + 1 < len(heads) else len(lines)
        steps.append((match.group("name"), lines[start:end]))
    return steps


def step_names(text: str) -> list[str]:
    """Every step name, in the order the job runs them."""
    return [name for name, _ in _split_steps(text)]


def step_index(text: str, name: str) -> int:
    """Position of the named step among the job's steps."""
    names = step_names(text)
    try:
        return names.index(name)
    except ValueError as exc:
        raise StepNotFound(
            f"workflow step {name!r} not found. Steps are: {names}"
        ) from exc


def step_source(text: str, name: str) -> str:
    """The named step's own lines, verbatim (comments and all)."""
    for step_name, lines in _split_steps(text):
        if step_name == name:
            return "\n".join(lines)
    raise StepNotFound(
        f"workflow step {name!r} not found. Steps are: {step_names(text)}"
    )


def run_block(text: str, name: str) -> str:
    """The named step's `run: |` body, dedented, ready to hand to bash."""
    lines = step_source(text, name).split("\n")
    for position, line in enumerate(lines):
        match = _RUN_RE.match(line)
        if not match:
            continue
        indent = len(match.group("indent"))
        body: list[str] = []
        for follower in lines[position + 1 :]:
            if follower.strip() == "":
                body.append("")
                continue
            if len(follower) - len(follower.lstrip(" ")) <= indent:
                break
            body.append(follower)
        return textwrap.dedent("\n".join(body)).rstrip("\n") + "\n"
    raise StepNotFound(f"workflow step {name!r} has no `run: |` block")
