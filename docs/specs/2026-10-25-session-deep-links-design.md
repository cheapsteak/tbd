# Deep links to one session

## Problem

A tool that shows agent sessions on a web page — a dashboard, a status card, a PR body — wants to link straight to the session that is waiting for a person. Today it can link only to a worktree.

The `tbd://open` link format can already name more than that. `DeepLink` in `Sources/TBDShared/DeepLinks.swift` builds and parses `tbd://open?worktree=<uuid>&terminal=<uuid>`, the app opens that terminal's tab, and the tab bar's "Copy link" already copies the shareable https form with a terminal in it. But `tbd link`, the surface an outside tool calls, prints only `worktree=`. And a provider-hosted session (a **remote session**, `docs/remote-provider-contract.md`) has no link at all: the parser requires `worktree`.

## Decision

Two slices, shipped in order:

1. **`tbd link` names a terminal and prints the https form.** No format change: the CLI exposes what the format and the app already support.
2. **A link to a remote session.** A new `remote` param, app navigation for it, `tbd link --remote`, and the redirector page forwarding it.

## Link format

The existing shapes are unchanged:

- `tbd://open?worktree=<uuid>`
- `tbd://open?worktree=<uuid>&terminal=<uuid>`
- the shareable form of either, the same query on `DeepLink.redirectorBase` (`https://cheapsteak.github.io/tbd/open/`)

A remote session is `tbd://open?remote=<provider>/<session>`, and its shareable form carries the same `remote` param.

- **The value is the address `tbd remote` already uses** – the `<provider>/<provider-session-id>` compound that `tbd remote list` prints and that every session-addressed `tbd remote` subcommand accepts (`RemoteSessionRef` in `Sources/TBDCLI/Commands/RemoteCommands.swift`). It splits at the first slash, so a session id may contain slashes. The registry does not forbid a slash in a provider's name, but a provider whose name has one cannot be addressed by this compound, through a link or through `tbd remote`.
- **`provider` is the registry key** – the name a provider is registered under in `~/tbd/agent-providers.json`, which the contract makes the identity of a registration. A remote link therefore means something on the install that made it, as a worktree UUID does.
- **A valid `worktree` param wins** – when a link carries one, the link opens that worktree and `remote` is ignored. Every link that parsed before this change parses to the same target after it.
- **A malformed `remote` is no target** – no slash, or an empty provider or session, and the link is ignored like any malformed link. A malformed `remote` beside a valid `worktree` changes nothing.
- **The parser accepts the slash encoded or not** – the value is read through `URLComponents`, so `remote=acme/sess-42` and `remote=acme%2Fsess-42` are the same link.

`DeepLink` gains builders for both remote forms and a parser that returns one of two targets: a worktree with an optional terminal, or a remote session. Both the CLI and the app use them.

## `tbd link`

- **`tbd link`** – the current worktree, from `TBD_WORKTREE_ID`. It never reads `TBD_TERMINAL_ID`: a bare link stays a worktree link, so scripts that rely on its output keep getting the same thing.
- **`tbd link <worktree>`** – a worktree UUID, name, or display name.
- **`tbd link --terminal <uuid>`** – that terminal's tab. The daemon is the authority on which worktree a terminal belongs to, read through `terminal.list`, so no worktree argument is needed. Given one, it is resolved first, and a terminal that belongs to another worktree is refused with a message naming the terminal, the worktree the argument resolved to (with the name as typed, when a name was typed), and the worktree the terminal belongs to.
- **`tbd link --this-terminal`** – the calling terminal, from `TBD_TERMINAL_ID`, looked up the same way. Outside a TBD terminal it is refused.
- **`tbd link --remote <ref>`** – a remote session. `<ref>` takes the three forms `RemoteSessionRef` resolves: `<provider>/<session>`, the UUID of a lane bound to a session, or the name of one. It cannot be combined with a worktree argument, `--terminal`, or `--this-terminal`.
- **`--https`** – prints the shareable form of any of the above instead of `tbd://`.

The output is one line, the URL. A refusal is one line on stderr with a non-zero exit. Flags that cannot be combined are an argument error instead, which prints usage after its message, as for every `tbd` command.

**The terminal lookup is scoped to one worktree whenever a worktree is known.** `terminal.list` reconciles every row it reports, so a fleet-wide call costs work and side effects across every session on the machine. For both `--terminal` and `--this-terminal`, the CLI lists one worktree's terminals when a worktree argument names it or, without one, when `TBD_WORKTREE_ID` does. It lists fleet-wide only when nothing names a worktree, or once after a scoped miss, to tell a terminal in another worktree apart from one that does not exist. `TBD_WORKTREE_ID` is only a hint: when the daemon puts the terminal in another worktree, the link follows the daemon. Only a worktree the caller typed turns that into a refusal.

### A remote session TBD has not mirrored

`tbd link --remote <provider>/<session>` for a session that is not in TBD's mirror still prints the link and exits 0, and writes a warning to stderr. The compound form is an address, the way `tbd remote` treats it, and refusing would race the mirror: a tool that creates a session and asks for its link at once would be refused until the daemon's next poll of that provider.

