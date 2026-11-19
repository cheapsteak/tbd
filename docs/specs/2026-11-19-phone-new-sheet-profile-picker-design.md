# Phone New sheet: choose the account for a new worktree

The phone's New sheet creates a local worktree from a first message. The new session starts on the
profile TBD would pick for that repo. This change lets the user see that profile and pick another one
before they tap Create.

This extends [phone control](2026-11-07-phone-control-design.md) and builds on
[create with a profile or model](2026-11-10-create-with-profile-and-model-design.md).

## Goal

When I create a worktree from my phone, I want to see which model profile the session will use and
change it, so I can start work on the right account without switching it afterwards.

## Why this sits before creation

The phone has no step after Create where a profile could be chosen. The first message and the profile
are both on the sheet, and one `worktree.create` call carries them. The profile is fixed when the
laptop starts the primary terminal, and it is already known when the call arrives. So:

- Creation is not slowed, and no tab is swapped to another profile afterwards.
- The laptop's queued-prompt modal is not involved. That modal belongs to the laptop app.
- The laptop's `worktree.create` already accepts a profile. Only the phone path drops it.

## Scope

- **In scope:** the "Local worktree" form of the New sheet.
- **Out of scope:** the "Remote session" form. A remote session picks a provider, not a profile.
- **Out of scope:** a model choice. Only the profile is chosen.
- **No flag.** The change adds UI to an existing sheet and acts only on a tap. An old phone and an old
  laptop keep working, as the wire section explains.

## What the user sees

Between the "First message" box and the hint line, the local form shows one collapsed row:
"Account", with the name of the current choice on the right.

- **Collapsed.** The row shows the profile the repo would use, as the laptop reports it. Until that is
  known, it reads "Default".
- **Expanded.** A tap opens a list, one row per profile, with a check on the current choice. The
  profile kind and a "default" mark follow the wording the Switch account sheet already uses.
- **Picking.** A tap on a row makes it the choice and collapses the list. Tapping the ticked row
  pins it: the new session starts on that profile. An untouched row leaves the choice to the
  laptop, which with profile balancing on may start the session on another account than the one
  the row names.
- **Unusable profiles.** A profile that cannot start a session is disabled, and its row says why in
  short words, for example "Not logged in". It cannot be picked.
- **No memory.** Each time the sheet opens, the choice starts again at the repo's profile.
- **Create stays tied to the message.** Choosing a profile does not enable Create. The message rule is
  unchanged.
- **The tap guard.** The row follows the same rule as the other sheet controls: it is held for
  `TAP_GUARD_MS` after the form first shows and after the profile list arrives, so a tap aimed at
  something else cannot land on it.

## Wire

**`profiles.list`** takes an optional `repoID`. With it, the reply adds:

- `repoProfileID` – the ID of the profile a new worktree in that repo would use, with balancing left
  out. It is the repo's own profile setting, otherwise the global default. Either one is skipped when
  it no longer exists or is an API-key profile with no key, as the laptop's resolver skips it. It is
  absent when neither is left.
- on each profile, `usable` (absent means usable) and, when it is false, `unusableReason` – a short
  phrase.

Without `repoID`, the reply is what it is today, so the Switch account and Fork sheets are unchanged.
Both new profile fields are optional, so an older phone ignores them.

The laptop computes `usable` with the same check that refuses an explicit profile at create
(`ExplicitProfileCheck`). The reason phrases come from that check's outcome, not from its
long refusal text, which names laptop commands the phone user cannot run.

**`worktree.create`** from a phone may carry `profileID`. The laptop keeps that field and still drops
everything else a phone may not set, including `model`. The rest of the create is as before.

- **A profile the laptop refuses.** The check runs again at create, because a profile can change
  between the list and the tap. A refused create answers with the laptop's refusal, and the sheet shows
  it in the place it already shows create errors, with the user's text kept.
- **No `profileID`.** The create behaves as it does today.

## Failure behaviour

- **The list is loading.** The row reads "Default". Create works and sends no `profileID`.
- **The list fails to load.** The row stays at "Default" and Create works. A failed list never blocks
  a create. The row does not show an error, because the user loses nothing.
- **The list loads with no `repoProfileID`.** The row reads "Default" until the user picks one.
- **The user picks a profile and the list reloads.** The pick stays if that profile is still in the
  list and usable. Otherwise the choice goes back to the repo's profile.
- **The sheet sends `profileID` whenever the user tapped a profile row**, the ticked one included.
  Leaving the row alone sends none, so the laptop's own choice, including balancing between
  accounts, applies exactly as before.

## Components

- **Laptop wire types** (`Sources/TBDDaemon/PhoneBridge/App/PhoneAppMessages.swift` and the phone
  app protocol files) – the optional request
  field and the optional reply fields.
- **`PhoneAppService+Profiles.swift`** – fills the new fields. It stays an allowlist, built field by
  field, and never carries a token or other secret.
- **`RPCRouter+PhoneSessionActions.swift`** – `phoneWorktreeCreateParams` keeps `profileID`.
- **Phone protocol and state** (`phone/app/src/protocol`, `state/sheets.ts`) – the new fields, and the
  New sheet's own profile load, kept apart from the Switch account sheet's so one cannot overwrite the
  other.
- **`NewSheet.tsx`** – the collapsed row and the list.
- **Phone control spec** – sections 5 and 8.2 say the phone sets only the repo and the first message.
  They are rewritten to add the profile.

## Testing

Laptop:

- `profiles.list` with a `repoID` marks the repo's profile, for a repo with its own setting and for one
  without.
- It marks an unusable profile with a reason, and a usable one without. A Bedrock profile is usable.
- Without a `repoID` the reply carries none of the new fields.
- A phone `worktree.create` keeps `profileID` and still drops `model` and every other field.
- A phone create with an unusable profile is refused and creates nothing.
- A phone create with no `profileID` behaves as before.

Phone:

- The row shows the repo's profile once the list loads, and "Default" before.
- Expanding lists the profiles, with a check on the current one.
- An unusable row is disabled and cannot be picked.
- A pick is sent as `profileID` on Create, and so is a tap on the profile the row already shows. An
  untouched row sends none.
- A failed list leaves Create working with no `profileID`.
- A reload that drops the picked profile resets the choice.
- The remote form shows no Account row.
- A refused create shows its message and keeps the first message and the pick.
- A new sheet starts again at the repo's profile.

## Rejected alternatives

- **Swap the tab after creation.** It restarts Claude for no gain, because the profile is known before
  the create starts.
- **Show only the global default.** A repo with its own profile would show the wrong name until the
  user picked.
- **List every profile and refuse at Create.** It adds no wire fields, but the user learns a profile
  is unusable only after they type a message and tap Create.
- **Remember the last pick.** It would start the next worktree, possibly in another repo, on an
  account the user chose for something else.
