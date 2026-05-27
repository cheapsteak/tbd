# User custom terminal themes — design

**Status:** Drafted, pending user review
**Date:** 2026-05-27
**Branch:** `user-custom-themes`
**Related:** PR #190 (added 7 bundled light themes), PR #225 (COLORFGBG broadcast on scheme change)

## Problem

TBD bundles 15 terminal color schemes (8 dark + 7 light) baked into the Swift binary at `Sources/TBDApp/Terminal/ColorSchemes.swift`. Users who want a scheme that isn't bundled have to either submit a PR or live without. There's no way to:

- Import an existing scheme they like from a popular format (Alacritty TOML).
- Tweak an existing scheme's bright-black, accent, or background and save it as their own.
- Manage a personal palette across machines via dotfiles.

## Goals

- Let users **tweak any scheme's 20 color slots** (16 ANSI + foreground / background / cursor / selection) in a built-in editor. Editing diverges into an in-memory draft; the user decides to Save as a new user theme, Save (overwrite, user themes only), or Reset.
- Let users **import an Alacritty TOML** file (the de-facto modern theme distribution format) and have it appear as a selectable scheme.
- Persist user themes to the filesystem in a portable JSON format so they can be shared, version-controlled in a dotfiles repo, and inspected with `cat`.
- Live-preview every edit in all open terminal panes; debounced disk writes; explicit Save/Revert.
- Compose cleanly with the existing scheme-switch machinery: COLORFGBG broadcast (#225), Combine-driven `TBDTerminalView` repaints, the Settings → Terminal picker.

## Non-goals

- iTerm2 `.itermcolors`, Kitty `.conf`, Ghostty `.conf` importers. (Each is a follow-up parser if/when demanded.)
- Export to Alacritty TOML. (Workaround: the JSON file itself is portable; share it.)
- Sharing UI, cloud sync, theme marketplace.
- Per-pane or per-worktree theme override; scheme remains app-global.
- Auto-switch theme based on macOS appearance. (Could compose nicely with this work later — out of scope here.)
- Editing **bundled** themes. They're read-only; Duplicate is the only path to mutation.

## Architecture

### Filesystem as source of truth

User themes live in `~/tbd/terminal-themes/`, one JSON file per theme. The directory name explicitly scopes to "terminal" because these themes only affect the terminal renderer's colors — not the SwiftUI app chrome (sidebar, toolbar, etc.). Deleted themes move to `~/tbd/terminal-themes/.trash/<id>-<timestamp>.json` (soft delete; a future "undo" affordance can mine it).

### `ThemeStore`

A new `@MainActor` singleton in `Sources/TBDApp/Terminal/ThemeStore.swift`:

- Enumerates `~/tbd/terminal-themes/*.json` at launch, decodes each, holds an `[id: TerminalColorScheme]` dict.
- Watches the directory via the macOS `FSEventStream` API (CoreServices) so external edits — `vim ~/tbd/terminal-themes/foo.json`, `cp` of a file from a teammate, `git pull` of a dotfiles repo — appear in the picker without restarting the app.
- Publishes changes via a `@Published var userThemes: [TerminalColorScheme]`. Consumers (`TerminalSettingsView`, `ColorSchemes.scheme(forID:)`) react via Combine.

### Resolution: `ColorSchemes.scheme(forID:)` extended

Today `ColorSchemes.scheme(forID:)` looks up only the static `bundled` array. The extension:

1. Check `bundled` first (bundled IDs are reserved).
2. Fall back to `ThemeStore.userThemes`.
3. Fall back to `defaultScheme` (Tango).

Collisions where a user file's `id` matches a bundled id are skipped at load time with a logged warning. The user can't shadow `gruvbox-dark`; the editor enforces this at save time.

### Live edit flow — clone-on-change

There is no explicit "enter editing mode" gesture. The editor is always visible below the picker, showing the selected scheme's current colors with editable fields. The flow is:

1. The user has any scheme selected (bundled or user). The editor displays its colors.
2. The user changes any field — a hex value, an `NSColorWell`, the name. The moment a field diverges from the saved/bundled source, the editor view-model enters **draft mode**: it holds an in-memory copy of the scheme that overrides the source for live preview. The picker label gets a "— Draft" suffix while drafting.
3. The draft is bound to every hex-text-field / `NSColorWell` slot. Mutations publish via `AppearanceSettings`'s existing `@Published` path → all `TBDTerminalView` instances re-render immediately. Same plumbing already used for scheme switching, just at finer granularity.
4. No disk write happens during drafting — the draft is in-memory only. Disk writes are explicit, triggered by Save / Save as….
5. Action buttons at the bottom of the editor adapt to source type:
   - **Bundled source, drafting:** `[ Save as… ]` `[ Reset ]`. Bundled themes are immutable — Save as is the only way to persist.
   - **User-theme source, drafting:** `[ Save ]` `[ Save as… ]` `[ Reset ]`. Save overwrites the existing `<id>.json` in place; Save as creates a new file alongside.
   - **No draft:** `[ Save as… ]` only — verbatim clone of the current source into a new user theme. This replaces the old "Duplicate" button cleanly.
6. **Save as…** opens a small dialog pre-filled with `"{Source displayName} Copy"` (or just the current name field if the user has edited it). On confirm, `ThemeStore` writes `<slug>.json`, switches `AppearanceSettings.schemeID` to the new id, draft state ends. The slug appends `-2`, `-3` etc. for re-clones.
7. **Save** (user-theme drafts only) writes the draft back to the existing `<id>.json`; draft state ends; picker label loses the "— Draft" suffix.
8. **Reset** discards the in-memory draft; panes snap back to the saved source colors; `schemeID` unchanged.
9. Switching to another scheme in the picker, or another Settings tab, while a draft is unsaved → confirm dialog. For bundled-source drafts: *"You have unsaved changes to Gruvbox Dark. Save as new theme / Discard / Cancel."* For user-source drafts: *"You have unsaved changes to My Gruvbox. Save / Save as… / Discard / Cancel."*
10. Quitting the app with an unsaved draft → same confirm. (No autosave for drafts; they're ephemeral by design.)

### COLORFGBG continuity

The existing broadcast path from PR #225 (`AppState.broadcastAppearanceColorFgBg` → `appearance.updateColorFgBg` RPC → `tmux setenv -g COLORFGBG`) re-fires on every scheme change, debounced. Live-editing the active theme's `background` is "just another scheme change" from that path's perspective — no new code, no new tests needed for COLORFGBG behavior. The bundled and user-theme code paths converge on `AppearanceSettings.currentColorFgBg` which already takes a `TerminalColorScheme`.

## JSON schema

```json
{
  "schemaVersion": 1,
  "id": "my-gruvbox",
  "displayName": "My Gruvbox",
  "ansi": [
    "#282828", "#cc241d", "#98971a", "#d79921",
    "#458588", "#b16286", "#689d6a", "#a89984",
    "#928374", "#fb4934", "#b8bb26", "#fabd2f",
    "#83a598", "#d3869b", "#8ec07c", "#ebdbb2"
  ],
  "foreground": "#ebdbb2",
  "background": "#282828",
  "cursor": "#ebdbb2",
  "selection": "#3c3836"
}
```

- `schemaVersion` (int): forward-compat; lets us add fields later without breaking old files.
- `id` (string): canonical handle stored in `UserDefaults` (`terminal.scheme.id`); must match `^[a-z0-9-]+$` and not collide with a bundled id.
- `displayName` (string): free-form Unicode; what shows in the picker.
- `ansi` (array of 16 strings): lowercase 7-char hex (`#rrggbb`).
- `foreground`, `background`, `cursor`, `selection` (string): same hex format.
- Filename = `<id>.json`. Slug derived from `displayName` on Duplicate when the user hasn't customized the id.

All fields required. No optional fields in v1 — keeps validation simple.

## Alacritty TOML → TBD JSON mapping

The importer (a new `AlacrittyThemeImporter`) parses one of the canonical Alacritty section layouts:

| Alacritty section + key | TBD JSON field |
| --- | --- |
| `[colors.primary]` `foreground` | `foreground` |
| `[colors.primary]` `background` | `background` |
| `[colors.cursor]` `cursor` (fallback: `text`) | `cursor` |
| `[colors.selection]` `background` | `selection` |
| `[colors.normal]` `black`/`red`/`green`/`yellow`/`blue`/`magenta`/`cyan`/`white` | `ansi[0..7]` |
| `[colors.bright]` same 8 names | `ansi[8..15]` |

Many published Alacritty configs (Catppuccin Latte/Mocha, Flexoki, Rosé Pine variants) intentionally make `[colors.bright]` identical to `[colors.normal]`. The importer copies both halves verbatim — no special-casing.

Missing required sections → import fails with a specific, actionable error: *"`[colors.normal]` section not found; this doesn't look like an Alacritty colors config."* No silent fallback.

The Import button in Settings → Terminal opens a file picker filtered to `.toml`. On successful parse, the importer writes the converted JSON to `~/tbd/terminal-themes/<slug>.json` and `ThemeStore`'s FSEvents watcher does the rest (the new theme appears in the picker without further action).

Foreign-format files dropped directly into `~/tbd/terminal-themes/` (e.g. a `.toml` file) are ignored — only `.json` is loaded. To consume a foreign file in the dir, the user goes through Import (which converts).

## Editor UX

Inline expansion in Settings → Terminal — same tab as the scheme picker; the editor is always visible beneath the picker, showing the selected scheme's colors. There is no separate "edit" gesture; touching any field starts a draft. ASCII layout (showing a draft of a bundled scheme — the most common entry point):

```
Settings  >  Terminal
----------------------------------------------
Scheme:    [ Gruvbox Dark — Draft        v ]
           [ Import… ]

+--------- Editing: Gruvbox Dark -----------+
| Name:  [ Gruvbox Dark                  ]   |
|                                            |
| Foreground   [ #ebdbb2 ]  ◼                |
| Background   [ #282828 ]  ◼                |
| Cursor       [ #ebdbb2 ]  ◼                |
| Selection    [ #3c3836 ]  ◼                |
|                                            |
| ANSI 0-7   ◼  ◼  ◼  ◼  ◼  ◼  ◼  ◼          |
| ANSI 8-15  ◼  ◼  ◼  ◼  ◼  ◼  ◼  ◼          |
|                                            |
| (changes apply live to all panes)          |
|                                            |
|             [ Save as… ]   [ Reset ]       |
+--------------------------------------------+

Font family:    [ SF Mono              v ]
Font size:      [ 12 ]
(rest of Terminal settings below)
```

For a user theme being drafted, the action bar becomes `[ Save ] [ Save as… ] [ Reset ]` and a `[ Delete ]` appears next to `[ Import… ]` above the editor. When no draft is in progress, the action bar collapses to just `[ Save as… ]` — a one-click "fork this scheme into a new user theme" affordance that replaces the old explicit Duplicate button.

Each color slot is a **hex text field + `NSColorWell`** pair, two-way bound. Hex is power-user copy-pasteable; the NSColorWell opens the standard macOS color panel for users who'd rather pick visually. The ANSI rows compress to swatch-only (with hover-tooltips showing the role name + hex) to keep vertical space tight.

`[ Save ]`, `[ Save as… ]`, and `[ Reset ]` only appear when relevant per the rules above. The Name field is editable in both no-draft and drafting states; editing it counts as a draft change just like a color edit.

## Validation & edge cases

| Situation | Behavior |
| --- | --- |
| Malformed JSON in a `~/tbd/terminal-themes/*.json` file | Skip the file, log a warning (`os.Logger`, category `themes`), surface a "*N* theme(s) failed to load — see logs" banner at the top of Settings → Terminal |
| Missing required field (e.g. `ansi` has 12 entries) | Same as malformed |
| User file's `id` collides with a bundled id | Skip with logged warning; bundled wins. Editor's Save also refuses such an id (form-level validation). |
| Two user files with the same `id` | First one encountered wins (load order is implementation-defined); both files get a logged warning naming the conflicting filenames. In practice this only happens if a user manually copies a file without changing the inner `id`; the editor would never produce this state. |
| `id` field absent | Slugify from `displayName`; the field gets persisted on the next save |
| Invalid hex string (`#abcd`, `red`, `0xffffff`) | Field fails validation; Save disabled while invalid; offending field gets a red border + tooltip |
| Active theme's file is deleted externally (`rm`) | FSEvents → `ThemeStore` drops the entry → `schemeID` reverts to default (Tango); banner surfaces |
| Active theme's file is mutated externally | Reload, panes repaint via the existing publisher chain. No editor-state collision because editing-state is only entered via the in-app Duplicate button; an externally-edited file is "the new saved truth." If the user is editing in the app *and* something mutates the file from outside, the in-app draft wins until Save / Revert. |
| Save as… while drafting a bundled `gruvbox-dark` | Dialog pre-fills with `"Gruvbox Dark Copy"`; on confirm a new `gruvbox-dark-copy.json` (or `-copy-2`, `-copy-3` for re-clones) is written and `schemeID` switches to it |
| Save as… on a no-draft bundled scheme | One-click "verbatim clone" — same path as above, the draft just happens to equal the source |
| Quit / app crash with an unsaved draft | Draft is in-memory; lost on next launch. No autosave. Confirm dialog on user-initiated quit. |
| Delete an active user theme | Confirm dialog → on confirm, file moves to `.trash/<id>-<timestamp>.json`, `schemeID` → `tango`, banner offers a (future) undo affordance |

## Testing plan

Per CLAUDE.md "branching conditional needs a test for each branch":

- **`ThemeStoreTests`**
  - Round-trip a JSON file (write → enumerate → read → equality).
  - FSEvents-driven reload: write a file under `TBD_HOME`-isolated tmp, expect `userThemes` to update.
  - Collision avoidance on Save as…: invoke Save as twice against `gruvbox-dark` → second file is `gruvbox-dark-copy-2.json`.
  - Draft → Reset reverts in-memory state without touching disk (no file written, source scheme intact).
  - Delete-active fallback to Tango: write a user file, set `schemeID` to it, move the file → expect `schemeID == "tango"`.
- **`AlacrittyImporterTests`**
  - Feed canonical TOMLs from `catppuccin/alacritty`, `rose-pine/alacritty`, `folke/tokyonight.nvim` (committed as `Tests/TBDAppTests/Fixtures/alacritty/*.toml`).
  - Assert resulting `TerminalColorScheme` matches the expected hex tuple.
  - One malformed TOML missing `[colors.normal]` → expect a typed `AlacrittyImporter.Error.missingSection` with a message containing `"[colors.normal]"`.
- **`ColorSchemes.scheme(forID:)` branch coverage** (extending the existing tests)
  - Bundled-only lookup (existing behavior preserved).
  - User-only lookup (new branch).
  - Bundled-vs-user collision → bundled wins (new branch).
- **No SwiftUI view tests for the editor.** This codebase doesn't reliably exercise SwiftUI views in test; the `ThemeStore` + importer tests cover all the data-layer correctness. Editor wiring is verified manually per the existing project convention.

All tests use `setenv("TBD_HOME", ...)` isolation per CLAUDE.md, and `UserDefaults(suiteName:)` if they touch `AppearanceSettings`.

## File list (proposed)

New:
- `Sources/TBDApp/Terminal/ThemeStore.swift`
- `Sources/TBDApp/Terminal/UserTerminalTheme.swift` (the Codable struct + JSON encode/decode)
- `Sources/TBDApp/Terminal/AlacrittyImporter.swift`
- `Sources/TBDApp/Settings/TerminalThemeEditorView.swift` (the inline editor SwiftUI view)
- `Tests/TBDAppTests/ThemeStoreTests.swift`
- `Tests/TBDAppTests/AlacrittyImporterTests.swift`
- `Tests/TBDAppTests/Fixtures/alacritty/{catppuccin-latte,rose-pine-dawn,tokyonight-day}.toml`

Modified:
- `Sources/TBDApp/Terminal/ColorSchemes.swift` — extend `scheme(forID:)` to consult `ThemeStore`
- `Sources/TBDApp/Terminal/AppearanceSettings.swift` — pick up `ThemeStore` for the active scheme lookup; no other API change
- `Sources/TBDApp/Settings/TerminalSettingsView.swift` — Duplicate / Delete / Import buttons + embed `TerminalThemeEditorView`
- `Sources/TBDShared/CLAUDE.md` (if any new path constant lands in `TBDConstants`) — mention `~/tbd/terminal-themes/`

## Open questions for future work (explicitly deferred)

- **Auto-switch theme on macOS appearance change.** Bind a "light scheme" + "dark scheme" pair, follow the OS. Composes naturally with COLORFGBG broadcast (the broadcast already re-fires on the new bg). Out of scope here.
- **iTerm2 `.itermcolors` import.** XML plist; trivial to add a second importer once the converted-JSON pipeline is in place.
- **Export to Alacritty TOML.** Symmetric with import; nice-to-have for users who want to round-trip TBD themes back to other terminals.
- **Theme search / filter** in the picker once the list grows past ~20 entries.

