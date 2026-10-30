# herdr: session/process identity and agent state, and what TBD can take

*Researched 2026-10-30 as a read-only survey of the source of `herdrdev/herdr` at ee5bfb50 (2026-10-29), `herdrdev/herdr-core` at 9edb39d and `herdrdev/herdr-app` at 8180cbe, plus GitHub issues, PRs and discussions. It covers how herdr ties processes to a session or pane, how it tells which agent runs there, and how it derives agent state. Every herdr path below is relative to its repo root. The only thing executed was a ctypes probe, [`procenv_probe.py`](procenv_probe.py) in this folder; the measurement in section (b) was run directly on a macOS 27 development machine. [`README.md`](README.md) in this folder is the index and synthesis.*

## Short answer

- **The token-and-descendants design the question describes is real, but it lives in herdr-core (`hc`), not in herdr itself.** herdr-core mints a per-terminal `HC_SCOPE=<monotonic-timestamp>-<random-hex>`, scans every process's environment for it, then adds the transitive ppid descendants of every match. It uses that set for one thing: **ending everything a terminal started** (`crates/herdr-core/src/sweep.rs:1-4`).
- **herdr (the main product) does not identify a pane's processes by token on macOS or Linux.** It uses the pty's foreground process group (`e_tpgid` / `tcgetpgrp`). It mints a token (`HERDR_PANE_RUNTIME_ID`) only on Windows, only for Git Bash panes (`src/platform/windows.rs:1219-1232`). The `HERDR_PANE_ID` it injects goes the other way: the agent's own hook reads it from its *own* inherited env and tells herdr which pane it is in.
- **macOS does let you read another process's environment, with exceptions.** On the machine measured, `sysctl(KERN_PROCARGS2)` returned the full exec-time environment of most same-uid processes. Every Apple platform binary tested (`/bin/zsh`, `/bin/sleep`, `/usr/bin/perl`, `/System/...`) came back with argv but zero env entries. A few non-Apple apps did too: Dia, Chrome and Postgres.app (step 9 in section (b)). Postgres rewrites that region for its process title; the cause for the Chromium-based apps is unknown. `claude` (Developer ID, hardened runtime) is fully readable, including `TBD_TERMINAL_ID` / `TBD_WORKTREE_ID`. TBD's belief came from testing `/bin/sleep`, which happens to be one of the hidden cases. herdr-core's source states the same rule: "macOS hides the environment of its own binaries (an agent's `/bin/bash` tool shell), but not their parents" (`sweep.rs:95-97`).
- **herdr's agent state is screen-scraping first.** Claude Code, Codex and OpenCode state comes from regex manifests run over the rendered pane bottom and the OSC title. herdr tried hook-reported state for Claude in April–May 2026, hit gaps and races, and made the hooks session-identity-only on 2026-06-02 (`295b09ca`). Since then it has had 168 Claude state issues (38 open) and 13 changes to `claude.toml` in four months.

---

## (a) How herdr does it

### a1. What herdr puts in a pane's environment

All set in `apply_pane_launch_env` (`src/pane.rs:184-219`):

