# Release pipeline: build in CI, install the download — design (draft)

**Status: draft with open questions.** The repository owner has not answered
the questions in the last section yet. Nothing here is decided until they
have, and no implementation starts before that.

`tbd update` compiles the whole installation on the machine it updates. This
spec moves that compile to a GitHub Actions macOS runner. A workflow builds
the release configuration of every runtime product for a commit on `main` and
publishes the output as a release asset keyed by that commit. `tbd update`
then downloads and verifies the asset instead of building, and falls back to
the local build when no asset fits.

The design behind `tbd update` is
[`2026-09-04-automatic-version-updates-design.md`](2026-09-04-automatic-version-updates-design.md).
That spec lists "a release channel, tags, or signed downloadable builds" among
its non-goals, so "latest" there means a commit on `main`. This spec revises
that non-goal and nothing else. The commit is still the identity; a download
is another way to get that commit's binaries onto disk.

## 1. What is wrong today

- **An update competes with the fleet for one build slot.** `scripts/update.sh`
  builds all six runtime products through `scripts/swift-safe`. That wrapper
  serializes every Swift build on the machine and waits up to 1,800 s for the
  slot (`DEFAULT_TIMEOUT_SECONDS`). On a machine with active agent worktrees
  the slot is often busy. One developer machine's `~/tbd/updates/update.log`
  shows two of its last five update attempts ending at exactly that ceiling:
  `building TBDDaemon` at 17:17:57, then `ERROR: build of TBDDaemon failed` at
  17:47:58. Neither attempt compiled anything. The operator saw a 30-minute
  update that failed.
- **A build that does get the slot is still expensive.** A warm incremental
  release build in the same clone took about seven minutes, `TBDDaemon` alone
  246 s. A cold build is several times that. Release builds are
  whole-module-optimized, so their peak memory is the part that swaps a laptop
  already running dozens of agent sessions. That is the incident class
  (2026-08-01, swap exhaustion) `scripts/swift-safe` was written to prevent.
- **Every machine repeats the same work.** Each installation compiles the same
  commit, with the same compiler version (CI pins Xcode 26.6 / Swift 6.3.3),
  for the same architecture.

## 2. Goals and non-goals

Goals:

- One CI build per eligible commit on `main`, published where an unauthenticated
  `curl` can fetch it.
- `tbd update` can install that build with no local compile, and the
  installation it produces behaves the same as a locally built one: same
  bundle assembly, same local signing identity, same handover, same kept
  previous bundle, same build-identity reporting.
- The operator can check that a download is the artifact CI built from that
  commit.
- When no usable asset exists, the update degrades to something predictable
  and never installs a partial or unverified tree.

Non-goals:

- Notarization, a Developer ID signature, or a drag-to-install `.app` for people
  who have never built TBD. The installation still starts from a checkout.
- Semantic versions, a changelog, or release notes. The commit is still the
  version.
- Intel or universal binaries, unless Question 5 says otherwise.
- Changing the handover, the wake pacing, or anything after the install step.

## 3. What the updater's layout requires

Researching `update.sh`, `restart-bundle-lib.sh` and the app's daemon lookup
changed the ask in three ways.

- **`TBD.app` cannot be built in CI and shipped whole.** `assemble_app_bundle`
  writes the installing shell's `PATH` into `Contents/Info.plist`
  (`write_restart_environment_plist`); a login relaunch depends on that value.
  `sign_app_bundle` signs with a per-machine self-signed `TBD Dev Signing`
  identity, so that TCC decisions persist across rebuilds
  ([`docs/tcc-signing.md`](../tcc-signing.md)). A bundle signed anywhere else
  would bring back the endless consent prompts that document describes.
  `Contents/SourceWorktreePath.txt` names a local path. **So CI ships the
  build products, and the local updater assembles, signs and installs the
  bundle from them exactly as it does today.** The download replaces
  `build_products` and nothing downstream of it.
