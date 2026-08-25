# Automatic Notes tabs for new worktrees

Status: **implemented**.

## Problem

An ordinary repo-backed worktree starts with an empty Notes tab. The daemon
creates the note after the primary terminal, appends it to the tab order, and
leaves the primary terminal focused. This is intentional: Notes are immediately
available without requiring a second gesture, and existing users rely on that
default.

The same convenience is unwanted for users who do not keep worktree notes. For
them, every new worktree opens with an empty tab they must ignore or remove. The
choice is stable across worktrees, so it belongs in a durable global preference
rather than in every creation sheet.

Fresh-branch conversation revival has a different requirement. Its Notes tab is
populated with provenance for the forked conversation and the branch it came
from. That note is part of the revival result, not an empty convenience tab, and
must exist regardless of the preference for ordinary worktrees.

## Design

Settings › Worktrees contains a global toggle named **Create a Notes tab for
new worktrees**. It defaults on, preserving the established creation behavior.
Turning it off affects ordinary repo-backed worktrees whose
`completeCreateWorktree` config snapshot occurs after the preference is
persisted, regardless of which client created them. It does not remove existing
notes. A visibly pending creation may use either value depending on whether it
has already taken that snapshot.

The preference is daemon-backed rather than app-local. The daemon owns
worktree creation for both the app and the CLI, so it is the only layer that can
apply one choice consistently to every client.

The preference distinguishes two creation cases:

- **Ordinary creation** — `completeCreateWorktree` receives no
  `ConversationCarryover`. It creates an empty initial Notes tab only when
  `autoCreateNotesEnabled` is true.
- **Fresh-branch conversation revival** — `completeCreateWorktree` receives a
  `ConversationCarryover` with a provenance seed. It always creates the
  populated Notes tab, even when `autoCreateNotesEnabled` is false.

Scratch spaces use a separate creation lifecycle and are outside this setting.
Plain revival of an existing worktree restores its existing state rather than
creating an initial note, so it is unchanged as well.

## Persistence and defaults

The singleton `config` row stores the choice in
`auto_create_notes_enabled INTEGER`. The migration adds the column without a
SQL `DEFAULT`, preserving three states:

- **NULL** — the user has never chosen. `ConfigRecord.toModel()` resolves this
  through `Config.autoCreateNotesDefault`.
- **0** — the user explicitly disabled automatic empty Notes tabs.
- **1** — the user explicitly enabled automatic empty Notes tabs.

`Config.autoCreateNotesDefault` is `true`, the single shipped default. The
shared `Config` model exposes the resolved nonoptional
`autoCreateNotesEnabled` value, while `ConfigRecord` retains the nullable stored
value. `ConfigStore.setAutoCreateNotes(_:)` writes either explicit choice.

Keeping the SQL column nullable matters even with a permanent default-on
preference. It preserves the difference between an untouched installation and
a deliberate choice, so a future product-default change can follow the Swift
constant for untouched rows without overriding either explicit state.

## Lifecycle semantics

`completeCreateWorktree` reads `Config` once near the start of creation and
computes whether an initial note is required from that snapshot. Once the read
completes, later preference changes do not affect that creation. Any creation
whose snapshot occurs after a new value is persisted uses the new value. This
code boundary, rather than the worktree's visible pending state, determines
which preference applies.

Both terminal-spawn branches use the same decision:

- **Inline spawn** — after the primary terminal is spawned, the daemon creates
  the initial note when required.
- **`preSession` spawn** — the detached phase-three task creates the initial
  note after the hook completes and the primary terminal is spawned.

When created, the note is titled `Notes`, appended after terminal IDs in the
worktree's tab order, and does not take focus from the primary terminal. An
ordinary note has empty content. A conversation carryover writes its provenance
seed into the note.

Initial-note creation remains best-effort. A note insert, seed update, or tab
order update that fails is logged and does not fail an otherwise valid worktree
whose checkout and terminals already exist. Failures earlier in the ordinary
creation lifecycle retain that lifecycle's existing cleanup behavior.

## RPC and app refresh

The app initializes its mirror from `Config.autoCreateNotesDefault` and refreshes
it from `ModelProfileListResult`, the existing config-bearing response returned
by `modelProfile.list`.

Changing the toggle calls `config.setAutoCreateNotes`. The handler persists the
explicit value and broadcasts the existing `modelProfilesChanged` delta. Each
connected app responds by fetching `modelProfile.list` again, so the setting
converges across app windows without a daemon restart.

The app changes its local mirror only after the setter RPC succeeds. If the RPC
fails, the previous value remains visible and the established error alert is
shown. The daemon therefore remains authoritative, and a failed write cannot
make the UI claim that future worktrees will follow a value it did not persist.

## Compatibility

Existing databases receive a nullable column, so their singleton config row
stays NULL and resolves to the default-on behavior. No backfill turns an
untouched row into an explicit choice.

The custom decoders for both `Config` and `ModelProfileListResult` resolve a
missing `autoCreateNotesEnabled` key through
`Config.autoCreateNotesDefault`. New code therefore treats payloads from before
the field existed as enabled, matching the behavior those payloads represented.
Older decoders ignore the additive response field. If the setter is unavailable,
the app follows the normal RPC failure path and retains its previous mirror.

## Rollout and permanence

This toggle is a permanent user preference, not a temporary rollout flag. The
underlying default-on behavior already exists, creates only an empty app-owned
note, and neither destroys state nor acts without a worktree-creation gesture.
The change adds an explicit opt-out while preserving that behavior for untouched
installations.

There is no graduation step that removes the preference. Users can reasonably
want either workspace shape indefinitely, and explicit false and true values
remain durable choices.

## Testing

The lifecycle branch matrix covers:

- ordinary inline creation with an untouched/default-on setting creates one
  empty Notes tab, appended last without stealing focus;
- ordinary inline creation with an explicit false setting creates no note;
- ordinary `preSession` creation with an explicit true setting creates the
  empty Notes tab after phase three;
- ordinary `preSession` creation with an explicit false setting creates no
  note;
- inline conversation carryover with the setting false still creates the
  populated provenance note;
- `preSession` conversation carryover with the setting false still creates the
  populated provenance note.

Persistence and compatibility tests prove that the migration has no SQL
default, NULL follows a supplied default in either direction, explicit false
and true survive a changed supplied default, the store persists both values,
and legacy shared-model JSON resolves enabled.

RPC tests prove that the setter persists both values and broadcasts
`modelProfilesChanged`, that `modelProfile.list` carries the resolved value,
and that a legacy list response resolves enabled. App-state tests cover loading
both values, changing the mirror only after success, retaining it on failure,
and the help text that names the carryover exception.

## Rejected alternatives

- **Turn automatic notes off for everyone** — this removes an intentional
  behavior that existing users rely on instead of letting each user choose.
- **Store the preference in `UserDefaults`** — the daemon would not see it for
  CLI-created worktrees, and app and daemon state could disagree.
- **Make the preference per repository** — the choice describes a user's
  workspace habit rather than a repository property, while per-repo storage
  would add configuration and UI complexity without a distinct lifecycle need.
- **Apply the preference to conversation carryover** — disabling an empty
  convenience tab must not discard the populated provenance that explains the
  revived conversation's origin.
- **Use a temporary feature flag around the setting** — the behavior already
  ships default-on, and an additional gate would duplicate a permanent control
  without protecting a risky rollout.