The warning names the cause and the next step:

- **Remote sessions are off** – the daemon refuses `remote.*` verbs. The warning points to the "Enable remote agent sessions" setting, which takes effect when the daemon next starts.
- **The provider is not registered** – no provider by that name in the registry. The warning names `~/tbd/agent-providers.json`.
- **The session is not mirrored yet** – the provider is registered, but its last listing did not include the session. TBD mirrors every session a registered provider lists, on its next poll; the warning names `tbd remote list` as the way to check.
- **The daemon is unreachable** – the session could not be checked.

No command adds one session to the mirror: the daemon mirrors whatever a registered provider lists. The other two `<ref>` forms resolve only through the mirror, so a lane UUID or name that resolves to nothing is refused, as `tbd remote` refuses it.

## The app

`DeepLinkHandler` dispatches on the parsed target. A worktree target goes to `navigateToWorktree(_:terminalID:)`, unchanged. A remote target goes to a new `AppState.navigateToRemoteSession(provider:sessionID:)`, which reuses the paths a click takes and adds none of its own:

1. **An adopted lane opens its row.** When an unarchived worktree's `providerBinding` names the session, the app navigates to that worktree as a worktree link would. That is what clicking the lane's row does, and selecting that row is what puts the remote surface on the session (`syncRemoteSurfaceToWorktreeSelection`).
2. **Otherwise a mirrored session is selected.** When the session is in `remoteSessions` and not dismissed, the app calls `selectRemoteSession(provider:sessionID:)`, the call the Remote section's rows, a repo section's matched rows, and the Provider Desk all make.
3. **Otherwise the link is logged and ignored.** A warning in the `deeplink` category, no UI error, as for a worktree link that matches nothing.

**A link does not change attach intent.** It selects with `reattach: false`, like a click. A session the person detached stays detached until they choose Attach.

**A link that arrives during launch waits.** As worktree links do, it is buffered until the initial load finishes, and that load awaits `refreshRemote()`, so the mirror is present when the link is handled. One link is buffered at a time, whatever its kind: a newer link replaces an older one still waiting.

## The redirector

`docs/open/index.html` forwards its query onto `tbd://open`. GitHub Pages serves it from `main`'s `docs/` folder, so merging is the deploy.

- **A valid `worktree`** – forwarded as today, with `terminal` when that is valid.
- **Otherwise a valid `remote`** – forwarded as `tbd://open?remote=<value>`, the value passed through `encodeURIComponent`. Valid means: a slash with a non-empty part on each side, no control characters, and at most 512 characters. The check is looser than the worktree check because the contract makes session ids opaque and provider-minted; encoding keeps the forwarded URL well formed whatever the value holds.
- **Neither** – the page reports a missing or invalid `worktree` or `remote` parameter.

The status line names the session it is opening, HTML-escaped as the worktree name already is.

## Placement, flags, and resources

- **Placement** – link building and parsing live in `TBDShared`, shared by the CLI and the app. Navigation lives in the app, the only place that can select UI.
- **No feature flag** – a new link type acts only when a person opens it. It runs nothing in the background, sends no input, and changes no persisted state.
- **No new durable resource** – nothing is created that outlives the request, so no reconciler is involved.

## Testing

- **`Tests/TBDSharedTests/DeepLinksTests.swift`** – remote builders and parser round trip; a session id containing a slash; an encoded and an unencoded slash; a valid `worktree` beside a `remote` opens the worktree; a malformed `remote` alone is no target; a malformed `remote` beside a valid `worktree` still opens the worktree.
- **`Tests/TBDAppTests/DeepLinkHandlerTests.swift`** – an adopted lane selects its row; an unadopted mirrored session is selected; a dismissed or unknown session changes no selection; a link during launch is handled after the load; a newer buffered link replaces an older one.
- **`Tests/TBDCLITests/LinkCommandTests.swift`** – every `tbd link` form above, the lookup scoping, each refusal, and each unmirrored-session warning cause.
- **The redirector** – it has no test harness. It is checked by hand after deploy with a worktree link, a worktree-and-terminal link, a remote link whose session id contains a slash, and a malformed `remote`.

## Rejected alternatives

- **`provider=<p>&session=<s>`** – two params that mean something only together add a new failure mode, a link carrying one of them. And in TBD "session" already names a local Claude Code session id; the param would claim that name.
- **A bare `tbd link` inside a terminal linking to that terminal** – it changes the output of a command scripts already depend on. A tab-level link is asked for by flag.
- **Refusing an unmirrored remote session** – it races the daemon's poll for a tool that creates a session and links it at once. A mistyped address gets a warning rather than a failure.
- **Reattaching on open** – a link would reconnect a session the person detached on purpose, which a click on its row does not do.
- **A terminal-by-ID RPC** – it would make the lookup one row with no reconcile, but it adds a compiled verb for a one-shot command. A list scoped to one worktree already covers the common case, and the fleet-wide list runs only after a miss.
- **Printing `worktree=` for an adopted session** – adoption can happen after the link is made, when the session's repository is registered later. A `remote=` link resolves to the right row whenever it is opened.
