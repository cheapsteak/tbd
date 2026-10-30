# herdr extensibility and product shape: what TBD can take

*Researched 2026-10-30 as a read-only survey of the source of `herdrdev/herdr` at ee5bfb50 (2026-10-29), `herdrdev/herdr-core` at 9edb39d, `herdrdev/herdr-app` at 8180cbe and `herdrdev/herdr-layout-examples` at ed4eda7, plus GitHub issues, PRs and discussions on `herdrdev/*`, the live marketplace index (`https://assets.herdr.dev/plugins/index.json`, generated 2026-10-30T16:00Z), `yigitkonur/awesome-herdr`, and the READMEs and manifests of 17 third-party repos. It covers herdr's plugin model, herdr-core's headless runtime, herdr-app's mods and layouts, and the third-party ecosystem built on them. [`README.md`](README.md) in this folder is the index and synthesis.*

Citation conventions:

- `herdr/…/docs/X.mdx` means `herdr/docs/next/website/src/content/docs/X.mdx`.
- Issues, PRs and discussions are `herdrdev/<repo>#N`. Discussions share the issue number space on `herdrdev/herdr`.
- The herdr issue tracker is bot-triaged (`kangal-bot`, `akbash-bot`) under a "bugs-only issue intake". Almost every plugin-capability request filed as an issue was closed as "not planned" and sent to Ideas discussions. So a closed issue here means "redirected", not "rejected after design review".

Three products share the name, and the distinction matters throughout:

- **herdr (the TUI, "Herdr 1")**. A Rust terminal multiplexer with its own server. Started 2026-03-27; v0.9.5 on 2026-10-14; 46.9k stars. It has the plugin system and the marketplace.
- **herdr-core (`hc`)**. A headless terminal runtime, "Core draws nothing". Repo created 2026-10-16, first public commit 2026-10-23, at v0.1.13. A fresh rewrite, not an extraction.
- **herdr-app ("Herdr 2")**. A native GPUI desktop client of herdr-core. Same dates, at v0.1.9. It has mods and layouts, and explicitly no plugin system.

---

## (a) How herdr does it

### 1. The TUI plugin model (plugin v1, shipped in 0.7.0 on 2026-06-15)

