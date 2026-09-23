# Security model

## What leaves the machine

Only a request to the TypeSafe API (`api.typesafe.ai`), and only for a file that
passed every local check below. The request carries:

- the filename and extension
- a text excerpt, capped at 3,500 characters (PDF text, plain text, Office text)
- OCR text from images, capped at 1,200 characters
- PDF title and author, page count, image dimensions and scene labels
- archive entry names (up to 60) — secret-named and privacy-matching ones removed
- the source and referrer URL — **cut to scheme, host and path**; query strings,
  fragments and user info are removed (a presigned link's query string is a
  live credential)
- code-generated candidate names — screened the same way
- for folders that route by subfolder, the names of those subfolders and a few
  file names from each — **screened against the secret floor and your privacy
  patterns**, since that is where rules file private documents

**Never the file itself.** No bytes, no images, no audio. Nothing else is sent
anywhere: no telemetry, no crash reports, no analytics. The app writes nothing
to the system log.

## The order a file goes through

Every step that can decide locally runs before the step that cannot.

| # | Step | Reads the file? | Can send? | If it matches |
| --- | --- | --- | --- | --- |
| 1 | Settle; skip symbolic links | no | no | wait / skip |
| 2 | **Secret floor, by name/format** | no | no | never classified — not read, not moved |
| 3 | Extract evidence | yes, locally | no | — |
| 4 | **Secret floor, by content** | already read | no | never classified — not sent, not moved |
| 5 | Local rules | already read | no | filed by code |
| 6 | Privacy filter | already read | no | held in place |
| 7 | **Outbound screen** of the prepared request | — | no | refused |
| 8 | Jev | — | **yes** | filed, asked, or left |
| 9 | Jev's own personal-record check | — | (already sent) | held, and never sent again |

Step 9 is a backstop, not a defence: by then the excerpt has been sent. The
local steps are what keep private things private.

### The outbound screen

Two layers, both in code every request passes through:

- `OutboundGuard.prepare`, in `Classifier.classify`: the full format floor on
  the filename, the content floor on the evidence, URLs cut down, secret and
  private names dropped from listings.
- `OutboundGuard.screen`, in `JevClient.ask`: the content floor over **the exact
  bytes of the request body**, immediately before it is sent. Whatever path a
  request took — the app, `Usher classify`, `Usher watch`, a folder unit — and
  whatever a future change adds to it, those bytes are what get checked.

## Every way a file moves

A decision can wait in the panel for days under the rules of the day it was
made. So every move — **Move**, **Move all**, and filing previews after dry run
is turned off or a threshold changes — goes through one gate first:

- a symbolic link is refused
- the secret floor runs again, by name, format **and content**
- a folder is refused if any file inside it is a secret by name or format

**Move all** never creates a folder; those proposals are decided one at a time.
Turning dry run off never files anything by itself: the panel shows how many
previews would move and waits for a yes, and a bulk move can be undone as one.
`Mover` never creates a folder unless the move explicitly allows it — a route
whose folder is missing becomes a question.

## What is stored, and how

| File | Contents | At rest |
| --- | --- | --- |
| `journal.ndjson` | every decision: paths, names, reasons, probabilities | **encrypted**, per line |
| `renames.ndjson` | every bulk rename, for undo | **encrypted**, per line |
| `settings.json` | folders, thresholds, privacy lists | plain text — see [Manual checks](Manual-Checks.md) |
| `routes.json`, `rules.json` | destinations and rules | plain text |

All live in `~/Library/Application Support/Usher/`. Logs and backups Usher
creates are owner-only from the first byte. None are in this repository. See
[Encrypted logs](Encrypted-Logs.md).

## Known limits

- **`settings.json` is plain text.** It holds the privacy lists, including the
  personal identifiers (emails, phone, address) used to stop files that mention
  you. Moving those into the keychain is planned, not done.
- **Detection is pattern-based.** It covers the formats listed in
  [Secret floor](Secret-Floor.md). A BIP-39 seed phrase or a bare hex private
  key with no label is not recognised by content.
- **A folder unit moves whole.** It is always approved by hand, and refused if
  it holds a file that is a secret by name or format — but a secret inside it
  with a harmless name moves with it.
- **Downloaded files are untrusted input.** A PDF can contain text aimed at the
  classifier. Every choice is resolved against a set code defined — folders and
  filenames it offered — and new folders need approval, so the worst a hostile
  file can do is be filed in the wrong one of your existing folders, or suppress
  the model's own personal-record backstop.
- **Anything already sent stays sent.** The floor and encryption protect from
  now on; they do not recall a request made before they existed.