- **The daemon never lives in the bundle.** `update.sh` starts the successor
  from `<build_dir>/TBDDaemon`, and the daemon finds `TBDCLI`, `TBDHolder`,
  `TBDPeerHelper` and `TBDModelProxy` as siblings of its own binary. After a
  reboot, the app respawns a missing daemon from the first executable
  candidate `DaemonCandidateFinder` names: the app bundle's `MacOS/TBDDaemon`,
  then `<sourceWorktree>/.build/release/TBDDaemon`, then `.build/debug`. A
  downloaded daemon that sits anywhere else is invisible to that respawn, and
  the app would bring up whatever stale local build the update clone last
  produced. Section 4.4 places the download where that lookup finds it.
- **The update clone stays, and stays at the installed commit.**
  `sourceWorktree` in the build identity is what `tbd update` execs
  `scripts/update.sh` from. It is also where the daemon's update checker runs
  `git remote get-url`, `git merge-base --is-ancestor` and `git rev-list
  --count`. `assemble_app_bundle` reads `Resources/TBDApp.Info.plist` and
  `Resources/AppIcon.icns` from it. So the fetch and detach into
  `~/tbd/updates/src` keep running; only the compile goes away. Fetching is
  seconds; the compile is what costs.

Two further facts shape the artifact.

- **Resource bundles must travel with the binaries.** A release build dir holds
  `TBD_TBDApp.bundle`, `TBD_TBDDaemonLib.bundle` (SQL migrations),
  `SwiftTerm_SwiftTerm.bundle` (Metal shaders), `Highlightr_Highlightr.bundle`,
  `GRDB_GRDB.bundle` and `swift-nio_NIOPosix.bundle`. SwiftPM's generated
  `Bundle.module` accessor falls back to an absolute `.build` path baked in at
  compile time. On the machine that built the binary, that fallback hides a
  missing bundle. A CI-built binary is the first TBD binary to run on a
  machine that did not build it, so any consumer that relies on the fallback
  breaks there for the first time. `SQLMigrationLoader` avoids
  `Bundle.module` for exactly this reason. The TBDApp consumers
  (`MarkdownStylesheet`, the sidebar and content icons) do not, and must be
  checked against a relocated tree before this ships (section 7).
- **The six products all exist.** `RUNTIME_PRODUCTS` in
  `scripts/restart-bundle-lib.sh` is `TBDDaemon TBDApp TBDCLI TBDHolder
  TBDPeerHelper TBDModelProxy`, and each is an `executableTarget` in
  `Package.swift` (tools version 6.0, `platforms: [.macOS(.v15)]`). `TBDApp`
  links the committed `rust/comrak-ffi/lib/libcomrak_ffi.a`, so CI needs no
  Rust toolchain. Current release binaries total about 144 MB uncompressed,
  arm64 only.

## 4. Proposed design

### 4.1 The workflow

A new `.github/workflows/release.yml`, separate from `test.yml` so that the
test workflow's cache policy and concurrency stay untouched.

- **Trigger.** Question 2 decides between every push to `main` and only
  commits whose `test.yml` run on `main` passed (`workflow_run`). A
  `workflow_dispatch` input for a given commit exists either way, to backfill
  a missed build.
- **Runner and toolchain.** `macos-26`, `sudo xcode-select -s
  /Applications/Xcode_26.6.app`, the same pin `test.yml` uses. The manifest
  records the exact `swift --version`.
- **Concurrency.** `group: release-main`, `cancel-in-progress: true`. When
  `main` moves during a build, the build of the older commit is cancelled.
  Commits superseded that way get no asset, which is fine, because an update
  always wants the newest commit that has one (section 4.3).
- **Build.** One `swift build -c release --product <P>` per product, in
  `RUNTIME_PRODUCTS` order. CI calls SwiftPM directly, as `test.yml` already
  does; `scripts/swift-safe` governs a shared developer machine, not a
  single-tenant runner. `timeout-minutes` is set on the job, following the
  repository convention.
