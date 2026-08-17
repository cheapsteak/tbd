# Remembering "Send immediately"

Status: design, approved. App-only preference, ships resolving to OFF.

## The problem

The first-message composer that opens on worktree creation
(`QueuedPromptModal`, from
[`2026-08-10-queued-prompt-on-create-design.md`](2026-08-10-queued-prompt-on-create-design.md))
carries a "Send immediately" checkbox. It starts unticked every time, because
its `@State` is seeded from the compiled constant
`QueuedPromptComposer.sendImmediatelyDefault`. There is nowhere for a decision
about it to live.

An operator who wants first messages to send has to make that choice again on
every worktree they create. The choice is stable — someone who wants the agent
to start working the moment the message lands wants it on the tenth worktree
too — so re-asking is pure friction, and a checkbox that forgets reads as
broken rather than cautious.

The original OFF default was not arbitrary, and this design keeps its
reasoning: submitting starts a turn nobody watched begin, and it is the half
TBD cannot report on afterwards, since an unsubmitted draft leaves no
machine-readable trace. That argues for making the operator *opt in*. It does
not argue for making them opt in repeatedly. An opt-in that persists is still
an opt-in.

## The design

One `UserDefaults` key, read by the new-message composer and by a Settings row,
written by both.

### Where the setting lives

`QueuedPromptComposer` — the enum in `Sources/TBDApp/Worktree/QueuedPromptModal.swift`
that holds what a new first message starts from — carries three members, two of
them new:

- **`sendImmediatelyKey`** — `"queuedPromptSendImmediately"`, the `UserDefaults`
  key. New.
- **`sendImmediatelyDefault`** — unchanged at `false`. Still the single place
  the shipped default lives.
- **`resolveSendImmediately(defaults:shippedDefault:)`** —
  `defaults.object(forKey:) as? Bool ?? shippedDefault`, with `shippedDefault`
  defaulted to `sendImmediatelyDefault`. New.

The resolver's `object(forKey:) as? Bool ??` shape, matching
`AppState.enableTranscript` (`AppState.swift`), is the point rather than a
stylistic echo. `UserDefaults.bool(forKey:)` collapses "never chose" into
`false`, which is the same destroyed distinction that made
`auto_hibernate_enabled` unflippable on the daemon side: once absent and
explicitly-off read alike, a later change to the shipped default either skips
everyone or overrides deliberate opt-outs. Reading the raw object keeps three
states, so flipping `sendImmediatelyDefault` later reaches everyone who never
touched the toggle and preserves everyone who did.

`shippedDefault` is a defaulted test seam, not a production knob — every real
caller takes the default and reads `sendImmediatelyDefault`. It exists so a
test can prove the absent case *follows* the shipped default rather than
coincidentally matching today's `false`: without it, the absent-key assertion
degenerates to `false == false`, which a resolver that collapsed absent into
`false` — the exact defect this shape exists to prevent — would pass by
accident.

### Who reads and writes it

**`QueuedPromptModal`** replaces its `@State private var sendImmediately` with
`@AppStorage(QueuedPromptComposer.sendImmediatelyKey)`, defaulted to
`sendImmediatelyDefault`. Ticking the box writes the key immediately, so the
next composer opens ticked.

Writing on tick rather than on submit is deliberate. "Check it once and it
stays checked" is what a preference means, and the alternative — commit only if
the message is also sent — makes the setting silently conditional on an
unrelated later gesture. The cost is that ticking the box and then pressing
Escape still changes the preference; that is the correct reading of the
gesture, and the Settings row makes it visible and reversible.

**`ParkedPromptReadbackView`** is untouched. It keeps seeding its checkbox from
`readback.submit` — the bit stored with that particular parked prompt — and
never writes the key. Its job is to state what delivery will actually do for
the message in front of the operator, so it cannot show a global preference
that may disagree with the parked bit. Toggling it there edits that one
message, and nothing else.

**Settings ▸ General ▸ Worktrees** gains a row bound to the same key by
`@AppStorage`, next to the other defaults that apply to newly created
worktrees: "Send first messages immediately". That placement is what makes the
preference discoverable and resettable without opening a composer.

The two surfaces do not share help text, because each has a different thing to
add. The composer's toggle explains what ticking the box does to the message
being written, then says the tick is remembered and points at Settings. The
Settings row explains the default it sets and names the surface that also
writes it — specifically the sheet that opens while a new worktree comes up,
because a *second* sheet carries the identical title (`First message for
<name>`) and the identical checkbox label, and that one reads back an
already-parked message and edits only that message. Naming which sheet is what
stops an operator reading the row as a claim about the read-back.

### What does not change

Nothing crosses the RPC boundary. `worktree.setPendingPrompt` still carries an
explicit `submit` bit per prompt, and the daemon never learns this preference
exists — it sees only a per-message choice, exactly as before. No schema
change, no shared model change, no daemon-side default.

No new feature flag either. The key resolves to `false` until an operator
chooses otherwise, which is already the OFF-first shape a flag would impose,
and the composer itself remains gated behind the daemon's
`queued_prompt_enabled`. Adding a flag to gate a default-off preference would
be flag sprawl guarding nothing.

## Testing

A suite in `Tests/TBDAppTests/`, following `ShowScratchSectionSettingTests` —
`UserDefaults(suiteName:)` with `removePersistentDomain(forName:)` teardown,
never `UserDefaults.standard`, which on this unbundled executable is the
developer's real `TBDApp.plist`. Three cases, one per state the resolver must
keep distinct:

- An absent key resolves to `sendImmediatelyDefault` — asserted through
  `shippedDefault` in both positions, so the case proves the fallback is
  *followed* rather than agreeing with it by coincidence.
- An explicit `false` reads `false` and stays `false` regardless of what the
  default constant says — the assertion that a future graduation cannot
  override a deliberate opt-out.
- An explicit `true` reads `true`.

## Rejected alternatives

**Settings-only, with the composer's checkbox as a one-shot override.** The
preference would live solely in Settings and merely supply the composer's
starting value; ticking the box in the composer would affect that message
alone. This is safer in the narrow sense that a one-off tick cannot change
future behavior — but it answers the wrong complaint. The operator's gesture is
already "I want this on", made at the checkbox; sending them to a Settings
window to make it stick adds a step to the exact interaction the design exists
to shorten.

**Sticky checkbox with no Settings row.** The smallest diff: persist the
composer's own value and stop. Rejected because the preference would then be
invisible — changeable only by creating a worktree, and undiscoverable by
anyone who has not already noticed the box remembering. A persisted setting
with no home in Settings is state the operator cannot audit.

**Feeding the preference from the read-back composer too.** Consistent in the
shallow sense that the box would remember wherever it is ticked, but the
read-back is editing one already-parked message; giving that edit a global
side effect means an operator adjusting a single prompt silently changes what
every future worktree does.
