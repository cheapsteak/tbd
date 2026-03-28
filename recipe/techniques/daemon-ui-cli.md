# Daemon-UI-CLI three-process split

## Posture: Make

Architectural pattern. Three SPM targets in one Swift package.

## The problem

A macOS app that manages long-running terminal sessions needs to survive its own UI crashes. It also needs to be scriptable by AI agents that work in terminals, not GUIs.

## The technique

Split into three processes:
- **Daemon (`tbdd`):** Long-running headless process that owns all state (database, tmux servers, git operations, hooks). Communicates via Unix socket and HTTP.
- **App (`TBD.app`):** SwiftUI client that subscribes to the daemon's state stream. Owns only window layout. Stateless — can be killed and restarted without data loss.
- **CLI (`tbd`):** Stateless tool that sends a command to the daemon socket, prints the response, exits. Auto-resolves repo and worktree from `$PWD`.

The daemon is the brain. The app and CLI are views.

## Why not alternatives

- **Monolithic app:** UI crash kills everything. Agents can't interact when app is closed.
- **App + CLI (no daemon):** State lives in the app process. CLI can't work when app is closed. App crash loses state.
- **Electron/web approach:** Heavy runtime, poor macOS integration, no native terminal performance.

## Where this applies

Any developer tool that needs to survive crashes and be accessible to both humans (GUI) and machines (CLI/API).
