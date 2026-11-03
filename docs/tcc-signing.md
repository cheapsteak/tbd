# Stable code signing for TCC permission persistence

## Problem

TBD spawns `claude`/`codex`/shell/git as child processes. When one of those
touches a macOS TCC-protected location (Desktop, Documents, Downloads, Photos,
Media library, network volumes, Full Disk), macOS attributes the access to the
**responsible app** — TBD — and shows a consent prompt under TBD's name. In
particular, Claude Code probes the standard home folders at session startup, so
every new tab / `/clear` / `/compact` can trigger a burst of prompts.

That much is expected. The real bug was that the prompts **never stopped** — a
"Don't Allow" never stuck, re-prompting many times a day even without a rebuild.

### Root cause

An ad-hoc signature (`codesign --sign -`) gives TCC a designated requirement
that is just a bare `cdhash` with no stable anchor:

```
designated => cdhash H"967b10c8…"     flags=0x2(adhoc)   TeamIdentifier=not set
```

TCC stores the user's decision keyed on the app's code requirement, but the
responsible process resolved to an anchorless ad-hoc identity
(`TBDApp-<hash>`) that did not validate against the stored requirement. The
unified log showed this directly, repeatedly:

```
tccd: Failed to match existing code requirement for subject
      com.github.cheapsteak.tbd and service kTCCServiceSystemPolicyAllFiles
```

No match → re-prompt, forever.

The same mismatch takes away grants as well as denials. Every rebuild has a
new cdhash, so a permission granted to one build does not match the next: the
switch in System Settings still shows TBD as allowed while tccd logs the
failure above and denies the access. Some services never ask again. With
Screen Recording, `screencapture` run in a TBD terminal fails with "could not
create image from display" and no prompt appears.

## Fix

Sign with a **stable self-signed code-signing identity** instead of ad-hoc. That
produces an anchored, rebuild-stable designated requirement:

```
designated => identifier "com.github.cheapsteak.tbd"
               and certificate leaf = H"9934b5c2…"      flags=0x0(none)
```

The leaf-cert hash never changes as long as we sign with the same cert, so a
single Allow/Deny decision now persists across rebuilds and across spawned child
sessions.

## The signing identity

`scripts/restart.sh` and `tbd update` (`scripts/update.sh`) both sign the
bundle with `sign_app_bundle` in `scripts/restart-bundle-lib.sh`. When the
identity is missing, the first install on a machine creates it, with no
prompt, and every install after signs with it:

- **What and where** – a self-signed code-signing certificate named
  `TBD Dev Signing` and its private key, in a dedicated keychain at
  `~/Library/Keychains/tbd-signing.keychain-db` whose password is
  `tbd-signing`. The login keychain is untouched, and the new keychain is not
  added to the keychain search list: `codesign` is pointed at it with
  `--keychain`.
- **How** – `/usr/bin/openssl`, by absolute path so that a Homebrew or nix
  OpenSSL first on `PATH` is never used, makes the key and certificate in a
  private scratch directory that is deleted on every way out. `security` then
  creates the keychain with no auto-lock timeout, imports the key so that only
  `/usr/bin/codesign` may use it, and sets the key's partition list so that
  `codesign` uses it without asking. `provision_signing_identity` in
  `scripts/restart-bundle-lib.sh` holds the exact commands.
- **Concurrent installs** – runs in several worktrees can install at once.
  While one creates the identity it holds a lock, a directory beside the
  keychain (`tbd-signing.keychain-db.lock`) naming its pid. Another run waits
  up to 30 seconds for it, looks again once it has the lock, and signs that
  build ad-hoc if the wait runs out. A lock whose process has gone is broken,
  and so is any lock more than ten minutes old, whatever pid it names:
  creating the identity takes seconds, so such a lock was left by a run that
  died before writing its pid, or names a pid the system has since reused.
- **Failure** – if any step fails, the run says so and signs that build ad-hoc,
  and the install carries on. A keychain the failed run had created is deleted.
  A keychain left with no identity in it, by a run that was killed partway, is
  deleted and made again by the next install. A keychain at that path that the
  password `tbd-signing` does not unlock was made some other way: TBD leaves
  it alone and signs ad-hoc, and says how to delete it.
- **CI** – with `CI` set, nothing is created and the bundle is signed ad-hoc.
  A runner's keychain is thrown away with the runner.

`security find-identity -p codesigning ~/Library/Keychains/tbd-signing.keychain-db`
lists the identity. `CSSMERR_TP_NOT_TRUSTED` next to it is normal for a
self-signed cert: it only means Gatekeeper won't trust it, which is irrelevant
here, and `codesign` still signs with it. To confirm which signature an
installed bundle carries, `codesign -d -r- /Applications/TBD.app` prints its
designated requirement.

### Granting permissions again, once

The first bundle signed with the identity has a new designated requirement,
which the grants and denials recorded for earlier ad-hoc builds do not match.
The install that creates the identity says so in a note on stderr. Re-grant
each permission once: in **System Settings > Privacy & Security**, open each
list that grants TBD access (Screen Recording, Full Disk Access, Microphone,
and so on), remove TBD, and add it back. To clear every decision at once
instead:

```bash
tccutil reset All com.github.cheapsteak.tbd
```

After a reset, services that prompt ask again on next use. Some services
never prompt for a program running in a terminal, Screen Recording among
them: tccd logs `Service kTCCServiceScreenCapture does not allow prompting;
returning denied` and the access fails. Those still have to be added back by
hand in System Settings, reset or not.

Once re-granted, grants and denials persist across rebuilds. Folder prompts work
the same way: the first one is the last one. Click **Don't Allow** (Claude only
probes those folders; TBD worktrees live under `~/tbd/`, which isn't
protected), and it stays denied silently.

### Removing the identity

```bash
security delete-keychain ~/Library/Keychains/tbd-signing.keychain-db
```

This deletes the keychain, the certificate and the key. The next install
creates a new identity with a new certificate, so every permission needs
granting again once more.

## Microphone access

Some privacy services require the responsible app to declare why it wants
access before macOS will even ask. The microphone is one of them: without an
`NSMicrophoneUsageDescription` key in the responsible app's `Info.plist`, macOS
denies the request silently, shows no prompt, and never lists the app under
**System Settings > Privacy & Security > Microphone**. Because TBD is the
responsible app for every program running in its terminals, a voice-input
feature in a coding agent would fail with no visible cause.

`Resources/TBDApp.Info.plist` therefore carries `NSMicrophoneUsageDescription`.
The bundle is not signed with the hardened runtime, so no entitlement is needed
alongside it. After `scripts/restart.sh` assembles a bundle with the key, the
first microphone request from a terminal program prompts under TBD's name. To
grant access after declining, enable TBD under **System Settings > Privacy &
Security > Microphone**. To clear the decision and be prompted again:

```bash
tccutil reset Microphone com.github.cheapsteak.tbd
```

## Security note

`TBD Dev Signing` is a self-signed, locally generated dev key in a keychain
whose password is fixed and written down here, so that installs can sign
without a prompt. The key's access list names only `/usr/bin/codesign`
(`security import -T /usr/bin/codesign`), and its partition list admits Apple's
own tools. Any process running as you can still unlock the keychain with the
known password. That's acceptable for a local developer-tool signing key: no
one else trusts the certificate, it confers no trust outside this machine, and
it signs nothing that ships.
