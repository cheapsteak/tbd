# Release pipeline: build in CI, install the download — design

`tbd update` compiles the whole installation on the machine it updates. This
spec moves most of that compile to a GitHub Actions macOS runner. A workflow
builds the release configuration of the runtime products for each commit on
`main` whose test run passed, and publishes the output as a release asset keyed
by that commit. `tbd update --from-release` downloads and verifies the asset
instead of building, and falls back to the local build when none fits.

The design behind `tbd update` is
[`2026-09-04-automatic-version-updates-design.md`](2026-09-04-automatic-version-updates-design.md).
That spec lists "a release channel, tags, or signed downloadable builds" among
its non-goals, so "latest" there means a commit on `main`. This spec revises
that non-goal and nothing else. The commit is still the identity; a download
is another way to get that commit's binaries onto disk.

The repository owner decided the design questions on 2026-09-23; section 8
records them. One question remains open: how the app gets its resource
bundles on a machine that did not compile it. Section 3.1 states it and its
options. The implementation that accompanies this spec is option C, and it is
held until the repository owner records a choice.

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

- One CI build per commit on `main` that passed its tests, published where an
  unauthenticated `curl` can fetch it.
- `tbd update --from-release` installs that build without compiling the
  daemon side. The resulting installation behaves the same as a locally built
  one: same bundle assembly, same local signing identity, same handover, same
  kept previous bundle, same build-identity reporting.
- An unattended install only ever trusts bytes provably built by the release
  workflow from `main`.
- When no usable asset exists, the update degrades predictably and never
  installs a partial or unverified tree.

Non-goals:

- Notarization, a Developer ID signature, or a drag-to-install `.app` for people
  who have never built TBD. The installation still starts from a checkout.
- Semantic versions, a changelog, or release notes. The commit is still the
  version.
- Intel or universal binaries.
- Changing the handover, the wake pacing, or anything after the install step.

## 3. What the updater's layout requires

- **`TBD.app` is assembled on the machine that installs it.**
  `assemble_app_bundle` writes the installing shell's `PATH` into
  `Contents/Info.plist` (`write_restart_environment_plist`), and a login
  relaunch depends on that value. `sign_app_bundle` signs with a per-machine
  self-signed `TBD Dev Signing` identity, so that TCC decisions persist across
  rebuilds ([`docs/tcc-signing.md`](../tcc-signing.md)).
  `Contents/SourceWorktreePath.txt` names a local path. So CI ships build
  products, and the local updater assembles, signs and installs the bundle
  from them exactly as it does after a local build.
- **The daemon never lives in the bundle.** `update.sh` starts the successor
  from `<build_dir>/TBDDaemon`, and the daemon finds `TBDCLI`, `TBDHolder`,
  `TBDPeerHelper` and `TBDModelProxy` as siblings of its own binary. After a
  reboot, the app respawns a missing daemon from the first executable
  candidate `DaemonCandidateFinder` names: the app bundle's `MacOS/TBDDaemon`,
  then `<sourceWorktree>/.build/release/TBDDaemon`, then `.build/debug`. A
  downloaded daemon must therefore be reachable at
  `<sourceWorktree>/.build/release/TBDDaemon` (section 4.4).
