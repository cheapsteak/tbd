# SwiftLint Adoption Research for TBD

**Date:** 2026-05-13
**Trigger:** PR #143 had a chain of small "Address review" commits replacing
`print()` calls with `os.Logger`. Goal: catch CLAUDE.md violations
mechanically before PR review.
**Constraint:** TBD is SPM-only — no `.xcodeproj`, no Xcode build phases.
**SwiftLint version researched:** 0.63.2 (released 2026-01-26).

This doc is research only. Implementation lives in a follow-up PR.

---

## 1. Best practice for SwiftLint on SPM-only projects in 2026

Three viable options for a `.xcodeproj`-less SPM package:

| Option | Local install needed? | Cost on `swift build` | Cost on `swift test` | `Package.resolved` impact |
|---|---|---|---|---|
| **SwiftLintBuildToolPlugin** (via SimplyDanny/SwiftLintPlugins) | None — binary ships in the package as an artifact bundle | Adds a prebuild step that re-lints all `.swift` files in each target every build (cached after first run) | Same prebuild step runs before tests | Adds `SwiftLintPlugins` and the bundled `SwiftLintBinary` artifact |
| **Standalone CLI** (Homebrew/Mint, or a vendored binary called from a script) | Yes — every contributor + CI needs `brew install swiftlint` (or equivalent) | Zero (lint is out-of-band) | Zero | None |
| **CI-only** (GHA step calling `swiftlint --strict`) | None | Zero | Zero | None |

Key facts (sourced below):

- The plugin **doesn't run lint on changed files only** — every `swift build`
  it re-runs SwiftLint against the target's full source set, but the SwiftLint
  CLI itself is fast and the plugin caches between runs. Build-time impact on
  TBD's ~5 targets should be a few seconds the first time and ~sub-second on
  incremental builds.
- The plugin requires **Swift Package Manager macOS host only** — fine for
  TBD (macOS-only project anyway), and harmless on `swift test` because tests
  run on the same host.
- `Package.resolved` will gain entries for `SwiftLintPlugins` and the
  `SwiftLintBinary.artifactbundle` checksum. This means `swift build` on a
  fresh checkout downloads ~20 MB of binary on first resolve, then caches.
- The plugin **does not require contributors to `brew install` anything** —
  the artifact bundle ships SwiftLint inside the SPM dependency graph.

> **Source (SwiftLint README, `## Setup` section, fetched 2026-05-13 via
> `gh api repos/realm/SwiftLint/readme`):**
>
> > Build tool plugins run when building each target. When a project has multiple
> > targets, the plugin must be added to the desired targets individually.
>
> > The build tool plugin determines the SwiftLint working directory by locating
> > the topmost config file within the package/project directory. If a config file
> > is not found therein, the package/project directory is used as the working
> > directory.

> **Source (SwiftLintBuildToolPlugin source, fetched via WebFetch
> `https://github.com/realm/SwiftLint/blob/main/Plugins/SwiftLintBuildToolPlugin/SwiftLintBuildToolPlugin.swift`):**
>
> > The plugin **expects SwiftLint to already be installed** — it doesn't
> > download it. Instead, it retrieves the executable via
> > `context.tool(named: "swiftlint")`.
>
> (Caveat: this is true of the plugin source in the realm/SwiftLint repo
> when consumed directly. The **SimplyDanny/SwiftLintPlugins** wrapper
> ships a binary artifact bundle that resolves `context.tool(named:
> "swiftlint")` to the bundled binary, so end users still need no local
> install. See section 2.)

### Recommendation

**Adopt SwiftLintBuildToolPlugin via SimplyDanny/SwiftLintPlugins**, pinned
with `from: "0.63.2"`. Reasons specific to TBD:

1. **Zero contributor friction** — no `brew install` step in the README.
2. **Catches violations at `swift build`** — the same command CLAUDE.md tells
   contributors to run before committing ("Verify your changes compile
   (`swift build`) before committing"). This is the most natural enforcement
   point we have.
3. **Same path runs in CI** — no second config to drift.
4. **Bundled binary** removes the realm/SwiftLint plugin's "swiftlint must
   be on PATH" footgun.

Apply the plugin to `TBDShared`, `TBDDaemonLib`, `TBDCLI`, `TBDApp` (the
four targets owning real code; the `TBDDaemon` executable target only
contains `main.swift` and gets covered transitively via `TBDDaemonLib`).
**Do not** apply it to test targets — printing in tests is fine, and we
want to keep `swift test` lean.

---

## 2. What the official SwiftLint repo recommends NOW

From `gh api repos/realm/SwiftLint/readme` (2026-05-13), the README's
`### Swift Package Manager` and `### Swift Package Projects` sections say
verbatim:

> SwiftLint can be used as a [command plugin] or a [build tool plugin].
>
> Add
>
> ```swift
> .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "<version>")
> ```
>
> to your `Package.swift` file …

And then for attaching to a target:

> ```swift
> .target(
>     ...
>     plugins: [.plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins")]
> ),
> ```

Crucially, the README contains an explicit recommendation block:

> > [!NOTE]
> > Consuming the plugins directly from the SwiftLint repository comes
> > with several drawbacks. To avoid them and reduce the overhead imposed, it's
> > highly recommended to consume the plugins from the dedicated
> > [SwiftLintPlugins repository](https://github.com/SimplyDanny/SwiftLintPlugins),
> > even though plugins from the SwiftLint repository are also absolutely
> > functional.
> >
> > This document assumes you're relying on SwiftLintPlugins.

The SimplyDanny/SwiftLintPlugins README (fetched via
`gh api repos/SimplyDanny/SwiftLintPlugins/readme`, latest tag `0.63.2`
published 2026-01-26) gives the rationale:

> Offering the plugins in a separate package has multiple advantages you should be aware of:
>
> * No need to clone the whole SwiftLint repository.
> * SwiftLint itself is included as a binary dependency, thus the consumer doesn't need to build it first.
> * There are no other dependencies that need to be downloaded, resolved and compiled.
> * There is especially no induced dependency on [SwiftSyntax](https://github.com/apple/swift-syntax) which would require a lot of build time alone.
> * For projects having adopted Swift macros or depend on SwiftSyntax for other reasons, there is no version conflict caused by the fact that SwiftLint has to rely on a fixed and pretty current version.

### Recommendation

Use `SimplyDanny/SwiftLintPlugins` not `realm/SwiftLint` as the SPM
dependency URL. Pin with `from: "0.63.2"` (allows patch updates, blocks
unexpected major bumps). Don't `exact:` — we want passive bug-fix
upgrades.

The `<version>` placeholder above must be replaced with `"0.63.2"` (the
latest release as of this research).

---

## 3. Pre-push git hook patterns for Swift OSS projects

Three live trade-offs:

**Lint changed vs. all files.** The build-tool plugin already lints the
whole tree on every `swift build`. A pre-push hook that re-lints
everything is duplicative and slow. A pre-push hook that lints **only
files changed since `origin/main`** is fast and catches the "I committed
without building" case. Either of:

```bash
git diff --name-only --diff-filter=ACM origin/main...HEAD '*.swift' \
  | xargs -r swiftlint lint --strict --use-stdin <  # one variant
```

or simpler:

```bash
files=$(git diff --name-only --diff-filter=ACM origin/main...HEAD -- '*.swift')
[ -z "$files" ] || swiftlint lint --strict $files
```

**Installation friction.** Two patterns dominate in 2026 Swift OSS:

1. **Vendored hook + opt-in install script.** A `scripts/install-hooks.sh`
   that copies `scripts/git-hooks/pre-push` into `.git/hooks/`. Cheap,
   no new dependency, but easy to forget.
2. **Lefthook.** Per WebFetch of `https://github.com/evilmartians/lefthook`:
   "Fast and powerful … single dependency-free binary which can work in any
   environment." Installable via `brew install lefthook`. Config example:
   ```yaml
   pre-push:
     jobs:
       - name: lint swift files
         glob: "*.swift"
         run: swiftlint {all_files}
   ```
   Adds one Homebrew dependency to onboarding.

Husky (Node) and pre-commit (Python) both add a runtime nobody on a Swift
project wants. They're common in mixed repos but overkill here.

**`--strict` at the hook stage.** Yes. The whole point of the hook is to
fail loudly before push. `swiftlint --strict` (warnings → errors) is the
correct severity at the hook layer; the build-tool plugin can run
non-strict locally so iterative work isn't blocked.

### Recommendation

Ship a **vendored pre-push hook** (`scripts/git-hooks/pre-push`) plus a
**`scripts/install-hooks.sh` one-liner**, mentioned in CLAUDE.md.
Skip Lefthook in PR1 — adding a tool nobody else uses to onboard a
two-line bash script isn't worth it. Reconsider only if we add more
hooks (commit-msg lint, formatters, etc.).

The hook should:
- diff against `origin/main` (the merge target, not `HEAD~1`),
- run `swiftlint lint --strict --quiet` on changed files,
- short-circuit cleanly when zero `.swift` files changed,
- print the install path of the swiftlint binary it found, so contributors
  see whether it's the SPM-bundled one or a stale Homebrew install.

The hook should call `swift package plugin --allow-writing-to-package-directory swiftlint`
(the command plugin) to reuse the SPM-bundled binary — that way pre-push
works for contributors who never `brew install`ed swiftlint.

---

## 4. Custom rule: `no_print_in_sources`

From the SwiftLint README's "Defining Custom Rules" section (fetched via
WebFetch of the README on `realm/SwiftLint`, 2026-05-13):

> ```yaml
> custom_rules:
>   pirates_beat_ninjas:
>     included:
>       - ".*\\.swift"
>     excluded:
>       - ".*Test\\.swift"
>     name: "Pirates Beat Ninjas"
>     regex: "([nN]inja)"
>     capture_group: 0
>     match_kinds:
>       - comment
>       - identifier
>     message: "Pirates are better than ninjas."
>     severity: error
> ```

Important regex notes from the same source:

> The regular expression pattern is used with the flags `s` and `m` enabled,
> that is `.` matches newlines and `^`/`$` match the start and end of lines,
> respectively.
>
> To prevent `.` from matching newlines, the regex can be prepended by `(?-s)`.

`included`/`excluded` in custom_rules take **regex patterns** (not globs)
matched against the file path. The top-level `included:` / `excluded:` keys
of `.swiftlint.yml` take **path globs** — different syntax. This is the
single biggest custom_rules footgun and worth a comment in our YAML.

`match_kinds` filters by SourceKit syntax kind. Setting it to a list that
**excludes `string` and `comment`** ensures we don't false-positive on
`"print(x)"` inside a string literal or `// print()` in a comment.

### Working snippet (verified against above schema)

```yaml
# .swiftlint.yml — at repo root

# Top-level included/excluded use GLOB syntax.
included:
  - Sources
  - Tests

excluded:
  - .build
  - Tests             # tests are allowed to print

custom_rules:
  no_print_in_sources:
    name: "No print() in Sources/"
    # included/excluded HERE use REGEX (not glob) matched against file paths.
    included:
      - "Sources/.*\\.swift"
    excluded:
      - "Sources/.*Tests?\\.swift"   # belt + braces; Tests/ already excluded above
    # Matches `print(`, `Swift.print(`, and `Foundation.print(` at the start
    # of a token — but only when SourceKit classifies the token as a normal
    # identifier (not a string or comment).
    regex: '\b(?:Swift\.|Foundation\.)?print\s*\('
    match_kinds:
      - identifier
    message: "Use os.Logger instead of print() in Sources/. See CLAUDE.md."
    severity: error
```

Notes:

- The regex deliberately covers `Swift.print(` and `Foundation.print(` —
  CLAUDE.md is unambiguous that *no* `print()` belongs in `Sources/`.
  Rationale: someone smart enough to write `Swift.print` to "bypass" the
  rule has clearly read it and chosen to violate it.
- `match_kinds: [identifier]` keeps the rule from yelling at the literal
  string `"print("` inside docstrings or fixture data. This matters
  because `Sources/TBDApp/Markdown/...` fixtures may contain code samples.
- Severity `error` — warning gets ignored by humans and CI alike.

We also need a deliberate **opt-out path** for genuine CLI output. Two
choices:
1. `// swiftlint:disable:next no_print_in_sources` on the call site.
2. Wrap output in a tiny shim (`CLIOutput.write(...)`) — better long-term.

The current `Sources/TBDCLI/` has many `print()` calls (verified locally
via `grep`). The PR adopting SwiftLint will need a transitional plan:
either route them through a shim, or sprinkle disable comments and file a
follow-up to clean up. **Lean toward the shim** — TBDCLI's prints are
already centralized in `Utilities.swift` and thin command files, so this
is a one-day refactor, not a multi-week one.

### Recommendation

Ship the `no_print_in_sources` rule above. Pair it with a same-PR refactor
that introduces a `CLIOutput` shim in `TBDCLI/Utilities.swift` and routes
all existing `print()` calls through it (the shim itself uses
`FileHandle.standardOutput.write(...)`, not `print`, so the rule is
satisfied). This keeps the rule clean of disable comments from day one.

---

## 5. Other low-friction high-value rules

Default-enabled rules already cover a lot (verified via WebFetch of
`https://realm.github.io/SwiftLint/rule-directory.html`). Recommendations
for explicit handling:

| Rule | Default? | PR1 vs. punt | Rationale |
|---|---|---|---|
| `force_try` | default | **PR1, severity error** | Already on; just bump severity. Hard rule = no `try!` in TBD. |
| `force_cast` | default | **PR1, severity error** | Same — `as!` is always a bug waiting to happen. |
| `force_unwrapping` | opt-in | **Punt to PR2** | Will surface dozens of existing violations across `TBDApp/` SwiftUI bindings. Worth doing, but separately. |
| `weak_delegate` | opt-in | **PR1** | Catches retain cycles; near-zero false positives in our code. |
| `redundant_optional_initialization` | default | **PR1** | Already on; nothing to do. |
| `line_length` | default (warn at 120) | **PR1, raise to 140 warn / 200 error** | Strict 120 will fight SwiftUI view bodies. 140/200 matches Apple sample style. |
| `function_body_length` | default | **PR1, relax** | Default 40-line warn fires constantly on SwiftUI; bump to 80/150. |
| `file_length` | default | **PR1, relax to 600/1000** | Several existing files are 500+ legitimately. |
| `identifier_name` | default | **Punt or disable** | Will fight our 2-letter generics (`U`, `T`) and acronyms (`PR`, `ID`). Disable or set `min_length: 1`. |
| `type_name` | default | **PR1 keep** | Catches genuinely odd type names. |
| `todo` | default | **Disable** | We use `TODO:` deliberately in the codebase. |

**Top-level config strategy.** Three philosophies in the wild:

1. **All defaults + targeted `disabled_rules:`** — minimum config, picks
   up new defaults automatically on SwiftLint upgrades. Risk: a new
   default rule lands in 0.64.0 that fires 200x.
2. **`only_rules:`** — explicit allowlist. Maximum determinism, maximum
   maintenance burden.
3. **Defaults + `opt_in_rules:` for extras** — most common in mature
   Swift OSS (e.g. swift-format, Apple sample apps).

### Recommendation

Go with **option 3**: defaults + a small `opt_in_rules:` list (`weak_delegate`
plus a few others over time) + `disabled_rules:` for the few defaults that
clash with our codebase (`todo`, `identifier_name`). Keep the file under
~50 lines in PR1; let it grow organically.

Use `swiftlint --strict` in CI but plain `swiftlint` (warnings allowed) at
`swift build` time, so contributors aren't blocked from running their code
during iteration but still see the warnings inline in Xcode/`swift build`
output.

---

## 6. GitHub Actions integration

Current state of `.github/workflows/`:

- `test.yml` — `macos-15` runner, restores SPM cache, runs `swift test --parallel` then `swift build`.
- `recipe-check.yml` — only runs on `recipe/**` changes.
- `claude-code-review.yml`, `claude.yml` — Claude reviewer.

Two integration options:

**Option A: append to `test.yml`.** Add one step before `swift test`:
```yaml
- name: SwiftLint (strict)
  run: swift package plugin --allow-writing-to-package-directory swiftlint --strict
```
Pros: reuses checkout, SPM cache, runner. No new workflow YAML. Single
source of truth for "did this PR pass CI".
Cons: lint failure blocks the test signal you might also want.

**Option B: separate workflow `lint.yml`.** Pros: independent failure
signal; runs in parallel. Cons: another `macos-15` minute on every PR;
duplicates checkout+cache; need to keep two workflows in sync re: triggers.

**On the official-action question.** The most popular GHA for SwiftLint
(`norio-nomura/action-swiftlint`, version 3.2.1) was last released
**2020-11-25** per its repo. Linux-only, Docker-based, unmaintained.
Skip it.

The realm/SwiftLint repo does not publish an official GitHub Action. The
canonical "official" path on macOS is `brew install swiftlint && swiftlint
--strict`, but since we're already adopting the SPM plugin, the
`swift package plugin swiftlint --strict` invocation reuses the same
binary CI is going to download anyway (no extra Homebrew step, no
version skew with local).

### Recommendation

**Option A — append to `test.yml`.** Add a `SwiftLint` step that runs
**before** `swift test`. Use the SPM command plugin (`swift package plugin
swiftlint --strict`) so CI uses the exact same binary version pinned in
`Package.resolved` — no Homebrew, no skew. The build-tool plugin will
*also* run during `swift test`/`swift build`, but a dedicated `--strict`
step gives a cleaner failure message than a build-step warning buried in
`xcbeautify`-less SPM output.

Skip the `norio-nomura/action-swiftlint` action — unmaintained since 2020.

---

## Putting it together

The implementation PR will need to:

1. Add `SimplyDanny/SwiftLintPlugins` 0.63.2 to `Package.swift` deps and
   attach `SwiftLintBuildToolPlugin` to the four real-code targets.
2. Add a ~50-line `.swiftlint.yml` at repo root with the `no_print_in_sources`
   custom rule, the rule-tuning from §5, and `included: [Sources, Tests]`.
3. Refactor `TBDCLI` to route prints through a `CLIOutput` shim so the new
   rule has zero baseline violations.
4. Add `scripts/git-hooks/pre-push` + `scripts/install-hooks.sh` and
   document in CLAUDE.md.
5. Add one `SwiftLint (strict)` step to `.github/workflows/test.yml` before
   `swift test`.
6. Update CLAUDE.md to mention `swift package plugin swiftlint` and the
   pre-push hook install command.

PR size: **medium**. The plugin/config/CI bits are mechanical; the TBDCLI
shim refactor and disable-comment cleanup is where the real work lives.