- **Cache.** None at first. The Actions cache store held 9.4 GB of its 10 GB
  when last measured. A release-configuration entry would evict the debug
  entries `test.yml` depends on. Measure the cold build duration first, then
  decide.
- **Package.** Stage the six executables and every `*.bundle` beside them,
  except `*Tests.bundle` (the same exclusion `assemble_app_bundle` applies),
  into `tbd-<commit>-macos-arm64/`. Add `manifest.json`: the full commit, the
  build time, the Swift and Xcode versions, the runner image, the run URL,
  the product list and a SHA-256 per file. Archive it as
  `tbd-<commit>-macos-arm64.tar.gz` and write
  `tbd-<commit>-macos-arm64.tar.gz.sha256` beside it.
- **Smoke test before publishing.** Run each helper with `--help` or
  `--version`. Start `TBDDaemon` against a scratch `TBD_HOME` long enough to
  run its migrations, from a copy of the staged directory at a path unrelated
  to the checkout. This catches the relocation failures of section 3 in CI
  rather than on a user's machine.
- **Attest** (Question 4). `actions/attest-build-provenance` over the tarball,
  which needs `id-token: write` and `attestations: write`.
- **Publish** (Question 3). Upload with `contents: write`, the only write
  scope the job holds. The workflow never runs on `pull_request` or
  `pull_request_target`, so no contributor-controlled code runs holding that
  token.

### 4.2 Asset naming and keying

The key is the full 40-character commit. It appears in the asset name, in
`manifest.json`, and in the checksum file. Only the tag differs between the
hosting options, and the recommended option (a single rolling prerelease,
Question 3) gives each asset a stable URL:

`https://github.com/<owner>/<repo>/releases/download/<tag>/tbd-<commit>-macos-arm64.tar.gz`

`update.sh` builds that URL from the remote it already resolves and the
commit it already fetched. The fetch needs no GitHub API call, so the 60
requests per hour allowed to unauthenticated API clients never comes into it.
Release-asset downloads are served from a CDN outside the API rate limit.

A remote that is a fork without this workflow gets a 404. That case behaves
exactly like "no asset yet" (Question 6).

### 4.3 The update path

`scripts/update.sh` gains a source step between `fetch_latest` and the
install. Its default is Question 1.

1. Fetch and detach the clone onto `origin/main`, as today, then read the head
   commit.
2. **Choose the target commit.** When the head has an asset, the target is the
   head. When it has none, walk back along `main`'s first-parent history, at
   most a small constant number of commits (set at the top of the script), and
   take the newest commit that has one. When none does, apply the fallback
   (Question 6). Detach the clone onto the target commit, so the scripts,
   `Resources/` and the build identity all describe the commit being
   installed.
3. **Download** into `~/tbd/updates/prebuilt/<commit>.partial/` with `curl
   --fail --location`, and fetch the checksum.
4. **Verify** before anything is unpacked into place. The tarball's SHA-256
   must equal the published checksum. The attestation must verify when
   Question 4 requires it. After unpacking, every file must match its
   `manifest.json` hash, `manifest.json`'s commit must equal the target
   commit, all six products must be present and executable, and `lipo
   -archs` must report the architecture this machine needs. Any failure
   deletes the `.partial` directory and takes the fallback. A download that
   failed to verify is never installed, whatever the fallback says.
5. **Normalize.** `xattr -dr com.apple.quarantine` on the unpacked tree. `curl`
   does not set the quarantine attribute, but a browser that fetched the
   tarball would, and Gatekeeper evaluates quarantined executables only. The
   helper binaries keep the linker's ad-hoc signature, as local builds do.
   The app bundle is re-signed locally as before.
6. **Stamp the build identity locally.** Call `write_build_identity
   "$UPDATE_SRC" <prebuilt dir>` with the clone detached at the target commit.
   It records the commit, `sourceWorktree = ~/tbd/updates/src` and a clean
   tree. The sidecar gains a `"provenance"` key: `"release"` plus the run URL
   for a download, and `"local"` for a local build. Older binaries ignore
   unknown keys (`BuildIdentity` decodes leniently), so the key costs nothing.
   Showing it in `tbd version` is an optional compiled follow-up.