- **The update clone stays, at the installed commit.** `sourceWorktree` in the
  build identity is what `tbd update` execs `scripts/update.sh` from. It is
  also where the daemon's update checker runs `git remote get-url`, `git
  merge-base --is-ancestor` and `git rev-list --count`. `assemble_app_bundle`
  reads `Resources/TBDApp.Info.plist` and `Resources/AppIcon.icns` from it. So
  the fetch into `~/tbd/updates/src` keeps running; only the compile goes
  away.
- **Resource bundles travel with the binaries, and the app cannot find its own
  from a download.** SwiftPM's generated `Bundle.module` accessor looks for
  `<Name>.bundle` at `Bundle.main.bundleURL` first. If that fails, it tries an
  absolute build path baked in at compile time
  (`<builder>/.build/arm64-apple-macosx/release/<Name>.bundle`), and calls
  `fatalError` if both fail.
  - For every executable except the app, `Bundle.main.bundleURL` is the
    executable's own directory, so bundles shipped beside it are found.
    `SQLMigrationLoader` does not use `Bundle.module` at all.
  - For the installed app, `Bundle.main.bundleURL` is the root of
    `/Applications/TBD.app`, while `assemble_app_bundle` stages the bundles in
    `Contents/Resources`. The installed app therefore resolves `Bundle.module`
    only through the baked build path, which exists on the machine that
    compiled it and nowhere else. The affected consumers are TBDApp's sidebar
    and content icons, `MarkdownStylesheet`, and the Highlightr dependency,
    whose `init` reads `Bundle.module` unconditionally. The code viewer, the
    diff highlighter and `CodeHighlightService` all construct `Highlightr()`.
  - So a CI-built `TBDApp` would stop at its first resource lookup on any
    user's machine.
- **So the app cannot simply join the asset.** Section 3.1 lists the ways
  around that; the rest of this spec describes option C.

### 3.1 The app-bundle choice (open)

This choice is pending the repository owner. The planned sequence is C now and
A next.

- **A – relocatable `Bundle.module`.** A resolver that checks
  `Bundle.main.resourceURL` before the generated accessor, used at TBDApp's
  four `Bundle.module` sites, and the same change in a Highlightr fork,
  following the SwiftTerm fork precedent. With it, `TBDApp` joins the asset
  and an update compiles nothing. It touches compiled app code and adds a
  forked dependency.
- **B – build at a fixed shared path.** CI builds under a path that exists on
  every Mac, such as `/Users/Shared`, and the installer links that path to the
  download so the baked build path resolves. `/Users/Shared` is
  world-writable, so another local user could plant that path, and the
  approach assumes one TBD user per machine.
- **C – ship every product but the app.** The asset carries `TBDDaemon`,
  `TBDCLI`, `TBDHolder`, `TBDPeerHelper` and `TBDModelProxy` with their
  resource bundles. The update compiles `TBDApp` alone (about 30% of a cold
  build, measured in
  [`docs/research/2026-08-19-cold-build-split/findings.md`](../research/2026-08-19-cold-build-split/findings.md))
  and adds it to the downloaded tree. It needs no change to compiled app code,
  and A later removes the remaining local compile without changing anything C
  builds.
- **D – patch the baked path in the binary.** An equal-length rewrite followed
  by a local re-sign works mechanically, but it is fragile and opaque.

## 4. Design

### 4.1 The workflow

`.github/workflows/release.yml` is separate from `test.yml`, so the test
workflow's triggers, cache policy and concurrency stay untouched.

- **Trigger.** `workflow_run` on the `Test` workflow, completed. A job-level
  condition admits only a successful run from a `push` to this repository's
  `main`. A `workflow_dispatch` input backfills one commit, and the job
  refuses any commit that `main` does not contain.
- **Two jobs, split by privilege.**
  - `release-build` runs on `macos-26` with `contents: read`. It selects Xcode
    26.6 (the pin `test.yml` uses) and runs `swift build -c release --product
    <P>` for each of the five published products, with the same `-j 3` cap
    as `test.yml`. It then packages, smoke-tests and uploads the archive as a
    one-day workflow artifact.
  - `release-publish` runs on `ubuntu-latest` with `contents: write`,
    `id-token: write` and `attestations: write`. It runs only this
    repository's scripts against that artifact.
- **Concurrency.** `group: release-main`, `cancel-in-progress: true`. A
  superseded commit gets no asset, which costs nothing, because an update
  walks back to the newest commit that has one.
- **Cache.** None. The Actions cache store holds about 9.4 of its 10 GB, and a
  release-configuration entry would evict the debug entries `test.yml`
  depends on.
- **Package** (`scripts/ci/package-release.sh`). This stages the five products
  and every non-test `*.bundle` beside them into
  `tbd-<commit>-macos-arm64/`, and adds `manifest.json`. The manifest records
  the commit, the architecture, the build time, the product list, the Swift,
  Xcode and macOS versions, the runner image, the run URL and a SHA-256 per
  file. The script archives the directory as `tbd-<commit>-macos-arm64.tar.gz`
  and writes a `.sha256` beside it.
- **Smoke test** (`scripts/ci/smoke-release.sh`). This runs before anything is
  published, and simulates a machine that did not build the archive. It moves
  the checkout's `.build` aside, so no baked build path resolves, and unpacks
  the archive at an unrelated path. Then it checks three things:
  - every resource bundle a shipped executable names by build path is present
    beside that executable;
  - every helper starts without a dyld or resource-bundle failure;
  - the daemon, run from the unpacked tree against a scratch `TBD_HOME`,
    applies its migrations and serves its socket.
- **Attest.** `actions/attest-build-provenance` over the archive.
- **Publish** (`scripts/ci/publish-release.sh`).
  - It uploads to the rolling prerelease `main-builds`, creating the
    prerelease on first use and marking it not-latest.
  - It then moves the `main-builds` tag to the commit, only forward along
    `main`, and only after the upload. The tag therefore always names a
    published commit, and a backfill of an older commit never moves it back.
  - Finally it prunes every asset beyond the newest 20 commits', always
    keeping the tagged one.

### 4.2 Asset naming and keying

The key is the full 40-character commit. It appears in the asset name, in
`manifest.json`, and in the checksum file. Each asset has a stable URL:

`https://github.com/<owner>/<repo>/releases/download/main-builds/tbd-<commit>-macos-arm64.tar.gz`

