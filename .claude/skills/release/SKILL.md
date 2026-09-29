---
name: release
description: Cut a signed, notarized release of Usher — preflight review, version tag, universal build, Developer ID signing, Apple notarization, checksum and release notes. Use when asked to release, ship, tag a version, or package Usher for someone else to install.
---

# Releasing Usher

A release is a tagged commit, built universal, signed with a Developer ID and
the hardened runtime, notarized by Apple, stapled, zipped and checksummed.
`Scripts/release.sh` does the mechanical part. This skill is the judgement
around it.

## Who does what

| Step | Who |
| --- | --- |
| Preflight: tests, review, docs, privacy scan | assistant |
| Release notes draft | assistant |
| Signed tag (`git tag -s`) | assistant runs it — **the owner touches the security key** |
| Notary credentials, once per Mac | **owner only** |
| Build, sign, notarize, staple, checksum | assistant runs `Scripts/release.sh` |
| Push commits and tags, create a GitHub release, upload | **owner only** — draft and stop |

## Never

- **Never read, open, copy, move or print a `.p8`, `.p12` or `.pem`.** Apple
  API keys are the owner's to handle. Notarization reads a stored keychain
  profile; the key file is not needed after `store-credentials`.
- **Never bypass commit or tag signing** (`--no-gpg-sign`, `-c commit.gpgsign=false`).
  If signing fails, it is almost always an untouched security key: say so,
  wait, retry once. Do not loop.
- **Never force-push, delete tags or rewrite history** without explicit,
  specific permission.
- **Never publish.** No `git push`, no `gh release create`, no upload. Draft
  the notes and the commands, then stop.
- **Never put anything personal in the repo or the notes** — no user file
  names, paths, emails, IDs. Run the privacy scan below.
- **Never put a real value in a test.** No real key, code, token, name,
  phone number, IBAN, document number, or file or folder name from the
  user's disk — not even "just to reproduce the bug". Fake secrets are built
  in `Tests/UsherTests/Fixtures.swift` from obvious TEST parts; emails are
  `@example.com`, phones `555-01xx`, IBANs the textbook ones.
  `NoRealSecretsInTests` enforces the shapes; the owner's private-terms list
  (below) covers the rest.
- **Never print sensitive data in tool output.** Counts and masked shapes, not
  file names from the user's folders. The session transcript is plain text.

## 1. Preflight

```bash
git status --porcelain                  # must be empty
swift build 2>&1 | grep -E "error|warning: " | grep -v commonMetadata
swift test 2>&1 | tail -1               # every test passes, no flake tolerated
```

A flaky test is a finding, not noise: rerun it in a loop until it names
itself, and fix it before tagging.

For anything more than a patch release, run three independent reviews in
parallel — architecture, security, UI/UX — read-only and code-only, told not
to open `~/Library/Application Support/Usher`, `~/Downloads` or `~/Desktop`.
Fix blockers and security findings before tagging; list the rest in the notes
as known issues.

Check the documentation still tells the truth: `README.md` and `docs/wiki/*`
make specific claims (what leaves the machine, what is encrypted, what the
floor catches). A security review lists false claims; fix every one.

Privacy scan of everything that ships:

```bash
git grep -niE '@gmail|@icloud|/Users/[a-z]{2,}/|client_secret_[0-9]|AuthKey_[A-Z0-9]{6,}' -- . ':!*.md' ':!.claude'
grep -rniE '@gmail|@icloud' README.md docs/
```

Only generic patterns (in tests and the secret floor) may match.

Then the private-terms scan over **the exact tree being pushed** — every file,
not the diff. The list lives outside the repo at
`~/.config/usher/private-terms.txt` (owner-only; names, document numbers,
key IDs, identifiers). Report file and line counts, never the terms:

```bash
python3 - <<'EOF'
import os, subprocess
terms = [l.strip().lower() for l in open(os.path.expanduser("~/.config/usher/private-terms.txt"))
         if l.strip() and not l.startswith("#")]
ref = "HEAD"
files = subprocess.run(["git", "ls-tree", "-r", "--name-only", ref], capture_output=True, text=True).stdout.split()
for f in files:
    text = subprocess.run(["git", "show", f"{ref}:{f}"], capture_output=True, text=True).stdout.lower()
    n = sum(any(t in line for t in terms) for line in text.splitlines())
    if n: print(f"{f}: {n}")
EOF
```

Anything it prints blocks the release. A scanner that reports nothing must be
checked against something known to be there before it is trusted.

## 2. Version

Semantic versioning. The version comes from the tag; `Scripts/bundle.sh`
writes it into Info.plist, and the build number is the commit count.

- patch `x.y.Z`: fixes only, no behaviour a user would notice changing
- minor `x.Y.0`: new behaviour, anything touching what is sent, stored or moved
- anything that changes `ConfigFingerprint.logicVersion` is at least minor —
  it makes the next catch-up re-ask

## 3. Release notes

Write `build/release/NOTES-vX.Y.Z.md` (not committed) with: what changed, in
the user's words; anything that changes what leaves the machine or what is
stored; migrations (journal format, fingerprint bump — "the first launch will
look at unresolved files again"); known issues; the checksum (step 5).

## 4. Tag

```bash
git tag -s vX.Y.Z -m "Usher X.Y.Z"      # owner touches the key
git tag -v vX.Y.Z                       # must say Good signature
```

## 5. Build, sign, notarize

Once per Mac, **owner only**:

```bash
xcrun notarytool store-credentials usher-notary \
  --key <path to AuthKey_XXXX.p8> --key-id <key id> --issuer <issuer uuid>
```

Then:

```bash
./Scripts/release.sh                    # NOTARY_PROFILE=... to override
```

It refuses an untagged or dirty tree, runs the tests, builds universal, checks
the hardened runtime, submits to Apple and waits, staples, validates with
`spctl`, and writes `build/release/Usher-X.Y.Z.zip` and its `.sha256`.

If notarization is rejected, read the log — do not re-submit blindly:

```bash
xcrun notarytool log <submission-id> --keychain-profile usher-notary
```

## 6. Verify like a stranger

```bash
xattr -w com.apple.quarantine "0081;$(printf %x $(date +%s));Safari;" build/Usher.app
spctl --assess --type execute --verbose=2 build/Usher.app   # accepted, Notarized Developer ID
codesign -dv --verbose=2 build/Usher.app 2>&1 | grep -E 'Authority|flags|TeamIdentifier'
lipo -archs build/Usher.app/Contents/MacOS/Usher            # x86_64 arm64
```

Launch it once. The first launch of a newly signed build asks for the keychain
items (API key, journal key) one last time; after that the Developer ID
identity holds across versions.

## 7. Homebrew

The cask lives in `sriinnu/homebrew-tap`, `Casks/usher.rb`, and is bumped by a
PR titled `usher X.Y.Z` (the tap's convention). Update `version` and `sha256`
from the release's `.sha256`, then:

```bash
brew style --cask Casks/usher.rb
brew audit --cask --online sriinnu/tap/usher      # after the PR is merged
brew install --cask sriinnu/tap/usher              # a real install, then launch it
```

## 8. Hand over

Report: the tag and its signature status, the zip path and SHA-256, the
notarization submission ID and status, test count, and the known issues. Then
give the owner the publish commands to run themselves, for example:

```bash
git push origin main --follow-tags
gh release create vX.Y.Z build/release/Usher-X.Y.Z.zip build/release/Usher-X.Y.Z.zip.sha256 \
  --title "Usher X.Y.Z" --notes-file build/release/NOTES-vX.Y.Z.md
```

and stop.
