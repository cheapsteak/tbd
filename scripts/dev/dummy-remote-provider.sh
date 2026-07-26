#!/usr/bin/env bash
# Dummy remote provider for live-testing TBD's remote-backend UI without any
# real backend. Implements the v1 contract (docs/remote-provider-contract.md)
# against plain JSON files in a temp state dir — no network, no auth, no
# persistence beyond one file per session.
#
# Register in ~/tbd/agent-providers.json as:
#   [{"name": "dummy", "exec": "<abs path to this script>"}]
#
# Sessions live in $TBD_DUMMY_STATE (default /tmp/tbd-dummy-provider/) as one
# JSON file per session, named "<id>.json". For manual testing you can hand-
# edit a file's "agent_state" to "waiting_input", or delete it to simulate the
# session disappearing (TBD marks it "gone" after two consecutive misses).
set -euo pipefail

STATE_DIR="${TBD_DUMMY_STATE:-/tmp/tbd-dummy-provider}"
mkdir -p "$STATE_DIR"

case "${1:-}" in
  describe)
    cat <<'EOF'
{"contract_versions": [1], "name": "dummy", "provider_version": "0.0.1",
 "capabilities": ["log", "send", "attach"],
 "create_params": [
   {"name": "title", "type": "string", "label": "Title", "required": true},
   {"name": "repo", "type": "string", "label": "Repository"},
   {"name": "branch", "type": "string", "label": "Branch", "default": "main"},
   {"name": "prompt", "type": "text", "label": "Initial prompt"},
   {"name": "size", "type": "enum", "label": "Size", "values": ["small", "large"], "default": "small"}]}
EOF
    ;;

  create)
    # Builds and persists the session JSON in python rather than printf/sed —
    # avoids hand-rolled JSON string escaping for user-supplied strings.
    python3 -c '
import json, random, sys, time

state_dir = sys.argv[1]
req = json.load(sys.stdin)
params = req.get("params") or {}
title = params.get("title") or "untitled"
# ponytail: time+random id, not a durable/collision-proof id scheme (real
# providers derive ids from persisted state, not PID/clock) — fine for a
# manual dev-test stub, upgrade if this ever needs to survive real reuse.
sid = f"dummy-{int(time.time())}-{random.randint(0, 9999)}"
session = {"id": sid, "title": title, "state": "running", "agent_state": "working"}
# `repo`/`branch` are well-known meta keys (docs/remote-provider-contract.md
# section "Session object") TBD resolves against locally registered repos to
# place this session inside that repo sidebar section instead of the
# provider-named Remote section. Only set when the caller actually supplied
# a repo -- an absent/blank repo param leaves meta unset, exercising the
# unmatched (provider-named section) path.
repo = params.get("repo")
if repo:
    session["meta"] = {"repo": repo, "branch": params.get("branch") or "main"}
with open(f"{state_dir}/{sid}.json", "w") as f:
    json.dump(session, f)
json.dump(session, sys.stdout)
' "$STATE_DIR"
    ;;

  list)
    python3 -c '
import glob, json, sys

state_dir = sys.argv[1]
sessions = []
for path in sorted(glob.glob(f"{state_dir}/*.json")):
    try:
        with open(path) as f:
            sessions.append(json.load(f))
    except (OSError, ValueError):
        continue  # skip unreadable/mid-write files rather than fail the whole list
json.dump({"sessions": sessions}, sys.stdout)
' "$STATE_DIR"
    ;;

  stop)
    id="${2:?stop requires a session id}"
    python3 -c '
import json, sys

state_dir, sid = sys.argv[1], sys.argv[2]
path = f"{state_dir}/{sid}.json"
try:
    with open(path) as f:
        session = json.load(f)
except (OSError, ValueError):
    session = {"id": sid}  # unknown id: still succeed, per contract idempotence
session["state"] = "exited"
session["agent_state"] = "exited"
with open(path, "w") as f:
    json.dump(session, f)
json.dump(session, sys.stdout)
' "$STATE_DIR" "$id"
    ;;

  log)
    id="${2:?log requires a session id}"
    printf 'hello from dummy session %s\nline two\n' "$id"
    ;;

  send)
    cat > /dev/null
    echo '{}'
    ;;

  attach)
    # Lands in a plain interactive shell; exit = viewer detached, the
    # (nonexistent) remote session is unaffected — matches the contract's
    # "pane exit never means session dead" rule.
    exec bash -i
    ;;

  *)
    verb="${1:-<none>}"
    printf '{"error": {"code": "invalid_params", "message": "unknown verb %s"}}\n' "$verb"
    exit 2
    ;;
esac