`update.sh` builds that URL from the update remote and the commit. It makes no
GitHub API call, so the unauthenticated API rate limit never applies.
Release-asset downloads are served outside that limit. `TBD_RELEASE_REPO`
points a fork's updates at another repository's releases.

### 4.3 The update path

`scripts/update.sh` resolves an update source, `build` or `release`. In order
of precedence it takes:

1. the `--from-release` flag (one run);
2. the `TBD_UPDATE_SOURCE` environment variable;
3. the file `~/tbd/updates/update-source` (every run, `auto` included);
4. the `UPDATE_SOURCE_DEFAULT` constant, shipped as `build`.

An edit to the constant in the update clone would not survive the next
update's checkout, which is why the file exists. With the source at `release`,
the fetch and detach of `~/tbd/updates/src` run as before, and then
`acquire_release_build` (`scripts/update-release-lib.sh`) runs:

1. **Architecture.** A machine that is not arm64 builds locally, in every
   mode, because a download can never serve it.
2. **Find the target.** Walk `main`'s first-parent history from the head,
   at most `RELEASE_WALKBACK` (10) commits. The target is the first commit
   whose `.sha256` downloads. When the running commit is the target or a
   descendant of it, there is nothing to install.
3. **Download** into `~/tbd/updates/prebuilt/download.partial/`.
4. **Verify**, before anything is unpacked into place.
   - The archive's SHA-256 must equal the published checksum.
   - The attestation is then checked with `gh attestation verify --repo
     <owner>/<repo> --signer-workflow
     <owner>/<repo>/.github/workflows/release.yml`.
     - If `gh` answers no, the run aborts in every mode.
     - If `gh` is not installed or not signed in, an `--auto` run refuses,
       and a manual run warns and continues on the checksum alone.
   - After unpacking, `manifest.json` must name the target commit and arm64.
     Every file must match its hash, the tree must hold no unlisted file and
     no symlink, and all five products must be present and executable.
   - A failure deletes the download and aborts the run. It never falls back
     to a build.
5. **Normalize.** Clear `com.apple.quarantine`, detach the clone at the target
   commit, and move the tree to `~/tbd/updates/prebuilt/<commit>/`.

`update.sh` then finishes the install.

1. **Stamp the identity.** `write_build_identity` stamps the tree from the
   clone. `stamp_release_provenance` adds `provenance: release`, the CI run
   URL, CI's build time and `locallyBuiltProducts`.
2. **Build `TBDApp` locally.** If `.build/release` currently points into the
   prebuilt home, `update.sh` removes the link, so SwiftPM owns its own
   directory for the build. It then builds `TBDApp` and copies it, plus any
   resource bundle the download lacks, into the tree. A failure restores the
   previous link and stops with the installation untouched.