**What a plugin is.** A directory with a `herdr-plugin.toml` manifest plus any executables (`herdr/…/docs/plugins.mdx:18-21`). The stated purpose is "Plugins exist so Herdr can stay lean" (`plugins.mdx:13`). The maintainer used the plugin system as the standard answer to feature requests. Per-project layout scripts and per-worktree setup scripts were both closed with "this looks like a good candidate for a plugin instead of a built-in herdr feature" (herdrdev/herdr#385, herdrdev/herdr#394). A user then built the worktree setup plugin (`tdi/herdr-worktree-setup`, noted in #394).

**Process model.** Every entrypoint is an argv array that runs out of process. There is no shell unless the plugin starts one. The cwd is the plugin root (`plugins.mdx:121-123`, `herdr/src/plugin_command.rs:5-27`). The manifest declares six kinds of entrypoint:

- `[[build]]`. Runs once at `plugin install`, after a confirmation preview. Build commands get a scrubbed environment: no socket, no `HERDR_PLUGIN_*` (`herdr/src/cli/plugin.rs:1257-1275`). Install aborts if the build changes the manifest after the preview (`cli/plugin.rs:330`, `:1042`).
- `[[startup]]`. One-shot commands run after session restore and on live handoff. They are "not supervised daemons" (`plugins.mdx:256`).
- `[[actions]]`. Named commands with declared `contexts` (`global | workspace | tab | pane | selection`, `herdr/src/api/schema/plugins.rs:373-379`). They are invoked from keybindings (`type = "plugin_action"`), the CLI (`herdr plugin action invoke`) or link handlers. Nothing in the UI lists them: right-click menus ignore `contexts` (herdrdev/herdr#5550).
- `[[events]]`. Hooks on lifecycle events. The allowed set is deliberately narrower than the event stream. Output changes, layout updates, metadata updates and `pane.updated` are excluded "until high-volume output-change hook semantics are implemented" (`herdr/src/api/schema/events.rs:286-330`). Unknown names link with a warning rather than failing (`herdr/src/app/api/plugins/manifest.rs:335-342`). Hookable events are workspace/tab/pane created, closed, focused and moved; `worktree.created/opened/removed`; `pane.agent_detected`; and `pane.agent_status_changed`.
- `[[panes]]`. A terminal UI the plugin runs, placed as `overlay` (default), `popup` (session-modal, no pane id), `split`, `tab` or `zoomed`.
- `[[link_handlers]]`. A Rust regex on Ctrl-clicked URLs, routed to one of the plugin's actions.

**What a plugin can see and do.** "There is no separate plugin SDK or restricted command set. The entire Herdr CLI is the plugin API" (`plugins.mdx:23`). Plugins call back through `HERDR_BIN_PATH` (portable across Unix sockets and Windows pipes) or the raw socket. The injected environment (`herdr/src/app/api/plugins/runtime.rs:39-79`, `herdr/src/app/api/plugins/env.rs`) is:

- `HERDR_SOCKET_PATH`, `HERDR_BIN_PATH`, `HERDR_ENV=1`
- `HERDR_PLUGIN_ID`, `HERDR_PLUGIN_ROOT` (a managed checkout; never store state there), `HERDR_PLUGIN_CONFIG_DIR` (user-editable, `~/.config/herdr/plugins/config/<id>`), `HERDR_PLUGIN_STATE_DIR` (under the XDG state dir) (`herdr/src/plugin_paths.rs:44-54`)
- `HERDR_PLUGIN_CONTEXT_JSON`: workspace id, label and cwd; worktree provenance; tab; focused pane, its cwd, agent and status; selected text; invocation source; correlation id; clicked URL; link handler id (`herdr/src/api/schema/plugins.rs:382-413`)
- per-kind extras: `HERDR_PLUGIN_ACTION_ID`, `HERDR_PLUGIN_EVENT` plus `HERDR_PLUGIN_EVENT_JSON`, `HERDR_PLUGIN_ENTRYPOINT_ID`, `HERDR_PLUGIN_CLICKED_URL`, `HERDR_PLUGIN_LINK_HANDLER_ID`
- reserved names a `plugin.pane.open` request cannot override, to stop spoofing (`herdr/src/app/api/plugins/panes.rs:357-370`)

Runtime limits: 32 plugin commands in flight, 64 KiB captured output per command, a 200-entry command log ring (`runtime.rs:11-13`). There is no storage API: "plugins own their files, schemas, migrations, and cleanup" (`plugins.mdx:375`).

**The UI surfaces a plugin can reach.** Every one is narrow, which is the main ecosystem story:

- *Terminal panes* in the five placements above. There is no native, non-terminal plugin UI in v1 (`plugins.mdx:31`).
- *Sidebar metadata tokens.* `pane.report_metadata` and `workspace.report_metadata` set named `$tokens` that the user's `[ui.sidebar.*] rows` config renders. Reports are source-scoped, carry an optional TTL, are ordered by `seq`, and are capped: at most 16 keys per report, 32 per pane, 80 characters per value. They are display-only, so state, waits and notifications still come from semantic state (`herdr/…/docs/socket-api.mdx` around the "Metadata reports are display-only" paragraph; `configuration.mdx:458-478`).
- *Agent views.* `agent.view.set` installs one transient declarative filter and sort (ops `all/any/not/eq/in/exists`, fields including `{"token": name}`) over the Agents sidebar. It is re-evaluated on every fact change, owned by `source = "plugin:<id>"`, and dropped when that plugin is disabled. A plugin that wants it to persist must save it to its state dir and reapply it from a startup hook (`socket-api.mdx:372-447`).
- *Agent state reporting.* `pane.report_agent` and `pane.report_agent_session` with a `resume_argv` let anything become a "recognized agent" that waits, notifications and restore all understand (`herdr/…/docs/add-herdr-support.mdx`).
- *Toasts* (`notification.show`), *window title* (`client.window_title.set`), *layout* (`layout.export` and `layout.apply` with a BSP tree of panes and splits, `socket-api.mdx:199-245`).
- *Events* via `events.subscribe`. Delivery is ordered within a subscription. History is bounded, and on overrun the server sends `events_lost` and closes the connection. The documented recovery is to subscribe again, then reconcile against `session.snapshot` and treat events as invalidations, not replayable deltas (`socket-api.mdx` "Event subscriptions").

**Install, version and trust.**

- `herdr plugin install owner/repo[/subdir]` accepts GitHub shorthand only. It clones, prints a preview (id, version, source, ref, commit, and every build, startup, action, event and pane command; `cli/plugin.rs:954-1010`), asks for confirmation (`--yes` skips it), builds, then registers. Version gating is `min_herdr_version`, which is required. Per-item `platforms` lists are supported. `plugin update` refetches the recorded ref, skips unchanged commits, and leaves linked plugins alone (PR herdrdev/herdr#4245, 0.9.4).
- The registry is a `plugins.json` beside `session.json`. It is global per user since 0.7.5, and writes preserve symlinks so dotfile setups work (`herdr/src/persist/plugin_registry.rs:12`, herdrdev/herdr#3922).
- Installations are generations with a reconciler. Each install or update lands in a fresh `github-installations/<id>/<pid>-<n>/` directory. A running command or pane holds a shared `flock` lease on that generation's `.in-use` file. Cleanup on the next install, update or server start reclaims only generations that are unregistered and unleased, and skips cleanup if pinning was incomplete (`herdr/src/plugin_paths.rs:22-42`, `herdr/src/plugin_installations.rs:9-239`). This is a careful named-reconciler design for a durable resource. Its gap: plugin-spawned background daemons are explicitly the plugin's problem ("Plugins must stop detached background processes before their parent command or pane exits", `plugins.mdx` install section).
- Trust is all-or-nothing. A plugin "runs as your user, inherits your environment, and can call the full Herdr CLI … does not review or sandbox plugin code" (`plugins.mdx:35-52`).

**The marketplace** (`herdr/…/docs/marketplace.mdx`). An automatic, unreviewed index of public GitHub repos with the topic `herdr-plugin` whose default branch has at least one parseable manifest, at the root or in subdirectories. It refreshes every 30 minutes and rescans when the head commit changes. Forks, archived repos and malformed manifests are excluded. It records the exact default-branch commit and shows stars, language and last push. The index hit GitHub search's 1000-result cap in September and needed a fix (herdrdev/herdr#3739).

### 2. herdr-core (`hc`): the headless runtime

- **The rule.** "Core is a runtime, not a multiplexer. If a feature only makes sense with a layout or a workspace to return to, it does not belong here" (`herdr-core/AGENTS.md:22-24`).
- **Status.** Status comes only from OSC 7501, the Program Status Protocol: "No screen detection, no agent registry, no vendor-specific logic. This is the one most likely to be helpfully added; don't" (`herdr-core/AGENTS.md:34-36`). This reverses the TUI's approach of screen manifests plus 24 per-vendor integrations.
- **One API, generated.** Params and results in `api/types.rs` are also the CLI args and the published schema (`AGENTS.md:38-41`). `hc schema` prints OpenRPC. Plain mode is JSON-RPC 2.0 per line. Framed mode carries attach streams with credit flow control; a viewer that falls 4 MiB behind gets a fresh repaint instead of the backlog (`herdr-core/schema/README.md`).
- **"The API only grows."** `released.openrpc.json` is checked in, and a test fails on any change that would break a client of the last release (`schema/README.md:14-21`). The promise has a known hole: behavior defaults and CLI `--json` projections are outside the check, and 0.1.13 flipped child-dies-with-parent to default-on behind a schema-additive diff (herdrdev/herdr-core#33).
- **Holders** own the PTYs, so a core restart or update leaves programs running (`herdr-core/docs/security.md`).
- **What core offers instead of plugins:**
  - `hc events` with `--terminal`, `--children-of` and `--label` filters
  - `hc label` for free-form `k=v` on terminals
  - parent and child terminals, with "notes" sent to the parent when a child needs attention or ends
  - templates
  - machines
  - `hc exec`, `hc file read/edit/write`, `hc put` on remote machines
  - a client-owned document store, `doc.get`/`doc.set`: any JSON up to 1 MiB, optimistic concurrency by version, persisted atomically, emitting a doc event (`herdr-core/crates/herdr-core/src/api/doc.rs:4-39`)

  Core has no hook or plugin runner at all. A builder asked whether `hc events` is "the intended integration point, or is running a command on status … planned?" (herdrdev/herdr#5684); it is unanswered.
- **Templates** (`herdr-core/docs/templates.md`). One Markdown file per role in `~/.config/herdr-core/templates/<name>.md`. A tiny line-based frontmatter carries `command` (required), `description`, `ready` (default: wait for the first OSC 7501 report; `quiet` waits for output to settle instead), `submit`, `stop` and `paste_gap_ms`. The body is the opening instruction, and core appends the task. Files are read fresh on each use. Usage: `hc run --bg --name review reviewer "Review src/x.rs"`.
- **Machines and `via`** (`herdr-core/docs/machines.md`). `hc machine add user@host` reaches a host over SSH, copying `hc` there if it is missing. `--via '<cmd>'` uses any local command that carries stdin and stdout unchanged and receives the remote shell line as its last argument: `ssh -p …`, `fly ssh console …`. `--temp` marks a short-lived sandbox machine. `docs/via/vercel-sandbox.py` is the worked example: a 70-line Python shim that turns Vercel's `sandbox exec -i` into a clean byte pipe. Remote terminals are addressed as `box/t3`, and the local core merges terminal lists and events across machines.

### 3. Why the split, and what lives where

**What the maintainers say.** The FAQ describes rather than explains: "Herdr TUI is the original Herdr: a terminal app with its own server. The desktop app is a new, separate program built on herdr-core … They don't share agents" (herdr.dev FAQ). The maintainer on herdrdev/herdr-app#63: "they're separate on purpose: the app is built on herdr-core, the tui has its own server … whether the tui moves onto herdr-core later is still open." The welcome screen says: "This is a new app on a new core. Your herdr workspaces stay where they are; nothing moves over" (`herdr-app/defaults/frame/welcome/main.js:274-276`). `herdr-core/AGENTS.md` says "Fresh code. Do not copy from Herdr 1 … Read it for ideas, lessons and edge cases." I found no announcement or issue that states the motivation outright.

**The rationale the record supports.** This is my inference; each point has evidence:

- *Status by protocol, not by guessing.* The TUI's open bug list is dominated by detection misclassification across vendors (herdrdev/herdr#5146, #4143, #4511, #4214) and the cost of polling (#3217, #5289, #5194). Core drops detection, and the app shows an agent only if it emits OSC 7501. That costs coverage: Cursor CLI and some Claude Code launches do not appear (herdrdev/herdr-app#98, herdrdev/herdr-app#158).
- *Every client should be equal.* The TUI's client protocol was private. herdr-gpui (1,985★) vendors the TUI's bincode client protocol over `herdr-client.sock` ("vendored parts of herdr-protocol", `penso/herdr-gpui` README). herdrm forwards sockets over `ssh -L` and uses `herdr agent attach`. herdr-core publishes its attach protocol as OpenRPC plus framing, and its page says "The Herdr app is one client. The same API is open to yours" (herdr.dev/core).
- *Runtime survives the client.* Holders let a core update keep programs running, and the app updates beside the running one.
- *Customization by agents editing files, not by a plugin ABI.* The herdr.dev pitch: "Made for your agents. Remade by them … Every pixel is a file your agent can change … No plugin system, no fork to maintain. You ask, it edits."

**What lives in core:** terminals and holders, OSC 7501 status, labels, events, parent and child relations and notes, templates, machines, remote exec and files, client documents, the schema, and the updater.

**What lives in the app:** spaces, tabs and splits (stored as the `herdr-app` document in each machine's core, so connected screens share structure but keep their own focus and zoom), layouts, mods, `keys.json`, `settings.json`, `programs.json` (the icon and name table plus `run` entries for the + menu), the agents sidebar, worktrees (a shipped mod), the Changes and Files panels, updates and telemetry.

**Adoption by label.** "A terminal with those labels shows up there, even one you start yourself: `hc run --keep --label herdr.space=<id> --label herdr.tab=<id> -- claude`" (`herdr-app/defaults/AGENTS.md` "The model"). External dispatchers can create work the window shows, but cannot name a space from outside (herdrdev/herdr-app#43).

**How third-party clients connect:**

- herdr-gpui uses the TUI's private binary client socket.
- herdrm uses `herdr agent/terminal attach` over forwarded sockets.
- herdr-web, ovis and collie use the TUI's JSON socket API (`session.snapshot` plus `events.subscribe` plus `pane.send_*`).
- herdr-client (Go) is generated from `herdr api schema` (herdrdev/herdr#3938).
- Shepherdr is "a standalone herdr-core client" and reads Claude and Codex chats "from their own logs".
- Nenu is being ported from Herdr 1 to core (herdrdev/herdr-app#43).

### 4. herdr-app mods, and how they differ from plugins

**The governing rule.** `herdr-app/AGENTS.md:15-30`, "Before you grow the app's core: ask [the maintainer]", asks three questions:

1. Does the app itself act on it?
2. Can only the app see it?
3. Can mods not do it correctly, even with care?

"If all three are no, it belongs in mods … even at the price of some repetition." This is an independent rediscovery of TBD's "Compile only what user-land cannot do well", applied to UI.

**What a mod is.** A folder `~/.config/herdr-app/mods/<name>/` with `main.js` (a default-exported `View` class) and `mod.json` (placement only). It is in-process JavaScript (a shared QuickJS context, per herdrdev/herdr-app#88) that *describes* native GPUI elements through `gpui-kit`; "There's no DOM: the script describes, Rust draws" (`herdr-app/defaults/AGENTS.md:39-47`). It hot-reloads on save. A broken save keeps the last good build and reports the error in `herdr-app status`.

**What a mod can do.** Panels, pane headers, menus (`"terminal_menu": "my-menu"` replaces the right-click menu wholesale), dialogs, popups, floating draggable windows, edge drawers, and a live terminal inside a block. Through the `herdr` module it can:

- read live data: `spaces()`, `agents()`, `terminals()`, `panes()`, `focused()`, `theme()`, `commands()`
- run any app command: `run(cmd, args)`
- run programs on any machine: `exec(cmd, args, {cwd, on})`, `hc(args)`
- `fetch`
- read files anywhere, and write them under the app home
- watch folders
- keep state: `shared()`/`setShared()` across mods, `localStorage` per copy, `data/`
- receive key commands routed to it (`keys.json` `"<mod>.<command>"`)
- post toasts that run a command when clicked

**The whole shipped UI is mods:** `spaces`, `agents`, `tabs`, `menu`, `prompt`, `confirm`, `toast`, `worktree`, `changes`, `files`, `peek`, `picker`. "Nothing in the default interface is special" (`defaults/AGENTS.md:1-16`).

**How mods differ from TUI plugins:**

- *Process model.* Plugins are out-of-process argv commands that talk over the socket. Mods are in-process scripts with direct data access.
- *UI power.* Plugins get terminal panes, tokens and agent-view queries. Mods can draw anything native and replace any shipped piece.
- *Packaging.* Plugins have a TOML manifest, a build step, an install command, a registry, managed checkouts and a marketplace. Mods have none of that. Sharing is a folder with `RECIPE.md` (a brief from which "another agent with an empty folder builds the layout or mod") and `preview.png`, tagged `herdr-mod` or `herdr-layout`, and listed at herdr.dev/mods within the hour. Installing one means *the user's agent* reads every file, warns about network, exec or out-of-folder reads, copies without overwriting (renaming on clash), merges `keys.json` snippets, and runs `herdr-app check` (`defaults/AGENTS.md:410-463`).
- *Trust.* Both are unsandboxed. Plugins show a mechanical install preview. Mods rely on "your agent reads every file before it adds one" (herdr.dev/mods). Community preview images are screened, with a 24-hour wait.
- *Verification for agents.* `herdr-app check <mod>` renders once and exits non-zero on error. `herdr-app shot` saves a PNG of the last frame, needing no screen-recording permission. `herdr-app --skill` prints the window manual. `defaults/AGENTS.md` and the `.d.ts` files are rewritten into the app home on every start, and `cargo test` checks that the guide names every command and every `settings.json` key (`herdr-app/AGENTS.md` "The guide users' agents read").
- *Ecosystem maturity.* At the time of research herdr.dev/mods lists only one mod (`tmux-prefix`), and the layouts gallery holds 7 agent-made examples (`herdr-layout-examples`). The app is one week old.

**The cost the record already shows.**

- *Composition.* A standalone mod cannot add a button to the shipped Spaces header without cloning the layout and the sidebar mod. A clone never receives updates (herdrdev/herdr-app#106).
- *Machine sync.* Mod state does not travel with the machine (herdrdev/herdr-app#38).
- *Hot-reload leak.* Old generations accumulate in QuickJS, and after about 85 saves renders take 0.4 to 1.4 s (herdrdev/herdr-app#88).
- *Battery.* "Every redraw of a mod redraws the whole window", so animation must be native (`defaults/AGENTS.md` "A mod" rules).

### 5. Layouts and config

**App layouts** (`defaults/AGENTS.md:165-408`):

- One JSON file per whole window. A tree of `block | row | column | stack` nodes. Block content is `{mod, props}`, `{terminal: "t7"}`, `{tab: "active"}` or `{agent: "focused"}`.
- Sizing by px or weight, with min and max. The look (theme, colors, fonts, padding) cascades from the root.
- Pane frames, including per-pane header mods with `reveal: "hover"`.
- Floating blocks, including `peek` drawers.
- `titlebar: "none"` plus `traffic_lights`.
- Clicks (sizes, hidden state, floating positions) persist separately in `layouts/.state/`, so a layout file stays a clean authored artifact and "a deliberate layout-file edit beats a click on that field."

**Shipped versus personal files:**

- Shipped layouts and mods are read-only and replaced whole on every start.
- Editing one anyway gets it moved to `<name>-edited` on the next start, Herdr's version restored, and a toast shown.
- `layout.clone` and `mod.clone` record `cloned_from: {name, version}`.
- `keys.json` is installed only when missing, "so a changed default key never reaches existing users by itself" (`herdr-app/AGENTS.md:49-50`). This is the default-flip problem TBD's NULL third state solves for DB flags.

**Safety:**

- `ctrl-alt-shift-escape` can never be rebound. It sets the current layout and `keys.json` aside and returns to `main`.
- An invalid file keeps the last good version and writes a `<name>.error` file next to it.

**App config.** `settings.json` covers "the person, never a look": zoom, sounds, the core binary, the macOS Option key, contrast, clipboard, telemetry. `keys.json` has sections `global`, `layout:<name>`, `terminal` and `mod:<name>`, and actions can be `send:<text>`. Everything applies live within about a second, and Settings edits the same files.

**TUI layouts.** No layout files. `layout.export` and `layout.apply` take a BSP tree, and plugins fill the gap: `yuk1ty/herdr-spreader` builds layouts from YAML (143★), and herdr-plus "Projects" are workspace templates (369★).

**TUI config.** `~/.config/herdr/config.toml`, reloaded with `herdr server reload-config`. An invalid value falls back to a safe default with a startup warning. Presentation comes from the client's local config, while panes, worktrees, integrations and custom commands come from the server (`configuration.mdx:41-53`). There is no per-project config file. The sidebar row config grew a styling-rule grammar: up to 16 rules per token with `equals/contains/starts_with/gt/lt`, `ignore_case`, `hide` and `rows_by_agent` overrides. The docs bound it: "regex, fuzzy matching, and scripts are not supported" (`configuration.mdx:362-480`). Herdr 2 replaced that grammar with code (mods).

---

## (b) Ecosystem map

**Scale.** The marketplace index lists 1,982 plugins in 1,923 repos (GitHub topic total 1,990). By the index's `firstSeenAt`, 855 repos appeared in August, 526 in September and 542 in October (the index began in August; plugins shipped June 15). Stars:

- 36 repos have 100 or more
- 102 have 20 or more
- 317 have 5 or more
- 841 have none

Languages: Rust 433, Python 419, Shell 368, JavaScript 257, Go 209, TypeScript 173. `awesome-herdr` (278★) indexes about 2,090 projects in 49 subsections. Many long-tail repos look agent-generated and near-duplicate (for example several separate `herdr-hunk` integrations). Treat stars, not counts, as the demand signal.

Keyword counts over name plus description (overlapping, approximate):

- status, sidebar, radar or attention: 366
- navigation or picker: 190
- worktree: 130
- review or diff: 120
- remote, phone, web or chat: 114
- usage, quota or tokens: 104
- tasks, kanban or issues: 101
- notifications or sound: 86
- naming or titles: 58
- session search or resume: 57
- hibernate or idle: 54
- layout bootstrap: 45

Grouped by what users built. Each group lists what TBD already has, if anything:

1. **Remote, phone and chat control.** The highest-starred category.
   - Projects: `devswha/ovis` (1,681★, browser and phone client with chat and live terminal), `AltanS/collie` (1,514★, self-hosted PWA), `eliasstravik/shepherdr` (1,036★, herdr-core client on a tailnet with a per-space coordinator chat, tasks and diffs), `ZingerLittleBee/Heeler` (703★, native iOS over SSH), `dcolinmorgan/herdr-remote` (438★, menu bar, phone and Telegram, one-tap approvals, daily digest), `0cv/herdr-mobile-relay` (331★), `arronKler/pairfob` (181★), `permgps/herdr-telegram-agents` (84★), and a Slack approvals bot (herdrdev/herdr#4941).
   - Surfaces used: `session.snapshot` plus `events.subscribe`, `pane.read`, `agent prompt` and `send-keys`. herdr-remote is one manifest line: `[[events]] on = "pane.agent_status_changed"`.
   - Trust lesson: herdr-mobile-relay 0.20.0 had to replace a shared relay key with per-device credentials and an encrypted transport, a breaking re-pair. The security boundary moved into third-party code.
   - TBD today: nothing comparable. TBD has deep links and the https redirector, macOS notifications, and machine-interface prompt answering (`prompt.answer`, `Sources/TBDShared/RPCProtocol.swift:257`), but no documented remote surface.
2. **Diff review that sends comments back to the agent.**
   - Projects: `persiyanov/herdr-reviewr` (959★), `plannotator/herdr-annotate` (724★, annotate terminal text, docs and agent replies, then send the feedback back), `jhochenbaum/herdr-hunk-diff` (148★), `quantk/herdr-review`, and `cevr/herdr-hunk` (routes Hunk notes to the right pane). awesome-herdr has 30 entries in this section. herdr-app ships a `changes` panel by default.
   - reviewr's surfaces: an `[[events]] on = "worktree.created"` and `worktree.opened` auto-open, a `split` pane, status events for a "last turn" diff scope, and send through pane input. It "refuses one at a permission prompt" and "never sends on its own".
   - TBD today: none. TBD has a file viewer panel (`Sources/TBDApp/FileViewer/FileViewerPanel.swift`), a transcript composer and `tbd terminal send`, but no diff panel and no comment-to-agent flow.
3. **Attention radar, sidebar enrichment and status HUDs.**
   - Projects: `hhdebb/herdr-radar` (202★, writes only display tokens, plus a resident daemon woken by the event stream and an `agent.view`), `alexarthurs/herdr-sidebar` (525★, VS Code-style files and git pane), `robbyrussell/herdr-ohmyzsh` (85★, slow commands in the sidebar), `kay-ws/herdr-island`, `natori-hrj/herdr-triage`, and herdr-tower (herdrdev/herdr#5642).
   - Authors repeatedly asked for a persistent widget surface and were turned away: a sidebar placement for plugin panes (herdrdev/herdr#4312), non-focusable widget spaces and per-space rows (herdrdev/herdr#5420), and a "server-rendered sections" proposal from someone who forked to build it (herdrdev/herdr#1608).
   - TBD today: compiled. Activity state, awaiting-input amber, program status rows (`Sources/TBDApp/Sidebar/ProgramStatusRowPresentation.swift`), the pinned dock, the Cmd-K jump menu and the status bar. There is no user-land slot on a row.
4. **Worktree automation.**
   - Projects: `devashish2203/herdr-worktrunk` (193★), `tdi/herdr-worktree-setup` (setup on `worktree.created`), `StructuPath/herdr-swarm`, `tomoasleep/herdr-symphony`. Users also asked for a pre-remove teardown hook (herdrdev/herdr#3849).
   - TBD today: compiled lifecycle plus `preSession`, `setup` and `archive` hooks with a five-level priority chain. `archive` runs *before* `git worktree remove`, which is exactly the hook herdr#3849 lacked (`docs/worktree-hooks.md`).
5. **Task boards and dispatch.**
   - Projects: `nelsonPires5/herdr-board` (186★, kanban cards as prompts dispatched to agents in visible panes), `smarzban/tsk` (242★), `bredebjorhovd/herdr-board` (issues to panes to PR review), and the `herdr-layout-examples/board` and `threads` layouts.
   - TBD today: `tbd worktree create --prompt/--prompt-file`, queued prompts (`worktree.setPendingPrompt`), PR binding and auto-archive on merge. A board is buildable in user-land today with the CLI.
6. **Navigation, pickers and auto-titles.**
   - Projects: `thanhdat77/herdr-navigator` (187★), `jeffarese/herdr-bar` (182★, Cmd-K plus auto tab titles), `kryptamine/herdr-auto-title` (279★), `qu8n/herdr-automatic-rename` (227★).
   - TBD today: compiled. Cmd-K jump menu, back and forward history, rename prompt, session title sync, `AutoTabLabelResolver`.
7. **Editors, file viewers and browser panes.**
   - Projects: `zenbu-labs/terminal-browser` (4,351★), `terminal-code` (2,219★), `smarzban/herdr-file-viewer` (693★), `ChmaraX/herdr-nvim` (316★), `ogulcancelik/herdr-browser` (Chromium in a pane over CDP).
   - TBD today: native webview, code viewer and note panels, plus the CLI `tbd panel open --file/--url/--transcript/--note` (`Sources/TBDCLI/Commands/PanelCommands.swift:370-392`).
8. **Usage, quota and account management.**
   - Projects: `uwuclxdy/clauth` (282★), herdr-agent-usage, OmniRoute quota rings (herdrdev/herdr#4312, #5400).
   - TBD today: compiled. Model profiles, usage polling, account load balancing.
9. **Session search, resume and hibernation.**
   - Projects: `nicosuave/memex` (297★), herdr-transcripts, herdr-agent-hibernate (herdrdev/herdr#4724), herdr-session-parker.
   - TBD today: compiled. History pane, `terminalHistory.revive`, and hibernation with park guards.
10. **Orchestration and multi-agent teams.** This is awesome-herdr's largest section (855 projects), including stampede, Council, herdr-fleet and herdr-orchestrator.
    - Surfaces used: `agent start`, `agent prompt --wait`, `agent wait --until blocked` and `pane split`.
    - TBD today: CLI worktree and terminal create, `tbd terminal send`, cross-session messaging (`docs/cross-session-messaging.md`), and the agent-start admission gate.
11. **Third-party native clients.**
    - Projects: herdr-gpui (1,985★, also adds "Teleport" a worktree to another host, checkpoints, and a review tab), herdrm (783★), Honjin, Bordr, Kelpie (iOS).
    - These exist because herdr's runtime and UI were separable. TBD's app is its only client.

Which surfaces made the ecosystem possible, ranked by how often the top projects lean on them:

1. the full CLI and socket as the API, with JSON on stdout
2. `events.subscribe` and `pane.agent_status_changed`
3. `session.snapshot`
4. pane input and read (`agent prompt`, `send-keys`, `pane read`)
5. terminal panes (`split`, `popup`, `overlay`)
6. sidebar metadata tokens
7. `worktree.created` event hooks
8. link handlers
9. `agent.view.set`

The manifest itself mostly packages these; very few top projects need anything a script with the CLI could not do. The recurring walls were three: a persistent non-terminal UI surface, contribution points in shipped UI (menus and headers), and cross-machine aggregate views.

---

## (c) Ranked ideas for TBD

Each idea is checked against "Compile only what user-land cannot do well" (`CLAUDE.md:75-77`) and the battery in `docs/theory-placement.md`. Per `CLAUDE.md` "Work starts with a brainstormed spec", any of these that is more than a bug fix needs a human-answered `/tbd-brainstorming` spec. This list is input for a human, not originated feature work.

### 1. A public, documented event stream for user-land (`tbd events`)

- **TBD now.** The daemon already pushes `StateDelta` to the app over `state.subscribe` (`Sources/TBDShared/RPCProtocol.swift:174`). The cases include worktree created, archived and revived; terminal created and removed; activity, awaiting-input, program-status and pending-prompt changes; notifications; and dev servers (`Sources/TBDShared/StateDelta.swift:7-87`). No CLI command exposes it: the only "subscribers" in `Sources/TBDCLI` are remote reconnect counts. The only user-land event hooks are the three worktree lifecycle hooks (`Sources/TBDShared/HookResolver.swift:9-14`; `preMerge` and `postMerge` are declared there but have no caller). A script that wants "tell me when any agent is waiting on me" must poll `tbd terminal list --json`.
- **herdr.** `events.subscribe` with typed filters; `hc events --terminal/--children-of/--label`, one JSON line per event; `[[events]]` hooks for low-volume events; and explicit overrun semantics (`events_lost`, close, then resubscribe and reconcile against a snapshot). herdr-remote, herdr-radar, reviewr, herdr-mirror and every phone client are built on it.
- **Placement verdict: expose.** This is the purest case of the rule. Events are facts and carry no theory. A stream plus a snapshot is exactly what lets user-land own every "when this happens, do that" policy, and it is the precondition for most ideas below. What stays compiled is ordering, bounded retention and an honest overrun signal. herdr's "drop the connection rather than silently skip" contract is worth copying verbatim.
- **Decline herdr's per-event `[[events]]` process hooks.** Spawning a process per status flip is the per-event fleet cost the rule names. herdr-radar's manifest records the failure in place: its event hook is "a WATCHDOG, not the wake mechanism … without paying a node spawn on every status flip". A resident subscriber is the right shape.
- **Reclaimer question.** Resident watcher processes are durable resources nobody owns. herdr punts on this ("Plugins must stop detached background processes"). If TBD ever launches subscribers itself (from a startup hook), the named-reconciler doctrine applies. If users launch them, TBD owns nothing.

### 2. Publish the RPC contract as a versioned, checked schema

- **TBD now.** `Sources/TBDShared/RPCProtocol.swift` is an internal Swift surface. CLI `--json` output is ad hoc per command. The remote provider contract (`docs/remote-provider-contract.md`) is the one externally versioned TBD contract, with `describe`, capabilities and `TBD_CONTRACT_VERSION`.
- **herdr.** `herdr api schema --json` prints JSON Schema for requests, responses, errors and events. herdr-core goes further: OpenRPC generated from the same types as the CLI, a checked-in `released.openrpc.json`, and a test that fails on any client-breaking change ("The API only grows"). A Go client was generated from the schema (herdrdev/herdr#3938). herdr-gpui had to vendor the TUI's private client protocol because nothing better was offered.
- **Placement verdict: compile the contract, not behavior.** Integrity of the interface is mechanism. It turns ideas 1 and 3 into something third parties can build against without reading Swift. Learn from herdrdev/herdr-core#33 and decide up front whether CLI `--json` projections and behavior defaults are inside the promise.
- **Scope.** This is a doc and a test, not a feature flag.

### 3. User-reported display tokens on worktree and terminal rows (values only)

- **TBD now.** Row content is compiled (`Sources/TBDApp/Sidebar/WorktreeRowView.swift`, `ProgramStatusRowPresentation.swift`). The nearest user-land write surfaces are `tbd notify` and the dev-server running files, which already produce a sidebar green dot from a file (`docs/dev-servers.md`).
- **herdr.** `pane.report_metadata` and `workspace.report_metadata` set named tokens. Each report carries a `source`, an optional TTL and an optional `seq`; keys and values are capped; tokens are display-only and never feed waits or notifications; tokens are not restored after a restart. The user's row layout chooses which `$tokens` render. This one surface carries radar, CI and PR labels, slow-command indicators, model and summary chips, and quota gauges: the most-built category.
- **Placement verdict: expose the slot, keep the theory out.** "What is worth showing on a row" is a two-reasonable-projects question, so the token *values* belong in user-land. TBD would compile the slot, source scoping, caps and expiry. Those are mechanism: TTL is needed because a dead reporter must not leave a stale chip, which is the floor principle.
- **Decline the follow-on grammar.** Do not copy herdr's row-styling rules (`equals/contains/gt/lt`, `rows_by_agent`; `configuration.mdx:362-480`). That is battery test 5's "policy grammar" that TBD would have to version forever, and Herdr 2 abandoned it for code. Offer at most a fixed presentation per token: text, plus perhaps a single semantic tone.
- **Spec questions for a human.** Is this additive UI or a change to where existing items appear? Is the host the worktree row, the terminal tab label, or both? Does the token need a flag?

### 4. File-backed user actions in Cmd-K and context menus, plus user link handlers

- **TBD now.** The Cmd-K jump menu (`Sources/TBDApp/JumpMenu/`) and the context menus are fully compiled. There are no user-defined commands. Per-repo hooks run only on lifecycle events.
- **herdr.** In the TUI, `[[keys.command]]` binds a key to a `popup`, `pane`, `shell` or `plugin_action` command, with `HERDR_ACTIVE_WORKSPACE_ID/TAB_ID/PANE_ID/PANE_CWD` set. Plugin actions get `HERDR_PLUGIN_CONTEXT_JSON`, which includes selected text and clicked URL. `[[link_handlers]]` routes regex-matched URL clicks to actions; the PR and issue link-preview plugins and herdr-pickr rely on it. Users asked for plugin actions in right-click menus and were refused (herdrdev/herdr#5550). In the app, the command palette lists every command, and `keys.json` can send to mods.
- **Placement verdict: expose.** TBD would compile only the menu slot and a context environment: `TBD_WORKTREE_ID`, `TBD_TERMINAL_ID`, the selection, the clicked URL. The scripts are user-land, for example under `~/tbd/actions/` and `~/tbd/repos/<repoID>/actions/`, following the existing two-storage-patterns rule.
- **Smallest useful slice.** Scripts appearing in Cmd-K, run in a background tab like the "Re-run pre-session hook" entry already does.
- **Spec questions.** Do actions run in a visible terminal or headless? Does TBD show their output?

### 5. Diff review with comments sent back to the agent (a product candidate for a human to brainstorm)

- **TBD now.** None (see ecosystem group 2). Several building blocks exist:
  - the file viewer panel
  - the URL panel, which could host a local review web app opened with `tbd panel open --url`
  - `tbd terminal send`, with compiled single-typist and awaiting-input send gates (`Sources/TBDDaemon/Server/AwaitingInputSendGate.swift`)
  - `prompt.answer`
  - the transcript, which knows turn boundaries
- **herdr.** It never compiled this in the TUI; reviewr and annotate are plugins and are the second- and third-most-starred tool category. herdr-app ships `changes` as a default mod. reviewr's "last turn" scope depends on a fact herdr exposes (turn-start transitions).
- **Placement verdict: split it.** The *facts* user-land cannot reconstruct well should be compiled and exposed: the turn-start boundary, and the HEAD and working-tree snapshot at turn start. The *send* stays compiled because transport correctness is mechanism, and it must refuse at a permission prompt as reviewr does. Whether the review UI itself is native or a user-land web app on a URL panel is a product decision for a human. The rule leans toward exposing the facts first, so third-party reviewers can exist before TBD decides to own one.

### 6. A generated user-land guide for agents, test-enforced, plus recipes

- **TBD now.** Instructions reach agents through the session skill (`Sources/TBDShared/TBDSkillContent.swift:15`, written by `Sources/TBDDaemon/Lifecycle/PluginDirWriter.swift`). The editable files are spread across docs: `.worktree-hooks/`, `~/tbd/repos/<repoID>/{hooks,notes.md,claude-settings.json,servers.toml}`, `tbd.toml` (`Sources/TBDDaemon/Remote/RepoPeerMessagingSetting.swift:16-23`), `.claude/launch.json`, and `~/tbd/hooks/default/`.
- **herdr.** `defaults/AGENTS.md` is rewritten into the app home on every start: "This folder is the Herdr app's whole interface, as files." The type files ship beside it. `cargo test` fails if the guide misses a command or a settings key. `herdr-app check` and `herdr-app shot` let an agent verify its own work. `RECIPE.md` is the sharing unit: a prose brief another agent rebuilds from, so a share survives API drift ("If the files don't work on this version … build it from the recipe instead").
- **Placement verdict: pure user-land.** Every `TBDConstants` path helper (`Sources/TBDShared/Constants.swift:166-302`) should appear in one guide, for example `tbd guide` or a seeded `~/tbd/AGENTS.md`, with a test that enumerates the helpers. Recipes are a cheap convention for sharing hook scripts and any idea-4 actions.

### 7. Shipped defaults as content: replace whole, move edits aside, record lineage

- **TBD now.** `docs/theory-placement.md` "Content, not law" already prescribes "seeded exactly once into a project's ownership on a customize gesture, and never rewritten after". There is a global default hook directory, `~/tbd/hooks/default/`.
- **herdr.** Shipped files are replaced on start. Edited shipped files move to `<name>-edited` and a toast explains why. Clones record `cloned_from: {name, version}`. The cautionary half: `keys.json` is seeded once, so default changes never reach existing users.
- **Placement verdict.** If TBD ships reference scripts (any seeded hook or action), copy the `-edited` move and the `cloned_from` record. They make "the user changed our file" visible instead of silently overwriting it or silently freezing it. TBD's NULL-unset rule for DB flags is the better answer for anything settings-shaped. This only matters once there is shipped content, so it ranks low.

### 8. Agent templates as Markdown role files (low)

- **TBD now.** Per-repo `customInstructions` and rename prompt, `--prompt-file`, and model profiles. Claude Code's own agent files cover part of this.
- **herdr-core.** `templates/<name>.md`, where the frontmatter command plus body make the opening instruction. Read fresh on each use. Readiness waits for OSC 7501, a fact rather than screen text.
- **Placement verdict: user-land content with a compiled reader** (`tbd terminal create --template reviewer`). The marginal value over `--prompt-file` plus a profile is small, so file it only if users ask.

### 9. Free-form labels on terminals and worktrees (low)

- **herdr-core.** `hc label t3 k=v`, `hc events --label`, and app adoption by label (`herdr.space`/`herdr.tab`). The demand is external dispatchers that want to name or group what they created (herdrdev/herdr-app#43).
- **TBD.** The daemon owns spawn, for good reasons (profiles, environment, holders), so adoption by label is the wrong fit. A generic label map is a fact surface that pairs well with ideas 1 and 3, but it is not needed until something consumes it.

### Considered and declined

- **A manifest plugin system and a marketplace.** The pull is real: 1,982 plugins in about 4.5 months. But the evidence argues against it for TBD:
  - Nearly everything the top plugins do is reachable from a script given ideas 1 to 4. The manifest mainly *packages* existing CLI surfaces.
  - The packaging layer carries real operational cost. Leases and generations, Windows PATH and `.cmd` quirks, build toolchains (143 Rust and 64 Go repos of 595 needed a compiler, herdrdev/herdr#2693), a 1000-repo index cap, and dozens of plugin-runtime bug issues. One malformed manifest once hid every plugin (herdrdev/herdr#4312).
  - A manifest is versioned vocabulary forever (battery test 5).
  - Trust is unsolved. There is no sandbox. An automated audit flagged manifest path handling (herdrdev/herdr#961), and a supply-chain proposal argued acquisition, build and enable are not separated (herdrdev/herdr#2109). Both were closed by bot.
  - herdr's own maintainer dropped plugins in Herdr 2: "No plugin system, no fork to maintain. You ask, it edits."

  TBD already has the two extension shapes that matter: hooks and an executable contract with capability negotiation (`docs/remote-provider-contract.md`).
- **In-process scriptable UI (herdr-app mods).** It is the most radical application of the same placement rule, and it is what let herdr-app ship its whole UI as editable content. But it rewrites TBD's architecture (SwiftUI has no comparable describe-then-render seam). It moves the theory problem rather than removing it: contribution points are missing (herdrdev/herdr-app#106) and clones fork users off updates. And it is one week old with one community mod. Revisit only on field evidence. The URL panel already lets a user-land web app occupy a panel today.
- **A declarative agent-view or sidebar-rule grammar.** herdr's `agent.view.set` filter and sort DSL is defensible on per-render cost grounds, since it is re-evaluated on every fact change. Still, it is a policy grammar, and herdr-radar has to save and re-apply it on every startup because it is not durable. TBD's sidebar groups are compiled theory with a toggle. If users want custom triage, ideas 1 and 3 let them build it outside.

### Things herdr learned that TBD already has right

- **Pre-removal teardown.** TBD's `archive` hook runs before `git worktree remove`. herdr's `worktree.removed` fires after it, and the requested pre-remove hook was refused (herdrdev/herdr#3849).
- **Caller identity on the socket.** TBD reads `LOCAL_PEERPID` at accept and carries it as the only unforgeable fact for authorization (`Sources/TBDDaemon/Server/RPCConnectionContext.swift:1-25`, `SocketServer.swift:473`). herdr's TUI socket has no caller authorization, which allows a sandbox escape via `agent.start` and `pane.send_text`. That has been open since June as herdrdev/herdr#514, with community proxies that only let `report_agent_session` through. If TBD publishes ideas 1 and 3, consider a report-only, low-privilege path from day one.
- **Status by machine interface.** TBD's "No TUI screen-scraping" rule and its OSC 7501 reader (`Sources/TBDApp/AppState+ProgramStatus.swift`, behind `program_status_enabled`) match where herdr-core ended up after the TUI's detection churn.
- **Runtime surviving the client.** TBD's pty-holder transport is the analog of herdr-core's holders.
- **The placement rule itself.** herdr-app's three questions (`herdr-app/AGENTS.md:15-30`) are an independent derivation of `docs/theory-placement.md`. The useful difference is scope: herdr applied it to UI, TBD to daemon behavior.

---

## (d) Notable issues, PRs and discussions

**Plugin model and its walls (herdr TUI):**

- herdrdev/herdr#385, herdrdev/herdr#394 (discussions): per-project layout and worktree setup scripts closed as "a good candidate for a plugin"; built later as `tdi/herdr-worktree-setup`.
- herdrdev/herdr#1608: a proposal for a persistent, server-rendered plugin section in the sidebar, implemented in a fork; closed by bot.
- herdrdev/herdr#4312: sidebar placement for plugin panes (to show quota rings without opening 37 panes); also one invalid manifest blanked `plugin list` for all 14 plugins.
- herdrdev/herdr#5420: `rows_by_workspace` and non-focusable "widget spaces"; the author worked around a fake workspace with focus-bounce hooks.
- herdrdev/herdr#5550: plugin actions in right-click menus (`contexts` is declared but unused by the UI).
- herdrdev/herdr#5444: `herdr plugin exec`, because plugins cannot put a CLI on PATH and the install directory moved between releases.
- herdrdev/herdr#3603: parameters for plugin actions.
- herdrdev/herdr#1791: no uninstall hook; no way for a plugin to own a notification class (double notifications).
- herdrdev/herdr#3849: a pre-remove worktree hook for teardown (`docker compose down`).
- herdrdev/herdr#3820: client-level aggregate agents, events and focus across machines (hardware button-pad plugin).
- herdrdev/herdr#2693: prebuilt binaries for compiled plugins (143 Rust and 64 Go of 595 repos at the time).
- herdrdev/herdr#2470: post-install guidance message.
- herdrdev/herdr#3739: marketplace index truncated at GitHub's 1000-result cap; fixed by the maintainer.

**Trust and security debates:**

- herdrdev/herdr#514 (discussion, originally a bug): no caller authorization on the socket; sandbox escape via `agent.start` and `pane.send_text`. Proposals for a three-tier `SO_PEERCRED` scheme, an opt-in password, and a report-only proxy. The maintainer: "not a bug per se … need to triage". herdrdev/herdr#5025 (scoping a child agent's control) was folded into it.
- herdrdev/herdr#961: automated audit, "unvalidated plugin manifest path allows arbitrary file read"; closed by bot.
- herdrdev/herdr#2109: "Feature-preserving supply-chain hardening": updater checksums, remote agent manifests, and plugin acquisition, build and enable not separated; closed by bot.
- herdr-app `docs/security.md`: "Mods have your access … That is not a security boundary." Telemetry is on by default in the app (it was never on in the TUI).

**The split and Herdr 2:**

- herdrdev/herdr-app#63: TUI and app "separate on purpose"; convergence undecided.
- herdrdev/herdr-app#43: an external client (Nenu, ported from Herdr 1) asks whether reading the app's core document is supported and how to name spaces from outside; it quotes the three questions back.
- herdrdev/herdr-app#38: mod state syncing through each machine's document.
- herdrdev/herdr-app#106: no contribution points in shipped mods; cloning forks users off updates.
- herdrdev/herdr-app#88: QuickJS keeps every hot-reloaded generation; renders slow after about 85 saves.
- herdrdev/herdr-app#163 (no global hotkey for mods), herdrdev/herdr-app#64 (no environment control for `exec`): mod API gaps.
- herdrdev/herdr-app#98, herdrdev/herdr-app#158: agents without OSC 7501 (Cursor CLI, and Claude's background-session daemon hosting the TUI in its own pty) never appear.
- herdrdev/herdr-core#33: the "API only grows" check does not cover behavior defaults or CLI `--json` projections; prompted by a default flip in 0.1.13.
- herdrdev/herdr-core#25: a TUI client for herdr-core requested; herdrdev/herdr-core#15: carrying a resume reference in OSC 7501.
- herdrdev/herdr#5684: "Questions from building on Herdr Core": hooks or events, an approval primitive, focus and typing locks, per-parent notes, environment, label inheritance, TUI convergence, agents without 7501.

**Changelog milestones (`herdr/CHANGELOG.md`):**

- 0.7.0 (2026-06-15, lines 615-619): plugin v1 with link, list, enable and disable, actions, event hooks, panes, link handlers, logs and keybindings; GitHub install; config and state dirs.
- 0.7.4 (line 468): popup panes (herdrdev/herdr#1125).
- 0.7.5 (lines 421-426): plugins become global per user; `[[startup]]` hooks.
- 0.8.2 (line 265): marketplace discovers manifests in subdirectories.
- 0.9.4 (line 20): `plugin update` (PR herdrdev/herdr#4245). PR herdrdev/herdr#5212 merged "share cli and api command contracts", the TUI-side step toward core's one-table API.

**Show-and-tell signals (`herdrdev/herdr` discussions):**

- herdrdev/herdr#5642 herdr-tower, #5625 visor, #5523 herdr-tools (sidebar sorted per customer, self-naming tabs, macOS waiting-agent picker), #5504 stampede, #5353, #5331, #5218 and #4548 (phone and browser access without tunnels), #5315 herdr-fleet (one Claude splitting work across panes, each on its own account), #4724 herdr-agent-hibernate, #4246 herdr-agent-chat (delegation with a delivery guarantee), #3711 Herdr Tasks, #3607 Herdr Supervisor, #3351 herdr-web (its author asks about the marketplace).
