# Terminal Appearance Customization — v1 Design

**Status:** Design approved, pending user spec review
**Date:** 2026-05-16
**Branch:** `customize-terminal-appearance`

## Summary

Expose four terminal-appearance settings, scoped globally via `@AppStorage`-style persistence, applied live to every open terminal pane:

1. **Font family + size** (via the native macOS Font Panel)
2. **Color scheme** (8 bundled, dropdown)
3. **Cursor style** (block / underline / bar × steady / blink, single dropdown)
4. **Caret color** (defined by the active color scheme — no separate setting)

Settings live in a new **Terminal** tab in `SettingsView`. The existing "Auto-resize tmux windows" toggle relocates into this tab.

## Motivation

TBD currently exposes none of SwiftTerm's appearance knobs. Users running TBD all day cannot match the font, size, or color scheme they use elsewhere (iTerm, Ghostty, VS Code's integrated terminal). Anti-aliasing, ligatures, and per-tab profiles are out of scope for v1 (see "Deferred").

## Architecture

### New files

- `Sources/TBDApp/Terminal/AppearanceSettings.swift` — `final class AppearanceSettings: ObservableObject`, singleton-style instance owned at app root, injected as `@EnvironmentObject`. Properties:
  - `@Published var fontName: String` (default: `NSFont.monospacedSystemFont(...)`'s `fontName`)
  - `@Published var fontSize: CGFloat` (default: `12.0`)
  - `@Published var schemeID: String` (default: `"tango"`)
  - `@Published var cursorStyle: SwiftTerm.CursorStyle` (default: `.blinkBlock`)
  - Each property's `didSet` writes the new value to `UserDefaults` under keys `terminal.font.name`, `terminal.font.size`, `terminal.scheme.id`, `terminal.cursor.style`.
  - `init()` reads from `UserDefaults` with fallback to defaults on missing/invalid values.
  - Computed `var font: NSFont`: `NSFont(name: fontName, size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize)`.

- `Sources/TBDApp/Terminal/ColorSchemes.swift` — value-type definitions:
  ```swift
  struct TerminalColorScheme {
      let id: String
      let displayName: String
      let ansi: [SwiftTerm.Color]      // 16 colors
      let foreground: SwiftTerm.Color
      let background: SwiftTerm.Color
      let cursor: SwiftTerm.Color
      let selection: SwiftTerm.Color
  }

  enum ColorSchemes {
      static let bundled: [TerminalColorScheme] = [
          tbdDefault, tango, solarizedDark, tomorrowNight,
          dracula, nord, oneDark, gruvboxDark
      ]
      static func scheme(forID id: String) -> TerminalColorScheme {
          bundled.first { $0.id == id } ?? tbdDefault
      }
      // Each scheme defined as a static let with hardcoded RGB values.
  }
  ```
  All 8 schemes are compiled-in struct literals — no JSON, no plist, no I/O. The `tango` scheme is the dark variant of the user's iTerm profile (RGB values transcribed from `guake.json`'s `Ansi N Color (Dark)` / `Background Color (Dark)` / `Foreground Color (Dark)` / `Cursor Color (Dark)` entries).

- `Sources/TBDApp/Settings/TerminalSettingsView.swift` — new tab body. Components:
  - "Font" row: label showing current font + size (e.g. "SF Mono 12"), "Choose Font…" button that opens `NSFontPanel` via `NSFontManager.shared.orderFrontFontPanel(self)`. The view conforms to a `NSFontChanging` delegate; in `changeFont(_:)` it reads the chosen font and writes onto `AppearanceSettings`.
  - "Color Scheme" row: `Picker` bound to `$settings.schemeID`, options enumerated from `ColorSchemes.bundled`. Each row shows the display name (no swatch preview in v1; can add later).
  - "Cursor Style" row: `Picker` bound to `$settings.cursorStyle` with rows: "Block" / "Block (blinking)" / "Underline" / "Underline (blinking)" / "Bar" / "Bar (blinking)".
  - "Experimental" section at the bottom containing the relocated `enableTerminalAutoResize` toggle.

### Modified files

- `Sources/TBDApp/Settings/SettingsView.swift` — add a 4th `tabItem` for "Terminal" with the `terminal` SF Symbol. Remove the `enableTerminalAutoResize` toggle and its Experimental section from `GeneralSettingsTab`.