3. **Stop here on `--dry-run`**, with the previous link restored.
4. **Point** `~/tbd/updates/src/.build/release` at the tree, by an atomic
   rename of a symlink. The unchanged tail follows: `assemble_app_bundle`,
   `sign_app_bundle`, `install_and_handover`, the CLI refresh, the app stage
   and the wake. The handover starts the daemon through that link, so it runs
   the downloaded binary.
5. **On a failed handover**, the previous app bundle is restored as before,
   and the link is pointed back at the tree still running.
6. **On success**, prune `~/tbd/updates/prebuilt/` to the running tree and the
   one it replaced.

When nothing is published for the last ten commits, what happens depends on
who is running the update. A manual run logs it and builds locally, as today.
An `--auto` run logs it and exits zero without building, and the next check
tries again. `--debug` always builds locally. A local build first hands
`.build/release` back to SwiftPM if it points at a download.

### 4.4 Where the downloaded daemon lives

`<sourceWorktree>/.build/release` is the one path both kinds of install run
from. SwiftPM makes it a symlink to `.build/arm64-apple-macosx/release`. A
download re-points it at `~/tbd/updates/prebuilt/<commit>`, and a local build
through `update.sh` removes that link first, so SwiftPM recreates its own.

- The prebuilt tree lives outside `.build`, so SwiftPM's build database never
  sees files it did not produce.
- `DaemonCandidateFinder`, the handover's `paths_match` (which resolves
  symlinks), and `refresh_installed_cli`'s hard link all work unchanged.
  `refresh_installed_cli` works because `~/tbd` and `~/.local` share a volume.

SwiftPM tolerates this. A throwaway package on Swift 6.3.2 had its
`.build/release` pre-pointed at an unrelated directory, and SwiftPM replaced
that link with its own on both a cold build and a warm incremental one. It
wrote nothing into the foreign directory, and the incremental build only
relinked.

### 4.5 What the daemon compares against

The daemon's update checker compares the running commit against the ref
`UpdateChecker.comparedRef` names, read fresh on every tick.

- **Default:** `refs/heads/main`.
- **Release source:** `refs/tags/main-builds`, when
  `~/tbd/updates/check-ref` (`TBDConstants.updateCheckRefFile`, honoring
  `TBD_HOME`) names it. `update.sh` writes that file whenever the standing
  update source (environment, file or constant, but not a one-off
  `--from-release`) is `release`, and removes it otherwise. `update.sh
  --check` syncs it too.
- **Anything else:** a value that is not a well-formed `refs/heads/…` or
  `refs/tags/…` reads as `main`.

With the release source, "update available" therefore means "an installable
build exists". An `auto` run can no longer reach a commit before its asset is
published. The checker records each commit it launched an update for and does
not retry it until the ref moves, so under the old comparison such a commit
would not have been retried until the next push.

### 4.6 Reclaiming what this creates

- **Local prebuilt trees** under `~/tbd/updates/prebuilt/`. The script that
  creates them reclaims them:
  - `prune_prebuilt` runs after every successful release install, keeping the
    running tree and the one it replaced;
  - `sweep_partial_downloads` removes a `.partial` left by a killed run at the
    start of the next release run, under the update lock.

  An entry is never created without its predecessors being pruned, which is
  the same reasoning as `previous/TBD.app`.
- **Remote assets.** `publish-release.sh` prunes to the newest 20 commits on
  every publish. A missed prune leaves extra assets, and the next publish
  removes them.

## 5. Rejected alternatives

- **Ship a finished, signed `TBD.app`.** The bundle embeds the installing
  shell's `PATH`, and it must carry the installing machine's signing identity
  for TCC decisions to persist.
- **Stage resource bundles at the app bundle's root.** `codesign` rejects
  unsealed contents in a bundle root.
- **Workflow artifacts rather than release assets.** Downloading one needs an
  authenticated token even on a public repository, and arrives wrapped in a
  zip. Retention caps at 90 days.
- **A tagged release per commit.** At about 140 pushes to `main` per month,
  it floods the Releases page and adds a tag to every clone.
- **The daemon inside the bundle.** This changes the layout for local builds
  too, puts resource bundles in a directory not meant for them, and makes
  `codesign --deep` sign every helper with the TCC identity.
- **A self-hosted runner.** The point is to spend GitHub's CPUs, and a
  self-hosted runner in a public repository runs contributors' workflow code
  on that machine.
