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

`scripts/restart.sh` signed the assembled bundle **ad-hoc** (`codesign --sign -`).
An ad-hoc signature gives TCC a designated requirement that is just a bare
`cdhash` with no stable anchor:

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

## Fix

Sign with a **stable self-signed code-signing identity** instead of ad-hoc. That
produces an anchored, rebuild-stable designated requirement:

```
designated => identifier "com.github.cheapsteak.tbd"
               and certificate leaf = H"9934b5c2…"      flags=0x0(none)
```

The leaf-cert hash never changes as long as we sign with the same cert, so a
single Allow/Deny decision now persists across rebuilds and across spawned child
sessions. `restart.sh` uses this identity when present and falls back to ad-hoc
otherwise (fresh clones / other contributors keep working).

## One-time setup (per machine)

Create the `TBD Dev Signing` identity in a dedicated keychain so `restart.sh`
can sign non-interactively:

```bash
cd /tmp
cat > tbd-codesign.cnf <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = TBD Dev Signing
[ v3 ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

# Self-signed code-signing cert + key
openssl req -x509 -newkey rsa:2048 -keyout tbd-key.pem -out tbd-cert.pem \
  -days 3650 -nodes -config tbd-codesign.cnf

# IMPORTANT: -legacy, or macOS Security can't import the PKCS12 (MAC verify fails)
openssl pkcs12 -export -legacy -inkey tbd-key.pem -in tbd-cert.pem \
  -out tbd.p12 -passout pass:tbd -name "TBD Dev Signing"

# Dedicated keychain with a known password so codesign never GUI-prompts
KC="$HOME/Library/Keychains/tbd-signing.keychain-db"
security create-keychain -p tbd-signing "$KC"
security set-keychain-settings "$KC"                 # no auto-lock timeout
security unlock-keychain -p tbd-signing "$KC"
security import tbd.p12 -k "$KC" -P tbd -T /usr/bin/codesign -A
security set-key-partition-list -S apple-tool:,apple:,unsigned: -s -k tbd-signing "$KC"

# Add to the user keychain search list (preserve existing)
EXISTING=$(security list-keychains -d user | sed 's/[" ]//g' | tr '\n' ' ')
security list-keychains -d user -s "$KC" $EXISTING

rm -f tbd-key.pem tbd-cert.pem tbd.p12 tbd-codesign.cnf
security find-identity -p codesigning "$KC"   # should list "TBD Dev Signing"
```

`CSSMERR_TP_NOT_TRUSTED` next to the identity is normal for a self-signed cert —
it only means Gatekeeper won't trust it, which is irrelevant here. `codesign`
still signs with it.

Then clear any stale ad-hoc-era grants once, so the next decision records
against the new identity:

```bash
tccutil reset All com.github.cheapsteak.tbd
```

After the next `scripts/restart.sh`, the first folder prompt is the last one:
click **Don't Allow** (Claude only probes those folders; TBD worktrees live under
`~/tbd/`, which isn't protected), and it stays denied silently from then on.

## Security note

`TBD Dev Signing` is a self-signed, locally-generated dev key with `-A`
(any-app) keychain access and a known keychain password. That's acceptable for a
local developer-tool signing key; it confers no trust outside this machine and is
not used to ship anything.