7. **Rename** `<commit>.partial` to `<commit>`, point the release build path at
   it (section 4.4), then continue with the unchanged tail: `assemble_app_bundle`,
   `sign_app_bundle`, `install_and_handover`, `refresh_installed_cli`, the app
   stage and the wake stage.
8. **Prune.** After a successful handover, delete every
   `~/tbd/updates/prebuilt/<commit>` except the one now running and the one it
   replaced. The replaced one backs `~/tbd/updates/previous/TBD.app`, and its
   daemon is what a rollback restarts.

`--debug` always builds locally, because CI publishes release builds only.
`--dry-run` downloads and verifies, then stops. `--check` is unchanged apart
from Question 7.

### 4.4 Where the downloaded daemon lives

Section 3 requires that the app's reboot respawn find the downloaded daemon.
The proposal keeps `<sourceWorktree>/.build/release` as the one path both
kinds of install run from, with the download reached through a symlink:

- SwiftPM already makes `.build/release` a symlink, to
  `.build/arm64-apple-macosx/release`. A download re-points that symlink at
  `~/tbd/updates/prebuilt/<commit>`. A later local build re-points it back.
  The updater records which of the two it did.
- The prebuilt directory lives outside `.build`, so SwiftPM's build database
  never sees downloaded files it did not produce, and a local fallback build
  stays correctly incremental.
- `DaemonCandidateFinder`, the handover's `paths_match` (which resolves
  symlinks) and `refresh_installed_cli`'s hard link all work unchanged.
  `refresh_installed_cli` works because `~/tbd` and `~/.local` share a volume.

The proposal depends on SwiftPM replacing a `.build/release` symlink that
points somewhere else, rather than refusing or building through it. That has
to be tested on the pinned toolchain before implementation. If it fails, the
two alternatives are in section 5, "The daemon inside the bundle" and "A new
daemon candidate path".

### 4.5 Reclaiming what this creates

This design creates durable resources in two places, and each needs a named
reconciler.

- **Local prebuilt trees** under `~/tbd/updates/prebuilt/`. Step 8 of section
  4.3 bounds them to two, in the same script that creates them. Nothing else
  creates them. A run killed mid-download leaves a `<commit>.partial` tree,
  and the next update deletes every `.partial` while it holds the update
  lock. They share the reasoning of `previous/TBD.app`: an entry is never
  created without its predecessor being pruned.
- **Remote release assets.** The publishing job deletes every asset beyond the
  newest N commits (Question 3). A missed prune leaves extra assets but
  cannot grow the set without bound, because the next successful run prunes
  again.

## 5. Rejected alternatives

- **Ship a finished, signed `TBD.app`.** The bundle embeds the installing
  shell's `PATH`, and it must carry the installing machine's signing identity
  for TCC decisions to persist. Only the bundle's contents can come from CI;
  its assembly stays local.
- **Workflow artifacts rather than release assets.** Downloading one needs an
  authenticated API token, even on a public repository, and arrives wrapped in
  a zip. That adds a `gh auth` dependency to every update, and retention caps
  at 90 days. A release asset is fetchable with `curl` alone.
- **A tagged release per commit.** At about 140 pushes to `main` per month,
  it floods the Releases page and adds a tag to every clone.
- **The daemon inside the bundle.** Putting `TBDDaemon`, its four siblings and
  its resource bundles in `Contents/MacOS` would let the app's first daemon
  candidate find them, and the kept previous bundle would then be a complete
  rollback. But it changes the layout for local builds as well, puts resource
  bundles in a directory not meant for them, and makes `codesign --deep` sign
  every helper with the TCC identity. That is a larger change than this
  problem needs. It stays the fallback if the symlink in section 4.4 proves
  unworkable.
