#!/usr/bin/env bash
# Symlinks repo-tracked git hooks into .git/hooks/. Run once after cloning.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
hooks_src="scripts/git-hooks"
hooks_dst=".git/hooks"

for hook in "$hooks_src"/*; do
  name="$(basename "$hook")"
  ln -sf "../../$hook" "$hooks_dst/$name"
  chmod +x "$hook"
  echo "Installed: $name"
done