- `Sources/TBDApp/Terminal/TBDTerminalView.swift`:
  - Accept `AppearanceSettings` in `init`.
  - Store a `Set<AnyCancellable>` for Combine subscriptions.
  - Subscribe to `settings.objectWillChange` in `init`; on receive, debounce via `DispatchQueue.main.async` and call `applyAll()`.
  - Call `applyAll()` once at the end of `init`, before tmux attach.
  - New private methods:
    - `applyFont()` — sets `self.font = settings.font`. SwiftTerm internally rederives bold/italic and recomputes cell metrics.
    - `applyScheme()` — `let scheme = ColorSchemes.scheme(forID: settings.schemeID)`; calls `installColors(scheme.ansi)`, sets `nativeForegroundColor`, `nativeBackgroundColor`, `caretColor = scheme.cursor`, `selectedTextBackgroundColor = scheme.selection`.
    - `applyCursor()` — `terminal.setCursorStyle(settings.cursorStyle)`.
  - After `applyFont()`, ensure pane resize fires (see "Tmux pane resize" below).

- `Sources/TBDApp/Terminal/TerminalPanelView.swift`, `TerminalContainerView.swift` — pipe `AppearanceSettings` through to `TBDTerminalView` init via `@EnvironmentObject`.

- `Sources/TBDApp/TBDApp.swift` (or the `@main` entry) — instantiate `let appearance = AppearanceSettings()` and apply `.environmentObject(appearance)` to the root view.

- `Sources/TBDApp/AppState.swift` — currently calls `TBDTerminalView.cellDimensions(for:)` statically to compute rows/cols from `mainAreaSize`. These call sites need the **current** font from `AppearanceSettings`, not `TBDTerminalView.defaultMonospaceFont`. Either:
  - Hold a weak reference to `AppearanceSettings` on `AppState`, or
  - Pass `currentFont` as a parameter at the call sites.
  Choose whichever pattern matches existing AppState dependency injection. Two or three call sites — verify via `grep "cellDimensions" Sources/`.

## Data flow

### Set path

1. User opens Settings → Terminal tab.
2. **Font:** clicks "Choose Font…" → `NSFontManager` panel opens. User picks. `changeFont(_:)` callback reads `convert(…)` result, writes `fontName` + `fontSize` onto `AppearanceSettings`.
3. **Scheme / cursor:** `Picker` is bound to a `Binding<String>` / `Binding<CursorStyle>` derived from `AppearanceSettings` `@Published` properties. Selection mutates the property.
4. `didSet` on each property persists to `UserDefaults`. `objectWillChange` fires.

### Apply path

1. Each live `TBDTerminalView` has a `settings.objectWillChange.sink { [weak self] _ in ... }` subscription.
2. Sink callback dispatches `applyAll()` via `DispatchQueue.main.async` (debounces rapid multi-property publishes into one apply).
3. `applyAll()` calls `applyFont()`, `applyScheme()`, `applyCursor()` in that order.
4. `applyFont()` triggers SwiftTerm's internal cell-dim recompute → `sizeChanged(source:newCols:newRows:)` fires on the delegate → existing TBD code path forwards the new dims to the tmux pane.

### Init path

`TBDTerminalView.init` calls `applyAll()` once before tmux attach, so the first render uses the user's settings.

### Failure modes

- Missing/invalid font name → `NSFont(name:size:)` returns `nil` → fallback to `NSFont.monospacedSystemFont(ofSize:)`.
- Unknown `schemeID` → `ColorSchemes.scheme(forID:)` returns `tbdDefault`. UserDefaults stays as-is (user can re-pick; no auto-correction).
- Unknown cursor style raw value → init fallback to `.blinkBlock`.
- No crashes, no migrations needed (v1 is additive: new keys, existing UserDefaults unaffected).

## Tmux pane resize on font change

Cell dimensions change when the font changes; the tmux pane must resize to match the new rows/cols-per-pixel-area.

- **Existing infra:** `TBDTerminalView.cellDimensions(for:)` (Sources/TBDApp/Terminal/TBDTerminalView.swift:58-63) already computes from any `NSFont`. `AppState` has `mainAreaSize`. SwiftTerm fires `sizeChanged` on its delegate after internal reflow.
- **Verification needed during implementation:** confirm `sizeChanged` actually fires when only `font` is set (not just on view bounds change). If it does, the existing delegate forwards the new dims to the daemon and we're done.
- **If `sizeChanged` does not fire on font-only change:** after `applyFont()`, manually call the existing "send pane resize" path with `cellDimensions(for: settings.font)` against `self.bounds.size`.
- **Auto-resize toggle does not gate this.** Even when `enableTerminalAutoResize` is off (default), font changes must always forward a one-shot pane resize — otherwise the visible region clips at the bottom.
- **AppState pre-spawn rows/cols** (the static `cellDimensions(for:)` callers) must use `AppearanceSettings.font`, not `defaultMonospaceFont`, so newly spawned panes start at correct dims.

## Bundled color schemes