- **A new daemon candidate path.** A compiled `prebuilt` candidate in
  `DaemonCandidateFinder` works, but it means a rebuild and a skew window
  before an old app can find a new layout. The symlink needs no compiled
  change.
- **A self-hosted runner.** The point is to spend GitHub's CPUs rather than a
  maintainer's, and a self-hosted runner in a public repository runs
  contributors' workflow code on that machine.
- **Download inside the daemon.** The daemon could fetch the asset itself. But
  the update procedure is deliberately user-land (`scripts/update.sh`), per
  "Compile only what user-land cannot do well". Downloading, verifying and
  unpacking are all things a script does well.

## 6. Risks

- **Relocated resource lookups** (section 3). The CI smoke test and a manual
  run of the app from a relocated tree cover these. The fix for any consumer
  that fails is to probe `Bundle.main` explicitly, as `SQLMigrationLoader`
  does.
- **Toolchain skew between a local build and a download.** A machine that
  alternates between the two runs binaries from two compilers. Both come from
  the same source, and the daemon, app and helpers in one install always come
  from one source, so no single install mixes compilers.
- **macOS compatibility.** The deployment target is macOS 15. CI links against
  the macOS 26 SDK, as local Xcode 26 builds already do. A user on macOS 15
  runs SDK-26-linked binaries in both cases. Nothing new here, but the
  smoke test runs on macOS 26 only.
- **Supply chain.** Today an update trusts the git remote. A download also
  trusts GitHub Actions, the workflow file on `main`, and everyone with write
  access to releases. A checksum published beside the asset proves transport
  integrity, not origin. Only an attestation that verifies against the
  workflow's identity binds the bytes to "built by `release.yml` from this
  commit on `main`" (Question 4).
- **macOS runner capacity.** GitHub allows five concurrent macOS jobs per
  account, shared with `test.yml`'s two per run and with the remote
  verification valve. One more macOS job per push to `main` narrows that
  headroom. Minutes are free on a public repository.
- **Latency.** A download is only as fresh as the last finished CI build. With
  no cache, a cold release build on the runner is unmeasured, but the debug
  equivalent reached 1,250 s. `main` can therefore lead the newest asset by
  tens of minutes, and Question 7 decides what the update check does in that
  window.

## 7. Verification before the flag flips

- On the pinned toolchain, SwiftPM re-points a foreign `.build/release`
  symlink on the next local build, and that build is incremental.
- The CI smoke test passes, and the downloaded app, launched from
  `/Applications`, renders markdown, sidebar icons, and the Metal terminal
  renderer. None of these may fall back to a missing resource.
- After a reboot, the app respawns the downloaded daemon, not a stale local
  one.
- A deliberately corrupted tarball, a manifest naming the wrong commit, and a
  missing product each end in the fallback and never in an install.
- The repo's `scripts/update.test.sh` harness gains a case for each branch of
  the source step: download, no asset, verification failure, `--debug`, and
  the switch in each position.

## 8. Open questions for Adam

Each question lists its options and a recommendation. The recommendation is
the drafting agent's lean, not a decision.

1. **What does `tbd update` do by default, and where does the switch live?**
   - (a) Local build stays the default. `tbd update --from-release` opts in
     per run, and an `update-source` switch in user-land (a constant at the
     top of `scripts/update.sh`, overridable by an environment variable) opts
     in for `auto` mode.
   - (b) Download is the default, and `--build` forces a local build.
   - (c) A daemon `config` column `update_source` (NULL/`build`/`release`),
     shown in Settings next to `update-mode`.
   - Recommendation: (a). Installing binaries this machine did not compile
     replaces a load-bearing path, so it ships default-off per the repo
     rule. Keeping the switch in user-land avoids a migration, and flipping
     it after a soak is a one-line edit. (c) is the upgrade path if Settings
     should show it.

