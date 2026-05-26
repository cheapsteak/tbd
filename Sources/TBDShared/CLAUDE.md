# TBDShared

Models and RPC types shared by daemon, app, and CLI. After changing anything here, use `scripts/restart.sh` (full restart) — the daemon must be restarted to pick up new fields.

`CLIInstaller` installs `~/.local/bin/tbd` as a **hard link**, not a symlink — see the doc comment at the top of `CLIInstaller.swift` for why. Same reason `scripts/restart.sh` uses a hard link for the `.app` bundle binary (PR #195).
