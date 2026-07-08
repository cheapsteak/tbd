#!/usr/bin/env bash
# scripts/install-reclaim-agent.sh — install/uninstall the hourly reclaim-build launchd agent.
# Dev tooling; NOT part of the shipped product.
#
# Usage:
#   scripts/install-reclaim-agent.sh install     # from a STABLE checkout (e.g. ~/projects/tbd), not a throwaway worktree
#   scripts/install-reclaim-agent.sh uninstall

LABEL="com.tbd.reclaim-build"

write_plist() { # OUT_PATH SCRIPT_PATH
  local out="$1" script="$2"
  cat > "$out" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${script}</string>
  </array>
  <key>StartInterval</key><integer>3600</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>${HOME}/Library/Logs/tbd-reclaim-build.log</string>
  <key>StandardErrorPath</key><string>${HOME}/Library/Logs/tbd-reclaim-build.log</string>
</dict>
</plist>
PLIST
}

_main() {
  local cmd="${1:-}"
  local repo_root; repo_root="$(cd "$(dirname "$0")/.." && pwd)"
  local script="$repo_root/scripts/reclaim-build.sh"
  local plist="$HOME/Library/LaunchAgents/$LABEL.plist"
  case "$cmd" in
    install)
      mkdir -p "$HOME/Library/LaunchAgents"
      write_plist "$plist" "$script"
      launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
      launchctl bootstrap "gui/$(id -u)" "$plist"
      echo "Installed $LABEL -> $script (hourly). Log: ~/Library/Logs/tbd-reclaim-build.log"
      ;;
    uninstall)
      launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
      rm -f "$plist"
      echo "Uninstalled $LABEL."
      ;;
    *)
      echo "usage: $0 install|uninstall" >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  _main "$@"
fi