2. **Which commits get built?**
   - (a) Every push to `main`, newer pushes cancelling older builds.
   - (b) Only commits whose `test.yml` run on `main` passed, triggered by
     `workflow_run`.
   - Recommendation: (b). A download install should be no worse than today's
     local build of a red `main`, and preferably better. (b) adds the test
     run's ten or so minutes of latency but never publishes a commit its own
     test suite rejected.

3. **Where do assets live?**
   - (a) One rolling prerelease (tag `main-builds`) holding the newest N
     commits' assets, with older ones pruned by the workflow.
   - (b) A tagged prerelease per commit.
   - (c) Workflow artifacts with 90-day retention.
   - Recommendation: (a), with N = 20. It adds one entry to the Releases page,
     gives each asset a stable URL, and needs no API calls. (b) spams the
     Releases page and every clone's tags. (c) needs an authenticated token
     for every download.

4. **What integrity check is required before install?**
   - (a) A SHA-256 checksum plus the per-file manifest hashes only.
   - (b) Also verify the GitHub build-provenance attestation when `gh` is
     installed and authenticated, and fall back to (a) when it is not.
   - (c) Require a verified attestation (`gh attestation verify --repo
     <owner>/<repo> --signer-workflow <owner>/<repo>/.github/workflows/release.yml`),
     and refuse the download without it.
   - Recommendation: (c) for `auto` mode and (b) for a manual run. An
     unattended install should only ever trust bytes provably built by the
     workflow from `main`. A person running the command can see what they
     get. A checksum alone proves only that the bytes were not corrupted in
     transit.

5. **Which architectures?**
   - (a) arm64 only. Intel machines always build locally.
   - (b) Universal (arm64 + x86_64), roughly doubling CI build time and asset
     size.
   - Recommendation: (a). The runner is arm64, and the active installations
     are Apple silicon. The architecture check in step 4 of section 4.3 makes
     an Intel machine fall back cleanly, so (b) can come later without a
     format change.

6. **When no usable asset exists, what happens?**
   - (a) Fall back to the local build, as today.
   - (b) Manual run: fall back to the local build. `auto` run: log "no asset
     for <commit>" and exit without building, so the next check tries again.
   - (c) Always fail with a message and build nothing.
   - Recommendation: (b). The point of the feature is that unattended updates
     stop spending local CPU, and a person running the command can accept a
     local build knowingly. A verification failure is never "no asset": it
     aborts the run and logs loudly in every mode.

7. **What does the update check compare against?**
   - (a) The head of `main`, as today. `auto` mode may then fire before an
     asset exists, and (combined with 6b) skip that commit.
   - (b) A ref the workflow moves after each successful publish (for example
     `refs/tags/main-builds`, read with the same `git ls-remote`), so "update
     available" means "an installable build exists". This is a compiled
     change to the checker's ref, or a new user-land setting it reads.
   - (c) (a) for `check`, (b) for `auto`.
   - Recommendation: (b) whenever the download path is on, and (a) otherwise.
     There is one subtlety. The checker records each commit it launched an
     update for and does not retry it until `main` moves. Under (a) with 6b,
     an `auto` run can reach a commit before its asset is published, and then
     that commit is never installed until the next push. (b) removes that
     race.

8. **Where does a downloaded install live on disk?**
   - (a) `~/tbd/updates/prebuilt/<commit>/`, with the clone's
     `.build/release` symlink re-pointed at it (section 4.4). No compiled
     change, and it depends on SwiftPM re-pointing a foreign symlink.
   - (b) The daemon, helpers and resource bundles inside
     `TBD.app/Contents/MacOS`. The previous bundle then rolls back the daemon
     too, but the layout changes for every install.
   - (c) `~/tbd/updates/prebuilt/<commit>/` plus a compiled new candidate in
     `DaemonCandidateFinder`.
   - Recommendation: (a), provided the SwiftPM check in section 7 passes, and
     (c) if it does not. In all three, the update clone stays checked out at
     the installed commit, so the build identity still names a real local
     checkout. `tbd update` and the update checker both depend on that.