| ID | Display name | Notes |
|---|---|---|
| `tbd-default` | TBD Default | Current SwiftTerm defaults — included so existing-look is selectable |
| `tango` | Tango | **Default on fresh install.** Dark variant of the user's iTerm profile (Tango palette: olive green, amber, dusty blue, brick red, muted purple, deep teal on black). |
| `solarized-dark` | Solarized Dark | Ethan Schoonover palette |
| `tomorrow-night` | Tomorrow Night | Chris Kempson palette |
| `dracula` | Dracula | High-contrast classic |
| `nord` | Nord | Cool low-saturation |
| `oneDark` | One Dark | Atom / VS Code default dark |
| `gruvbox-dark` | Gruvbox Dark | Warm retro |

Specific RGB values for non-Tango schemes will be transcribed from each scheme's canonical published palette during implementation.

## Default scheme on fresh install

**Tango.** Existing TBD users will see a visual change on next launch (white text on black, with the Tango ANSI palette). Acceptable given the feature is new — users can switch back to "TBD Default" from the new Settings tab.

No "Reset to Defaults" button in v1.

## Testing

### Automated (`swift test`)

- `AppearanceSettings` round-trip: write each property, read back from a fresh instance against the same `UserDefaults`, verify match.
- `AppearanceSettings` fallback: poison each UserDefaults key (bad font name, unknown scheme id, unknown cursor raw value), verify init returns the documented default.
- `ColorSchemes.bundled` invariants: every scheme has exactly 16 ANSI colors; every `id` is unique; every scheme is reachable via `scheme(forID:)`.
- `ColorSchemes.scheme(forID: "bogus")` returns `tbdDefault`.

### Manual verification (golden path)

- Settings → Terminal → change font to Menlo 14 → every open pane updates live; tmux content reflows; no bottom-clipping.
- Cycle through all 8 schemes → colors update live; `ls --color`, `git status`, `vim`'s syntax all reflect new ANSI palette.
- Cycle through all 6 cursor variants → caret shape and blink update live.
- Quit + relaunch → settings persist.

### Manual verification (edge cases)

- `defaults write com.tbd.app terminal.scheme.id bogus` → relaunch shouldn't crash; falls back to `tbd-default`.
- `defaults write com.tbd.app terminal.font.name NotARealFont` → relaunch shouldn't crash; falls back to system mono.
- Font change with `top` or `vim` running in the pane → no garbled redraw, content reflows.
- Delete `~/Library/Preferences/com.tbd.app.plist` (or run `defaults delete com.tbd.app`) → all four settings restore to factory.

### Branch coverage

This feature has no on/off flag — the Terminal tab is always present. If reviewer feedback adds one, add tests for both branches per [CLAUDE.md](/Users/chang/tbd/worktrees/tbd/20260514-previous-ostrich/CLAUDE.md) workflow rule.

## Deferred (explicitly out of scope for v1)

- **Anti-aliasing / "thin strokes" toggles.** SwiftTerm doesn't expose a public API for these and Retina defaults are good. Would require a SwiftTerm patch.
- **Non-ASCII font slot.** SwiftTerm uses a single font; iTerm's dual-font feature would need upstream changes.
- **Ligatures.** SwiftTerm draws glyph-by-glyph from `CTRun`s; no current ligature path.
- **Line height / horizontal cell spacing.** No SwiftTerm public API.
- **Bold-uses-bright-color toggle.** Uncertain SwiftTerm support; revisit if requested.
- **Transparency / blur.** Wrong UX for TBD's tiled-many-panes shape.
- **Per-worktree or per-tab appearance overrides.** Settings are global in v1. Per-worktree overrides can be layered later via `state.db` if needed.
- **Custom color editing.** Bundled schemes only in v1; no swatch pickers.
- **iTerm `.itermcolors` import.** Bundled schemes only.
- **Color scheme preview swatches in the dropdown.** Names only in v1.
- **"Reset to Defaults" button.** User can re-pick from the dropdowns.

## Files touched (summary)

**New:**
- `Sources/TBDApp/Terminal/AppearanceSettings.swift`
- `Sources/TBDApp/Terminal/ColorSchemes.swift`
- `Sources/TBDApp/Settings/TerminalSettingsView.swift`

**Modified:**
- `Sources/TBDApp/Settings/SettingsView.swift`
- `Sources/TBDApp/Terminal/TBDTerminalView.swift`
- `Sources/TBDApp/Terminal/TerminalPanelView.swift`
- `Sources/TBDApp/Terminal/TerminalContainerView.swift`
- `Sources/TBDApp/AppState.swift` (cellDimensions call sites)
- `Sources/TBDApp/TBDApp.swift` or `@main` entry (environment object injection)
