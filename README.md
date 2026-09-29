# usher

A macOS menubar app that watches your download folders, works out what each new
file actually is, and files it under a sensible name.

Jev (TypeSafe's System One model) makes two selections per file: which folder,
and which of several code-generated filenames. Everything else — watching,
extracting, thresholds, moving, undo — is plain Swift.

**Privacy and security** are documented in the [wiki](docs/wiki/Home.md):
[security model](docs/wiki/Security-Model.md) ·
[secret floor](docs/wiki/Secret-Floor.md) ·
[encrypted logs](docs/wiki/Encrypted-Logs.md) ·
[when Usher asks again](docs/wiki/When-Usher-Asks-Again.md) ·
[manual checks](docs/wiki/Manual-Checks.md).

## Requirements

- macOS 14 or later
- A **TypeSafe API key**, for the Jev model that does the classifying. Get one at
  [typesafe.ai](https://typesafe.ai); the docs are at
  [docs.typesafe.ai](https://docs.typesafe.ai).

Usher does nothing useful without a key — routing, renaming and the personal-record
check all run through Jev. The local rules and the privacy filter still work
without one, but every file that is not matched by a rule will simply be left alone.

## Install

Download `Usher-x.y.z.zip` from the
[latest release](https://github.com/sriinnu/usher/releases/latest), unzip, and
drag `Usher.app` to Applications. Releases are signed with a Developer ID and
notarized by Apple, so Gatekeeper opens them without a detour; a `.sha256` file
sits next to each zip if you want to check the download.

The app lives in the menubar only; there is no Dock icon. On first launch it
asks for a TypeSafe API key (Settings → Privacy) and macOS asks once to let it
read your Downloads folder and use its keychain items — allow both.

## Build from source

```bash
./Scripts/bundle.sh          # release build for this Mac
open build/Usher.app
```

With a "Developer ID Application" certificate in your keychain the build is
signed with it and the hardened runtime; otherwise it is ad-hoc signed, which
works but gives every build a new identity (see the note under the API key).
`Scripts/release.sh` does the full tagged, universal, notarized release — the
procedure is in `.claude/skills/release/SKILL.md`.

## Setting the API key

Usher looks in this order and never logs the value:

1. environment `JEV_API_KEY`
2. environment `TYPESAFE_API_KEY`
3. login keychain, generic password with service `JEV_API_KEY`

**Environment first, deliberately.** A keychain grant is bound to the signing
identity. A Developer ID build keeps one identity across versions, so "Always
Allow" holds; an ad-hoc build from source is a new identity every time and
macOS re-asks after each rebuild. Reading the environment never prompts.

GUI apps do not inherit your shell profile, so exporting the key in `.zshrc` is
not enough for the `.app`. Use `launchctl`:

```bash
launchctl setenv JEV_API_KEY "your-key-here"
```

That lasts until you reboot. To survive restarts, either put the key in the
keychain as well:

```bash
security add-generic-password -s JEV_API_KEY -a "$USER" -w "your-key-here"
```

…or run the `launchctl setenv` from a LaunchAgent at login.

For the `classify`, `rename` and `watch` commands, a plain shell export is enough:

```bash
export JEV_API_KEY="your-key-here"
```

Those commands disable keychain interaction entirely — a terminal process has
nobody to click an "allow access" dialog and would block forever waiting.

**Settings → Privacy** has a field to paste a key straight into the keychain, and
shows which source answered — never the key itself. It reports three states, since
they need different fixes: nothing stored, stored and readable, or *stored but this
build cannot read it* (an ad-hoc rebuild from source is a new identity to the
keychain — re-save, or use the environment). The
key is never written to the journal, the config, or this repository.

## How a download is handled

1. **Watch.** FSEvents over every enabled folder. Creations and renames only.
2. **Settle.** Nothing proceeds while a `.crdownload` / `.download` / `.part`
   placeholder exists or the file is still growing. An iCloud placeholder is
   materialized first — reading one without downloading it gives empty text, which
   looks exactly like a file with nothing in it.
3. **Secret floor, by name.** Vaults, keys, certificates, recovery codes, client
   secrets, exported API keys: stopped here, before the file is opened. See
   [Secret floor](docs/wiki/Secret-Floor.md).
4. **Extract, locally.** PDF metadata and first pages, archive listings (zip, and
   rar, 7z, tar and the rest through the system `tar`), Vision OCR and scene
   labels for images, and `kMDItemWhereFroms` — the URL the file came from, which
   is the strongest free signal there is.
5. **Secret floor, by content.** Private-key headers, provider key formats,
   password exports, labelled keys, a block of recovery codes. Stopped before
   rules or the model — and the finished request is screened again right before
   it is sent.
6. **Rules.** Deterministic patterns run *before* the model. A match is filed by
   code and never reaches the API. See [Local rules](#local-rules).
7. **Filter.** Filename, title, source host and image labels are checked against
   your patterns. A match means the file is never serialized into a request.
8. **Classify.** One POST with three questions that run in parallel: a Choice over
   destination folders, a Choice over candidate filenames, and a Noul asking
   whether the contents look like a personal record. A scanning destination adds a
   second request to pick among the folders that actually exist.
9. **Act.** Above `autoMoveThreshold` it moves. Between the thresholds it waits
   for you. Below, it does nothing. Every outcome is journaled.

Before any move, the destination is checked for a byte-identical file. If one is
there, the arriving copy is set aside in the duplicates folder rather than filed
as `… 2`. Identity is SHA-256, never size or name — two audio tracks of the same
length are not the same file.

## Configuration

`~/Library/Application Support/Usher/`

| File | What it is |
| --- | --- |
| `settings.json` | Watched folders, ignore list, thresholds, dry-run flag, privacy patterns |
| `routes.json` | The destination tree |
| `rules.json` | Deterministic routes that bypass the model entirely |
| `journal.ndjson` | Every decision, append-only — **encrypted**, one sealed line each |
| `renames.ndjson` | Every bulk rename, for undo — **encrypted** |

None of these are in the repository — they hold real paths and are seeded from the
defaults in source on first run.

The two logs are sealed with AES-GCM under a key kept only in the login keychain
(`Usher journal key`). If the key cannot be read, Usher does not start. Read them
with `Usher log journal` / `Usher log renames`. Losing the keychain item loses the
journal — see [Encrypted logs](docs/wiki/Encrypted-Logs.md).

## Ignored

Settings → Folders → Ignore takes shell globs — `*.dmg`, `IMG_*`, `AuthKey_*`,
`Screenshot *` — matched against file and folder names, case insensitive. A
match is never looked at: not read, not journaled, no row in the panel. That is
the difference from a privacy pattern, which holds a file and shows you that it
did. Use it for the things you know you want left exactly where they land.

## Never classified

Password managers, private keys, certificates and wallets are not held — they
are never classified at all. The pipeline checks for them before it reads,
downloads, rule-matches, renames or moves anything, and stops.

The core list — `.rfp`, `.kdbx`, `.1pif`, `.pem`, `id_rsa`, `wallet.dat` and
the rest — is fixed in code. A setting can widen it and cannot shrink it, so no
edit to `settings.json` can put a vault back in front of the classifier.

Formats are not enough: a recovery-codes file is a plain `.txt`, an OAuth client
secret a plain `.json`. The floor also matches naming conventions and, after the
file is read locally, secret shapes in its text — and the classifier refuses a
secret itself, whatever path it arrived by. Details in
[Secret floor](docs/wiki/Secret-Floor.md).

## Local rules

Some files must not leave the machine but still need filing. "Do not send this to
a third party" and "do not file this" are different requirements, and treating
them as one means your bank statements pile up in Downloads forever.

A rule in `rules.json` matches on filename, on text extracted on-device, or on the
download's source host. A match is filed by code, with no API call:

```json
{
  "name": "Insurance",
  "filenamePattern": "\\bpolicy\\b|\\blic\\b",
  "contentPattern": "life insurance corporation",
  "destination": "~/Documents/Insurance"
}
```

Rules are tried in order, first match wins. `contentPattern` is checked against
text read locally out of the PDF or via OCR, so a file whose name gives nothing
away still routes correctly.

**Use `\b`.** A bare `lic` matches "application"; a bare `chit` matches
"architect". The privacy filter applies word boundaries automatically, including
a trailing plural, but `rules.json` patterns are raw regex and mean exactly what
they say.

A rule never creates a folder. If the destination does not exist, the file waits
for approval like anything else.

### routes.json

The `description` is the text Jev reads, so write it the way you would explain the
folder to a person — that is the actual prompt. A node is one of two kinds.

**Declared** — this exact folder is the destination:

```json
{
  "label": "a1",
  "description": "Absolute beginner German. Greetings, the alphabet, numbers, present tense...",
  "path": "~/Documents/German/A1",
  "template": "{name}.{ext}"
}
```

**Scanning** — the destinations are whatever subfolders already exist in there:

```json
{
  "label": "people",
  "description": "A photo of one specific, identifiable person...",
  "scan": "~/Pictures/People",
  "allowNew": true
}
```

Template tokens: `{name}` `{ext}` `{date}` `{yyyy}` `{mm}` `{source_host}`.
A branch's `template` is inherited by its leaves.

### `{root}` — where destinations live

A `path`, `scan` or rule `destination` may start with `{root}`. It resolves per
file: to the watched folder's own **destination root** if one is set (Settings →
Folders → "into…"), otherwise to `defaultDestinationRoot` in settings.json —
iCloud Drive by default. An explicit root *confines* destinations: a Google
Drive folder set to file "into GoogleDrive" never moves anything to iCloud, and
a Drive-to-Drive move is a rename on the same volume. Absolute paths still work
as written.

There is always an implicit `unsorted` option. When Jev picks it, the file stays
in place — the model is allowed to say "none of these".

### Not creating folders forever

A scanning node reads the folders you already keep and routes into them, with a
few of the filenames inside each one shown as context. `~/Pictures/People/Samantha
Ruth Prabhu` already exists, so the next photo of her goes there — it does not
become `Samantha`, `samantha-ruth-prabhu`, or `Samantha Filmfare 2023`.

When nothing fits, the app proposes a name and **stops**. Creating a directory is
never a decision it makes alone; the file waits in the menubar with a `new folder`
badge until you approve it. Set `"allowNew": false` to forbid new folders in a
category entirely — files with no home then fall through to `unsorted`.

The proposed name comes from code, not the model: filename, URL slug, and OCR are
split into word-prefix variants (`Alia Bhatt`, `Alia Bhatt Red Carpet`, …) and Jev
picks the one that names the lasting subject rather than the occasion.

Routing runs in one request for declared destinations, two for scanning ones — the
candidate folders are not known until the first answer says which directory to read.
The threshold sees the geometric mean of both steps, so a two-stage route is scored
comparably against a one-stage one.

## Headless

The same binary runs without the GUI, which is the loop for tuning `routes.json`:

```bash
Usher classify --dir ~/Downloads --verbose   # classify, print, move nothing
Usher classify somefile.pdf                  # specific files
Usher watch                                  # live FSEvents, still no moves

Usher rename --dir ~/Books                   # preview filename cleanup
Usher rename --dir ~/Books --apply           # actually rename
Usher rename --dir ~/Books -r --apply        # include subfolders

Usher log journal                            # the encrypted journal, decrypted to stdout
Usher log renames                            # the rename log (the undo list)
```

`rename` strips mirror names (z-library, libgen, Anna's Archive, PDF Room), ISBNs,
content hashes and publisher strings. It only ever *removes* — the result is always
a subsequence of the original, so it can run unattended over a whole library. It
makes no API calls and never moves a file between folders.

```
✅ would move   ❓ would ask   ➖ too uncertain   📌 matched a local rule
📥 no match     🆕 wants a new folder (always asks)
🔒 held, never sent   ☁️  iCloud placeholder   🔑 never classified at all
```

## Dry run

On by default. Decisions are made and journaled, nothing moves. Leave it on for a
week of real downloads, read the journal, then turn it off.

Turning it off — or moving a threshold — costs no API calls. The answers are
already in the journal with their probabilities; Usher re-applies the new policy
to them, and asks before filing any previews that now cross the line. See
[When Usher asks again](docs/wiki/When-Usher-Asks-Again.md).

## Renaming

Jev does not generate text. Code proposes filenames from PDF title metadata, the
first real heading in the extracted text, the source URL, and the original name;
Jev picks the clearest one. A name it was not offered cannot be chosen.

## Tests

```bash
swift test
```

Regression tests over the logic that decides where files go. Each one pins a bug
that actually shipped, so read the comments for what went wrong rather than what
the assertion checks.

## Known limits

- **Text and JSON only.** No image input to the model — images reach it as
  on-device OCR text and pixel dimensions, nothing more.
- **No face recognition yet.** "The right person's folder" needs Vision face
  embeddings matched against an enrolled set, computed locally. Until then people
  photos route on filename, OCR and source URL, which is often enough and
  sometimes not.
- **Downloaded files are untrusted input.** A PDF can contain text aimed at
  steering the classifier. The questions say to treat state as data, but the real
  protection is that code owns the move, the destination set is closed, and
  nothing is ever deleted or overwritten.

## Journal as an eval set

Every undo is a labeled mistake and every approval is a labeled hit. After a few
weeks the journal is a real calibration set: the recorded probability against
what you actually did. `Usher log journal | jq …` is how to get at it. That is what tells you where to put the thresholds, and
whether Jev is trustworthy enough to route on.

## License

MIT — see [LICENSE](LICENSE). Usher talks to the TypeSafe API, which has its own
terms and pricing; this licence covers only the code in this repository.