- **`HERDR_ENV=1`**: constant, not a token (`src/main.rs:3-4`). Used to block nested herdr launches (`src/main.rs:453-457`) and as a guard in every hook script.
- **`HERDR_SOCKET_PATH`** and **`HERDR_BIN_PATH`**: where hooks send reports (`src/integration/env.rs:26-31`).
- **`HERDR_WORKSPACE_ID`, `HERDR_TAB_ID`, `HERDR_PANE_ID`**: herdr's *stable internal* ids, not random tokens (`src/integration/env.rs:8-10`, `src/pane.rs:205-218`). #216 records an early bug where hooks used the positional public id (`w…-3`), which renumbers when panes close. The fix was to inject the internal `p_N` id instead. These ids are the pane's identity, persisted with the session, so they survive a herdr restart. `PaneLaunchIdentity::OmitPane` actively removes an inherited `HERDR_PANE_ID` for launches that must not claim one.
- **Scrubbed on spawn:** `CODEX_THREAD_ID`, `OMPCODE`, `CLAUDECODE`, `CLAUDE_CODE_CHILD_SESSION`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_MESSAGING_TOKEN` (`src/pane.rs:189-198`), "A new pane is not a child agent of the process that started the server". TBD hit the same leak (memory: "Daemon inherits launching Claude env").
- **`HERDR_PANE_RUNTIME_ID`**: Windows only, Git Bash only. Format `<herdr-pid-hex>-<nanos-hex>-<counter-hex>`, minted fresh on every spawn (`src/platform/windows.rs:1225-1232`). On every other platform `apply_pane_runtime_marker_platform` is an empty function (`src/platform/mod.rs:298-299`).
- **`HERDR_AGENT=<label>`**: never set by herdr. The *user* sets it on a sandbox wrapper (`HERDR_AGENT=claude nono run -- claude`) so herdr knows which manifest applies to a process it cannot otherwise recognise (docs: `docs/next/website/src/content/docs/agents.mdx`, "VMs and sandbox wrappers"). herdr reads it back from the foreground process's env, which is the one place herdr itself reads another process's env on macOS (below).

### a2. Pane to processes in herdr (main product)

- **macOS and Linux: foreground process group, not env.** Each detection pass:
  - reads `e_tpgid` (the controlling tty's foreground pgid) from `proc_pidinfo(PROC_PIDTBSDINFO)` on the pane shell pid (`src/platform/macos.rs:525-550`). The pty-fd variant uses `tcgetpgrp` (`:552-555`);
  - lists that group's members with `proc_listpids(PROC_PGRP_ONLY, pgid)` (`:494-522`);
  - reads each member's `comm`, its `argv[0]` (which reflects `process.title`), and its full argv via `KERN_PROCARGS2` (`:435-472`, `:561-643`).
  - Linux is the same shape over `/proc` (`src/platform/linux.rs:352-489`).
- **No descendant walk by default.** #3179 (an agent inside an nvim terminal, in a different pgid) was closed as by-design: walking descendant groups "can select background or helper processes". Linux has an opt-in `HERDR_PROCESS_DETECTION=child-groups` for runtimes with no tty foreground group (`linux.rs:36`, `:411-456`). It is documented as best-effort ("a newer background job can be mistaken for the foreground job"), and #5289 reports it costing nearly a full core.
- **Pid reuse:** start time in microseconds from `pbi_start_tvsec/usec` is the "start token" (`macos.rs:929-951`). `live_pane_process_group` also requires the process to share the shell's controlling tty (`e_tdev`), so a reused pid on another tty fails.
- **Whole-session enumeration, used for signalling:** `session_processes` scans *all* pids and keeps those whose `getsid()` equals the pane shell's session (`macos.rs:1126-1140`). Anything that called `setsid` falls out of this set.
- **Windows:** no job control, so herdr snapshots the process table, walks descendants of the pane shell, and picks the topmost agent in the chain. Git Bash (MSYS2) breaks Windows parent links across its `exec` emulation, so a Git Bash pane also accepts *escaped* agent processes, but only when they carry the shell's `HERDR_PANE_RUNTIME_ID` (`windows.rs:1848-1914`). Env is read through the PEB, capped at 256 KiB, with a 60 s positive cache and a 1 s negative TTL (`windows.rs:832-841`, `:2445-2512`). Added in `df2cb2c3` (#2170, 2026-08-01).
- **Cadence** (`src/pane.rs`):
  - detection tick: 300 ms once an agent is identified, 500 ms before (`:2851-2853`, `:975`);
  - foreground re-probe: every 5 s when identified, 30 s when there is no foreground group (`:413-415`);
  - an 8 s "acquisition window" after a new pgid appears, with 500 ms then 2 s rechecks (`:416-420`). #5191 is open because an agent that joins a stable pgid after 8 s is never identified.
- **Edge cases herdr just accepts:**
  - An escapee (`setsid`, double-fork, `nohup … & disown`) leaves the foreground group and is invisible to detection.
  - Processes of other users are not read.
  - On Linux, `/proc/<pid>/environ` is not read for processes in `D`/`Z`/`X` state, and under WSL not for agent-named processes (`linux.rs:757-799`). Reading another process's memory can block.

### a3. Pane to processes in herdr-core (`hc`): the token design

- **Token:** `HC_SCOPE=<mach_absolute_time>-<random hex>` (Linux: the lower of MONOTONIC and BOOTTIME, in clock ticks) (`crates/herdr-core/src/sweep.rs:9-58`).
  - It is minted per program run (`api/run.rs:196-207`). A recovery or replacement shell gets a fresh one (`kept.rs:85-86`).
  - It is persisted on the terminal record as `scope` (`terminals.rs:110-112`), so a restarted core can still sweep a dead terminal's leftovers.
  - It is stripped from the core's own base env before children are built, so a terminal never inherits an outer one (`api/run.rs:211-219`, `exec.rs:84-96`).
- **Self-exclusion:** hc's own processes carry `HC_RUNTIME=1` and have `HC_SCOPE` removed (`client.rs:180`). A sweep never takes them or anything beneath them (`sweep.rs:9-12`). Under systemd the holder unit gets `UnsetEnvironment=HC_SCOPE` (`platform/systemd.rs:374`).
- **Finding members** (`sweep.rs:93-130`):
  1. list all pids with their ppid and start time (`proc_listallpids` + `proc_pidinfo` + `proc_pid_rusage.ri_proc_start_abstime`, `:155-176`; `/proc/*/stat` on Linux);
  2. **skip every process that started before the token's timestamp**, since it cannot carry it (perf commit `cde3e41`, 2026-10-24). This also defeats pid reuse;
  3. read env via `KERN_PROCARGS2` or `/proc/<pid>/environ` (`:178-181`, `foreground.rs:123`);
  4. keep exact `HC_SCOPE=<token>` matches;
  5. **close over ppid descendants** of the matches. This is what catches `/bin/bash` tool shells, whose env macOS hides, as long as their parent shows the token.
- **Accepted gap**, stated in the module doc: "A process that both leaves the session and drops its environment escapes: accepted" (`sweep.rs:3`). A hidden-env platform binary reparented to launchd is also invisible, since it has neither a visible env nor a token-carrying parent.
- **Ending them:** SIGHUP, wait 500 ms, SIGTERM, wait 500 ms, SIGKILL, wait 2 s. Members are re-scanned before each step because they may fork (`sweep.rs:70-91`).
- **When it runs:**
  - when a holder is lost (`runtime.rs:540-548`);
  - for terminals stopped by a core restart (`runtime.rs:292-301`), which the code calls harmless to repeat;
  - when an exec ends (`exec.rs:296-312`).
- **Write-ahead intent for one-shot execs:** before spawning, the core writes an empty file `state/execs/<token>`. When the exec ends it sweeps and deletes the file. At core start, `sweep_leftovers` sweeps every token file a crashed core left behind (`exec.rs:98-116`, `:147-152`). This is a small, crash-safe named reconciler, matching TBD's doctrine.
- **Windows:** job objects instead ("nothing to hunt", `sweep.rs:60-68`).
- herdr-core does **no agent or state detection**. It reports raw foreground facts (pid, name, argv, cwd) about twice a second, and "clients name and draw programs themselves" (`foreground.rs:1-3`). Its first public commit is 2026-10-23, so there is no field history yet.

### a4. Which agent is in a pane (herdr)

- A **compiled-in name table**, not manifests: `lookup_agent` maps basenames such as `claude`/`claude-code`, `codex`, `opencode`, `muse-bin-<digits>` and so on (`src/detect/mod.rs:198-235`).
- `normalized_process_name` prefers `argv[0]` (so `process.title` wins) and unwraps runtimes: `node`/`bun` script args, `python -c`/`-m`, `sh -c`, the Hermes installer stub, Cursor's bundled node (`:381-440`, `:513-700`).
- Within a foreground job, the group leader wins; otherwise the best-scoring member does (`:254-292`).
- **Probe order** (`src/pane.rs:868-923`):
  1. `HERDR_AGENT` hint on the leader;
  2. leader name;
  3. the hint on the pgid;
  4. leader in the full job;
  5. the hint on non-leader members;
  6. any member.
- A manifest's `aliases` and remote updates can only patch rules for agents herdr already knows. "Adding a completely new agent still requires a Herdr binary update" (agents.mdx).
- Known misses: nix wrappers (`.claude-unwrapped`, #803), tmux inside a pane, agents in nested terminals (#3179), and late joiners (#5191).

### a5. Agent state: the signals and their precedence

1. **Screen manifests:** TOML rules per agent (`src/detect/manifests/*.toml`, 22 bundled), evaluated by priority over named regions. For Claude (`claude.toml`):
   - The **OSC title** is checked first. `osc_title_working` (priority 1100) matches `^[⠀-⣿◐-◓] `, braille up to CC 2.1.227 and half-circles from 2.1.228. `osc_title_idle` matches `^✳ `.
   - Then **rendered-line regexes**: `esc to interrupt`, spinner glyphs `* · ✢ ✳ ✶ ✻ ✽` followed by `…`, `Waiting for N background agents`, `N MCP tasks still running`, the `❯` prompt in the prompt box, `do you want to proceed?` with numbered `yes`/`no` options, `enter to confirm · esc to cancel`, and MCP elicitation `Accept`/`Decline`.
   - The **OSC progress** sequence `4;0` means idle.
   - When no rule matches a known agent, the fallback is `idle` ("default_known_agent_idle_fallback"). The docs warn that automation trusting a mistaken idle "can type into an approval dialog".
   - This is exactly what TBD's "No TUI screen-scraping" rule forbids.
2. **PTY activity** is "the normal working authority". The manifest's `visible_working` flag is diagnostic (`src/detect/mod.rs:36-39`). A working-to-plain-idle transition is held for up to 3 confirmations at 100 ms, capped at 700 ms, to stop flicker (`src/pane/agent_detection.rs:5-80`).
3. **Hook or plugin reports.** These are authoritative only for an allowlisted (source, agent) pair, `full_lifecycle_hook_authority`: pi, omp, mastracode, opencode, kilo, kimi (`src/detect/mod.rs:330-340`). For everyone else a reported state is accepted and then overwritten on the next 300 ms tick (#979, #5007). A visible blocker on screen overrides a non-blocked integration state.
4. **Session-identity-only integrations** (Claude, Codex, Hermes, Qwen, Letta, Antigravity) report only the agent session reference (`src/detect/mod.rs:342-350`).
5. **Self-reporting agents** (Command Code, Crush, Kiro, Muse, Prime Agent) call herdr's socket themselves. Because herdr cannot see their process, "the pane's shell returning to an idle prompt is the only sign that the agent exited" (`src/pane.rs:384-412`).
6. **Manifest updates:** the catalog is `curl`-fetched from `https://herdr.dev/agent-detection/index.toml` every 30 min (`src/detect/manifest_update.rs:15-17`, `:509-552`; `src/app/mod.rs:42`). Validation is parse-only plus `min_engine_version`; there is no signature. Results are cached in the state dir, and a local override in `~/.config/herdr/agent-detection/<agent>.toml` always wins. `herdr agent explain` prints the matched rule and the evidence.

**Why herdr abandoned hook state for Claude** (the history matters because TBD uses hook state):

- `28fb23cd` (2026-04-01) installed Claude hooks mapping `PreToolUse`/`PostToolUse`/`PostToolUseFailure`/`SubagentStop`/`UserPromptSubmit` to working, `PermissionRequest` to blocked, `Stop` to idle, and `SessionEnd` to release.
- Failures followed:
  - #125: an Esc interrupt fires `StopFailure`, not `Stop`, so the pane stays working forever;
  - #349: after a *rejected* permission prompt no further hook fires, so the pane stays blocked; after an approved one it stays blocked until the next event;
  - #198: a `PostToolUse` arriving after `Stop`, plus subagent events, re-pin working ("I'm suspecting claude code hooks having a race condition where PostToolUse arriving later than end");
  - #58 and `fb4e5a73`: subagent events make the parent look blocked or idle.
- `2939030c` and `f7b26a91` removed the post-tool and subagent mappings. Then `295b09ca` (2026-06-02) made the Claude, Codex and OpenCode hooks session-only. Its changelog says "Native state for those agents comes from Herdr's screen detection".
- The current Claude hook, v11 (`src/integration/assets/claude/herdr-agent-state.sh`):
  - installs only `SessionStart` with the matcher `^(startup|resume|clear|compact|fork)$` (`src/integration/claude_settings.rs:19`);
  - ignores subagent events (`agent_id` set) and Cursor-originated events;
  - sends `pane.report_agent_session {pane_id, session_id, transcript_path, session_start_source}` over the socket with a 0.5 s timeout, swallowing every failure;
  - is accompanied by a `HOOK_REMOVALS` list that deletes the old state hooks from users' settings (`claude_settings.rs:26-63`).

### a6. Integrations, the version marker, and resume

- **Install:**
  - Claude and similar agents: a hook script under the agent's config dir plus a JSONC-preserving edit of its settings file (`claude_settings.rs:65-97`, CST-based so formatting survives);
  - OpenCode, Kilo: a JS plugin;
  - Pi, OMP: a TS extension;
  - Hermes: a Python plugin.
  - Config dirs honour `CLAUDE_CONFIG_DIR`, `CODEX_HOME` and similar (`src/integration/env.rs`).
- **`HERDR_INTEGRATION_ID=<id>` / `HERDR_INTEGRATION_VERSION=<n>`** are comment lines inside each installed asset (`src/integration/mod.rs:283`; Claude is at 11, `:52`).
  - `herdr integration status` reads them back to flag outdated installs.
  - Native restore requires a minimum version, since older hooks do not report session refs.
  - It is a staleness marker for files herdr wrote into someone else's config tree, not a runtime env var.
- **Resume** (`src/agent_resume.rs`):
  - The session ref comes from the `SessionStart` report (`session_ref_from_report`, `:116`). For Codex there is an argv fallback that parses `codex resume <id>` (`:135-150`).
  - The ref is persisted in `session.json` and, on restore, mapped to an agent-specific argv (`plan`, `:199-300`): `claude --resume <id>`, `codex resume <id>`, `copilot --resume=<id>`, `opencode --session <id>` and so on. The argv is validated for size (`:58-90`).
  - A "first session wins" guard (#511) locks a pane's ref for the life of the foreground process. That guard turns a *wrong* first report into a sticky one (#4814, #2012).
- **Reporter attribution:** the server takes `pane_id` from request params. `LOCAL_PEERPID` is read only to *log* who stopped the server (`src/api/server.rs:491`, `src/platform/unix_common.rs:403-419`). Nothing checks that a reporter runs in the pane it names. #2012, open since 2026-07-29, is exactly this.

---

## (b) macOS env-read probe

Environment: macOS 27.0.1 (26A434), Darwin 27.0.0, SIP enabled, uid 501.

Probe: [`procenv_probe.py`](procenv_probe.py) in this folder, run with `python3 -I`.

- It calls `sysctl({CTL_KERN, KERN_PROCARGS2, pid})` with a `KERN_ARGMAX` buffer and parses `argc | exec_path | argv… | env…`. This is the call herdr and herdr-core use (`src/platform/macos.rs:609-643`, `:1069-1085`).
- It prints only the errno, argc, the env entry count, and the values of an allowlist of identity vars (`HERDR_PROBE`, `TBD_TERMINAL_ID`, `TBD_WORKTREE_ID`, …).
- `--scan` reads every pid and times it.

Results, in the order run. Every process I started was killed; the commands below show it.

1. **`/bin/sleep` started by me: argv yes, env hidden; `ps` agrees.**
   ```
   HERDR_PROBE=hello /bin/sleep 120 &   # pid 47709
   ps eww -p 47709      ->  47709 ?? SN 0:00.00 /bin/sleep 120
   ps -E -o command -p  ->  /bin/sleep 120
   probe                ->  pid 47709: OK exec=/bin/sleep argc=2 argv0='/bin/sleep' env_entries=0
   kill 47709
   ```
   This reproduces TBD's original 2026-08-05 observation exactly. The sysctl succeeds but the kernel omits the env.
2. **Self-read works:** a Python process reading its own pid sees `env_entries=112`, `HERDR_PROBE=self`, `TBD_TERMINAL_ID=<uuid>`, `TBD_WORKTREE_ID=<uuid>`.
3. **Other processes I own: readable unless the binary is an Apple platform binary.**
   ```
   HERDR_PROBE=brewpy   /opt/homebrew/bin/python3 -c 'sleep'  -> env_entries=112  HERDR_PROBE=brewpy   (adhoc-signed)
   HERDR_PROBE=brewbash /opt/homebrew/bin/bash -c 'read'      -> env_entries=111  HERDR_PROBE=brewbash (adhoc-signed)
   HERDR_PROBE=sysperl  /usr/bin/perl -e 'sleep 60'           -> env_entries=0    (com.apple.perl)
   HERDR_PROBE=syszsh   /bin/zsh -c 'sleep 60; :'             -> env_entries=0    (com.apple.zsh)
   kill all four
   ```
4. **Processes in other terminals (other TBD sessions), read without touching them:**
   ```
   pid 4867  exec=~/.local/bin/claude env_entries=101 TBD_TERMINAL_ID=<uuid> TBD_WORKTREE_ID=<uuid>
   pid 10197 exec=…/claude env_entries=99  TBD_TERMINAL_ID=<uuid> TBD_WORKTREE_ID=<uuid>
   pid 10336 exec=…/claude env_entries=99  TBD_TERMINAL_ID=<uuid> TBD_WORKTREE_ID=<uuid>
   pid 12437 exec=…/claude env_entries=99  TBD_TERMINAL_ID=<uuid> TBD_WORKTREE_ID=<uuid>
   pid 4863  TBDHolder env_entries=85 · pid 22182 TBDDaemon env_entries=96 · pid 24387 TBDApp env_entries=95
   pid 260 / 1330 / 42919  /bin/zsh (TBD terminal shells)  env_entries=0
   ```
   `claude` is `Developer ID Application: Anthropic PBC`, `flags=0x10000(runtime)`, so a hardened runtime does **not** hide env. TBD's own terminal shells (`/bin/zsh`) do hide it.
5. **Other users:** `pid 1 launchd`, `syslogd`, `fseventsd`, `mediaremoted` (uid 0) all fail with `errno=22 (Invalid argument)`, returning no argv either.
6. **Exec-time snapshot only:** a Homebrew Python started with `HERDR_PROBE=before`, which then sets `os.environ["HERDR_PROBE"]="after"` and `LATE_SETENV=1`, still reads `HERDR_PROBE=before` with no `LATE_SETENV`. A token cannot be changed by an in-process `setenv`; only a re-exec with a new env changes it.
7. **An escapee is found by token alone:**
   ```
   HERDR_PROBE=probe-<uuid> python3: fork; setsid(); fork; sleep 90     # grandchild pid 50725
   ps -o pid,ppid,pgid,tty  ->  50725  1  50724  ??       # reparented to launchd, own session, no tty
   probe --scan --want HERDR_PROBE
     pids=945 readable=738 total_bytes=2592034 elapsed_ms=152.4
     errno 22: 207 pids
     pids carrying HERDR_PROBE= : 1
       50725 …/Python HERDR_PROBE=probe-<uuid>
   kill 50725  ->  gone
   ```
8. **Cost:** four further full scans of about 945 pids took 93, 61, 33 and 36 ms in Python. Each allocates a 1 MiB buffer per pid and moves about 2.6 MB in total, so a native implementation with herdr-core's start-time pruning would be far cheaper.
9. **Where the blind spot is** (classifying all 737 readable pids by executable prefix):
   - **Empty env:** `/System/Library` 188, `/System/Applications` 41, `/usr/libexec` 40, `/bin/zsh` 30, `/bin/sleep` 12, `/usr/bin` 6, `/usr/sbin` 4.
   - **Also empty, but not Apple:** Dia 38, Chrome 33, Postgres.app 14, a few under `~`. Postgres is known to overwrite its argv/environ region for its process title, which would explain its case. I did not establish why the Chromium-based apps read empty.
   - **Non-empty:** `~` 162, `/opt/homebrew` 25, `/nix/store` 14, most third-party apps.
   - **Carriers of `TBD_TERMINAL_ID`:** 111 processes: `claude` 30, `node` 21, `pyright-langserver` 16, `cua-driver` 14, `bash` 5, `sleep` (not `/bin/sleep`) 5, `python` 4, `sourcekit-lsp` 3, `just`, `gh`, …
10. **`ps eww` is not the problem; `/bin/sleep` is.** For a readable process `ps eww` prints all 112 entries, including `HERDR_PROBE=pscheck`. TBD's test happened to use one of the hidden binaries.
11. **Inconclusive:** a copy of `/bin/sleep` placed in a temporary directory is SIGKILLed on launch (exit 137, AMFI). So "hidden because of SIP path" cannot be told apart from "hidden because of Apple platform signature" this way. Empirically the rule is: every Apple-signed system binary tested was hidden, every non-Apple binary of mine was visible except the region-rewriters. herdr-core's comment states the same rule. The xnu source was not checked.

**Live escapee census, from the same reads.** Ten processes with `ppid=1` currently carry a `TBD_WORKTREE_ID`. Joined read-only against `~/tbd/state.db`:

- **4 active worktrees:** `sleep` ×3, `node`, `cua-driver`, `dirmngr`, and one other application binary;
- **1 archived worktree:** `nix`, a 3-day-old `nix … print-dev-env`, which OrphanGC's archived-worktree criterion is meant to catch;
- **The main worktree:** two `claude` processes, `claude daemon run --json-path …` and `ClaudeCode.app/…/claude --bg-pty-host /tmp/cc-daemon-501/…`, the latter alive 9 days 22 hours. Both name a `TBD_TERMINAL_ID` whose terminal row still exists.

So env shows where a process *came from*, not who *owns* it now. A user-wide daemon (`dirmngr`, Claude Code's own daemon, Codex's app-server in herdr #4649) is tagged forever with whichever terminal happened to start it.

---

## (c) Ideas for TBD, ranked

1. **Correct the "macOS hides process env" premise wherever TBD relies on it.** Cheap, and it changes what TBD considers feasible.
   - **Where TBD states it now:**
     - `Sources/TBDDaemon/Tmux/TmuxManager.swift:984-985` ("macOS forbids reading another process's environment (SIP)");
     - `Sources/TBDPeerHelper/PeerHelperOptions.swift:11` ("macOS refuses `ps eww` for another process under SIP");
     - `docs/tmux-dependencies.md:250`;
     - `docs/specs/2026-08-18-orphan-process-gc-design.md:503-506`. That spec's rejected alternative "Identify by TBD ancestry fingerprint" rests partly on "macOS hides another process's environment, so an env-var marker cannot be read at all". Its own examples, `pnpm` (node) and `process-compose` (Go), are exactly the kind of binary whose env *is* readable.
   - **The accurate statement:** most same-uid binaries are readable through `KERN_PROCARGS2` (exec-time snapshot), including `claude`, `node` and `pnpm`; every Apple platform binary tested returns argv but no env, as do a few non-Apple apps (Dia, Chrome, Postgres.app); other uids fail with EINVAL.
   - **Why it helps:** several design choices (the tmux `pane_start_command` fallback, argv-borne helper identity, the cwd-only orphan rule) were chosen partly because env looked impossible. Some remain right for other reasons (forgeability, below), but the stated reason should be accurate.
   - **Rule notes:** the spec edit must restate the rejected-alternative rationale as current reasoning, with no "an earlier draft said" narrative (root `CLAUDE.md`, "Spec and doc edits"). The memory file is the user's to change.

2. **Use env markers as attribution evidence in OrphanGC's escaped-process collector (herdr-core's sweep design, adapted).**
   - **What TBD does now:** a process is a reclaim candidate when its `ppid == 1`, its `lsof` cwd lies under a TBD root, and the owning directory is positively dead (archived row or `.deleting/` entry) (`docs/specs/2026-08-18-orphan-process-gc-design.md:118-140`). An escapee that `cd`'d out of the worktree, or never had its cwd there (a dev server started with `--cwd`), is missed.
   - **What herdr-core does:** match a per-terminal token in env, then close over ppid descendants to cover hidden-env tool shells, pruning by start time ≥ token time.
   - **What TBD could do:** for `ppid == 1` processes, read `TBD_WORKTREE_ID` (and `TBD_TERMINAL_ID`) through `KERN_PROCARGS2`. Treat "the env names an archived worktree" as a second positive attribution alongside cwd. The live census above found exactly such a process (`nix`, archived worktree, 3 days old).
   - **Why it needs care:** env attests *origin*, not *ownership*. The same census shows `dirmngr` and Claude Code's own daemon tagged with arbitrary worktrees. An env-only rule would kill a user-wide daemon when the worktree that happened to start it is archived. Mitigations:
     - require env plus cwd, or env plus "no live non-archived terminal descends from it";
     - exclude processes that are themselves agent daemons;
     - keep the spec's archived-only rule.
   - **Blind spots to accept:** platform binaries (`/bin/sleep`, `/usr/bin/python3` stubs, `/bin/zsh`), region-rewriting processes, `env -i` launchers, other uids.
   - **Rules:** this kills processes, so per `CLAUDE.md` it needs a default-off `config` flag with no SQL default, a `/tbd-brainstorming` spec, and both branches tested. It strengthens an existing named reconciler (OrphanGC) rather than adding a new resource kind.
   - **It does not conflict with `HolderDescentIndex`'s "an environment variable is never consulted" rule** (`Sources/TBDShared/HolderDescentIndex.swift:42-46`). That rule protects a tab-identity join from forgery; GC attribution of an *already-escaped* process is a different question, and the spec must say so explicitly.

3. **Check the caller's process before attributing a hook event to the terminal its env names: herdr's open bug #2012, measured here.**
   - **What TBD does now:** `handleTerminalSessionEvent` (`Sources/TBDDaemon/Server/RPCRouter+TerminalHandlers.swift:5733`) takes no `RPCConnectionContext`. It attributes the event to the env-borne `TBD_TERMINAL_ID`, checks only that the hook's cwd belongs to the terminal (`hookCWDBelongsToTerminal`), and applies the incarnation CAS. TBD already owns the right tools: `RPCConnectionContext.peerPID` (`Server/RPCConnectionContext.swift`), `ProcessIdentity.ofPeer` (`Process/ProcessIdentity.swift`), and `HolderDescentIndex`. Today only envelope suppression uses them (`RPCRouter+TerminalHandlers.swift:5146-5152`).
   - **What herdr does:** nothing, which is why #2012, #4814 and #4649 are open. Codex's shared app-server, and Claude Code's `bg-spare` (in #2012), run hooks inside a daemon whose env names the first pane that started it. The SessionStart then binds a session to the wrong pane, or to a dead one. With herdr's first-session-wins rule, the wrong binding sticks.
   - **Evidence it applies to TBD:** on this machine `claude daemon run` and `claude --bg-pty-host` carry `TBD_TERMINAL_ID`s of terminal rows that still exist. If Claude Code fires TBD's overlay hooks inside those processes (unverified), TBD would attribute a background session to the wrong live terminal, and the cwd check would pass because the daemon's cwd is in the same worktree.
   - **Suggested check:** for `session-event` and `terminal-activity`, resolve the peer pid's ancestry. Accept only if it descends from the named terminal's job (holder) or pane pid (tmux), and record a refusal otherwise.
   - **Rules:** a behaviour change on a load-bearing path that refuses inputs, so flag-gated and spec'd.

4. **Steal herdr's hook-failure catalogue; do not steal its screen-scraping.**
   - **What TBD does now:** hook-driven `activityState` (`Sources/TBDDaemon/Hooks/ClaudeHookOverlay.swift`):
     - `UserPromptSubmit` and `PreToolUse` map to working;
     - `Notification` maps to `waiting_for_user`;
     - `Stop` and `StopFailure` map to idle (TBD already covers herdr #125);
     - `AskUserQuestion` Pre/Post map to waiting, then working.
     - The session mod's `turn.step` stream adds a richer machine channel.
   - **What herdr learned the hard way, worth a regression test each in TBD:**
     - no hook fires after a *rejected* permission prompt (#349);
     - a late `PostToolUse` arrives after `Stop` (#198);
     - subagent events (`agent_id` set) must not drive the parent's state (#58, `f7b26a91`);
     - `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` (#1630) silently kills title-based signals.
   - **The cost of the alternative, for the record:** herdr's own numbers make the case for TBD's rule. There are 168 Claude-state issues (38 open), and `claude.toml` changed 13 times between 2026-06-10 and 2026-10-13. Breakage tracks Claude Code releases:
     - spinner glyphs changed from braille to `◐◑◒◓` in 2.1.228 (#1630, #2707);
     - `✳` used both as a spinner frame and as the idle title (#4376, #3029: idle Claude detected as Codex);
     - a historical spinner above a completed turn (#4819);
     - agent prose containing "Would you like to … yes" read as blocked (#4064);
     - PreToolUse hooks running read as idle (#5466);
     - a selection dialog in panes under 50 columns read as idle (#2868);
     - OpenCode changing "esc to interrupt" to "esc interrupt" (#5365).

5. **A time-stamped, write-ahead incarnation token (herdr-core's `HC_SCOPE` shape).**
   - **What TBD does now:** `TBD_TERMINAL_INCARNATION_ID` is a UUID set for replacement agent processes (`Sources/TBDDaemon/Process/AgentProcessEnvironment.swift:23-31`). `HolderChildIdentity.startWindow` (`HolderDescentIndex.swift:22`) uses row anchors rather than the token itself.
   - **What herdr-core adds:**
     - a monotonic-clock prefix on the token, so any scan can skip every process older than it (fast, and immune to pid reuse);
     - the token written to a file *before* spawn and swept at startup if still present (`exec.rs:98-152`).
   - **Why it might help:** if idea 2 or 3 lands, scanning by token becomes the hot path, and pruning by start time is what keeps it cheap. The write-ahead file is a minimal intent record, consistent with "Every durable external resource needs a named reconciler".
   - **Why it might not:** TBD's DB row already is the intent record for terminals. This matters only if TBD starts one-shot execs outside terminal rows.

6. **Expose the pty's foreground process group as a machine fact.**
   - **What herdr does:** `tcgetpgrp` on the master, or `e_tpgid` from `proc_pidinfo`, plus `KERN_PROCARGS2` argv for "what is running in this pane now". herdr-core publishes it about twice a second.
   - **What TBD does now:** tmux's `paneCurrentCommand`/`panePID` (`ClaudeStateDetector`) on tmux. Holder rows have only `childPID`.
   - **Why it might help:** a holder already owns the master fd, so `tcgetpgrp` is one syscall. It distinguishes "agent foreground" from "shell foreground with agent backgrounded or exited" without scraping.
   - **Caveats from herdr's issues:** late joiners (#5191), nested terminals (#3179), tmux inside a pane, Ctrl+Z suspension handling.
   - **Rules:** fine under "No TUI screen-scraping"; this is process-table data.

7. **Low value or not applicable.**
   - **TTY `ECHO`-off as a generic "waiting for a secret" signal** (#4441, declined by herdr). Agent TUIs run in raw mode with ECHO off all the time, so it says nothing about agents; it helps only plain shell tabs.
   - **`HERDR_AGENT`-style wrapper hints.** TBD launches its agents and records `kind`, so it does not need them.
   - **The integration version marker.** TBD's overlay and plugin files are daemon-owned and rewritten byte-for-byte (`PluginDirWriter`), so staleness is already handled.
   - **Remote manifest updates.** Not applicable while TBD forbids scraping.
   - **OSC 7501 Program Status Protocol.** TBD already accepts it (`Sources/TBDDaemon/ProgramStatus/ProgramStatusStore.swift`, spec `2026-10-10-program-status-protocol-design.md`); herdr closed the request as out of scope (#5069).

---

## (d) Notable herdr issues and PRs

**Identity and env inheritance**

- herdrdev/herdr#2012 (open): `pane current` and `pane.report_agent_session` trust an inherited `HERDR_PANE_ID`. Includes the Claude Code `bg-spare` case: SessionStart fires in the daemon-spawned process with a dead pane's id, so the visible pane keeps a month-old session ref.
- herdrdev/herdr#4814 (open), #4649 (open, "waiting on upstream"), #4859: Codex's shared `app-server --managed-daemon` keeps the first pane's `HERDR_*` env for days and binds every thread's session to that pane, even across herdr servers.
- herdrdev/herdr#5373 (open): Hermes's gateway, where `HERDR_*` never reaches the hook process.
- herdrdev/herdr#5544 (open): OpenCode 2 shell commands get no `HERDR_PANE_ID`.
- herdrdev/herdr#216: the positional pane id went stale after a renumber; fixed by injecting the stable internal id.
- herdrdev/herdr#5078: native restore drops the `HERDR_AGENT` hint.
- PR/commit `df2cb2c3` (#2170): the Windows Git Bash runtime marker.

**Process detection**

- herdrdev/herdr#3179 (closed, by design): no descendant-group walk.
- herdrdev/herdr#5191 (open): agents that join after the 8 s acquisition window are never identified.
- herdrdev/herdr#803: nix-wrapped `.claude-unwrapped` is missed.
- herdrdev/herdr#5289: child-groups mode costs nearly a core.
- herdrdev/herdr#3217 (open): severe macOS lag with about 40 agents. The profile points at frame building, not detection.
- Commits `9aa50f04` (2026-03-27) "use KERN_PROCARGS2 for macOS process name resolution", `947328fa` (2026-07-16) "feat(macos): support agent environment hints".

**Hook state, abandoned for Claude**

- herdrdev/herdr#125: `StopFailure` on interrupt.
- herdrdev/herdr#349: no event after a rejected permission prompt.
- herdrdev/herdr#198: a late `PostToolUse` and subagent events re-pin working.
- herdrdev/herdr#58: subagents make the parent look blocked.
- herdrdev/herdr#979: hook reports overwritten by the next screen scan.
- herdrdev/herdr#5007 (open): `report_agent` acknowledged but ignored.
- Commits `2939030c`, `f7b26a91`, `295b09ca` ("make claude codex opencode hooks session-only").

**Screen scraping breakage (Claude unless noted)**

- herdrdev/herdr#1630: `CLAUDE_CODE_DISABLE_TERMINAL_TITLE`, and the braille-to-half-circle spinner change in CC 2.1.228.
- herdrdev/herdr#2707, #2760: half-circle frames.
- herdrdev/herdr#4376: `✳` as a spinner frame.
- herdrdev/herdr#3029: idle Claude detected as Codex.
- herdrdev/herdr#4819: a historical spinner overrides idle.
- herdrdev/herdr#3467: a stale busy title outranks a permission dialog.
- herdrdev/herdr#4626: an echoed spinner line reads as working.
- herdrdev/herdr#4064: agent prose reads as blocked.
- herdrdev/herdr#5466: running PreToolUse hooks read as idle.
- herdrdev/herdr#2868: narrow panes.
- herdrdev/herdr#2959: a suggested prompt reads as idle.
- herdrdev/herdr#4668: AskUserQuestion's "review your answers" screen.
- herdrdev/herdr#5146: conversational questions read as done.
- herdrdev/herdr#4564: non-agent output in the same pane keeps working.
- Other agents: #5365 (OpenCode copy change), #1208 (Amp footer), #3120 (Grok glyphs), #5336 (Hermes English-only UI), #5548 (Antigravity).

**Declined generic signals**

- herdrdev/herdr#5069: OSC 7501. TBD already has it.
- herdrdev/herdr#4441: TTY ECHO.