- **Download inside the daemon.** The update procedure is deliberately
  user-land, per "Compile only what user-land cannot do well". Downloading,
  verifying and unpacking are things a script does well. The daemon gained
  only the read of the check-ref file, because the update checker is
  compiled.

## 6. Risks

- **Toolchain skew.** A release install runs daemon-side binaries from the
  CI compiler and an app from the local one. Both come from the same commit
  and talk over the same RPC types, so the skew is the same as between two
  local toolchains.
- **macOS compatibility.** The deployment target is macOS 15. CI links against
  the macOS 26 SDK, as local Xcode 26 builds already do.
- **Supply chain.** A download trusts GitHub Actions, the workflow file on
  `main`, and everyone who can change it. The attestation binds the bytes to
  "built by `release.yml` in this repository". An `--auto` run requires it;
  a manual run without `gh` settles for the checksum and says so.
- **macOS runner capacity.** GitHub allows five concurrent macOS jobs per
  account, shared with `test.yml`'s two per run and with the remote
  verification valve. The release job adds one per commit that passes on
  `main`. Minutes are free on a public repository.
- **Latency.** A download is available only after `Test` passes and
  `release-build` finishes. A cold release build on the runner is
  unmeasured. With the release source, the check compares against the
  published tag, so this latency delays updates but never produces a false
  "update available".

## 7. Verification

- `scripts/update.test.sh` covers every branch of the source step, with
  stubbed `curl`, `gh` and `uname`:
  - a verified install that builds only the app, links, stamps and prunes;
  - the walk back to an older published commit;
  - a missing or failing attestation in `auto` mode (refused);
  - a missing attestation tool in a manual run (proceeds with a warning), and
    a failing attestation in a manual run (refused);
  - a checksum mismatch and a manifest naming another commit (aborted);
  - nothing published: `auto` skips, a manual run builds locally;
  - a non-arm64 machine (builds locally, downloads nothing);
  - a dry run (leaves the running link);
  - a failed handover (the link goes back);
  - the link handed back to SwiftPM before a local build;
  - the source precedence and the check-ref file.
- `UpdateCheckRefTests` covers the check ref: no file compares against `main`,
  a release file against the tag, and malformed contents fall back to `main`.
- Before the default flips, two checks remain:
  - a first `release.yml` run on `main` passes its smoke test;
  - after a reboot, the app respawns the downloaded daemon.

## 8. Decisions

The repository owner decided each of these on 2026-09-23.

1. **Default and switch.** A local build stays the default. `tbd update
   --from-release` opts in for one run, and the user-land update source
   (section 4.3) opts in for every run, `auto` included. Installing binaries
   this machine did not compile replaces a load-bearing path, so it ships
   default-off per the repository rule. Graduation flips
   `UPDATE_SOURCE_DEFAULT` to `release`. Explicit choices, whether the file or
   the environment, keep winning.
2. **Which commits get built.** Only commits whose `Test` run on `main`
   passed, triggered by `workflow_run`. Test time adds latency, but a commit
   its own test suite rejected is never published.
3. **Where assets live.** One rolling prerelease, `main-builds`, holding the
   newest 20 commits' assets. It adds one entry to the Releases page, gives
   each asset a stable URL, and needs no API call to download.
4. **Integrity.** An `--auto` run requires a verified build-provenance
   attestation and refuses without one. A manual run verifies the attestation
   when `gh` is installed and signed in, and otherwise proceeds on the
   checksum with a warning. The checksum and the per-file manifest are always
   checked.
5. **Architecture.** arm64 only. Other machines build locally.
6. **No usable asset.** A manual run builds locally. An `--auto` run logs and
   skips, and the next check tries again. A verification failure is never
   "no asset": it aborts in every mode.
7. **What the check compares against.** The `main-builds` tag while the update
   source is `release`, and `main` otherwise (section 4.5).
8. **Where a download lives.** `~/tbd/updates/prebuilt/<commit>/`, with the
   clone's `.build/release` symlink pointed at it (section 4.4 records the
   SwiftPM check this rests on). The update clone stays at the installed commit, so the build identity
   names a real local checkout.
