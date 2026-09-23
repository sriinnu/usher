# Encrypted logs

The journal and the rename log name every file Usher has looked at, where it
went and why. That is a map of someone's private files, so neither is ever
written in plain text.

## Format

One JSON object per line, each line sealed on its own with AES-GCM:

```
u1:<base64 of nonce ‖ ciphertext ‖ tag>
```

Per-line sealing keeps appends as appends and means one damaged line costs one
line. An append after a torn write starts on a fresh line.

What the seal does and does not protect:

- **A modified line does not open**, and is ignored.
- **An added plain-text line is ignored.** Plain lines are read only during the
  one-time migration of a journal that is plain throughout; a file mixing sealed
  and plain lines is never migrated, so an injected line is neither believed nor
  sealed into the record.
- **Deleting, reordering or replaying sealed lines is not detected.** Lines are
  sealed independently, with no sequence number or chain.

Files are created owner-read/write only (`0600`) from the first byte.

## The key

256 random bits, generated on first launch, stored in the **login keychain** as
a generic password:

| Attribute | Value |
| --- | --- |
| Service | `Usher journal key` |
| Account | `journal` |
| Accessible | requested: when unlocked, this device only |

It exists nowhere else — not in the repository, not in settings, not in a file.
The accessibility attribute is honoured by the data-protection keychain; for an
item in the classic login keychain it is likely not enforced, so assume the key
travels wherever your login keychain does, backups included.

**If this keychain item is deleted, the journal cannot be recovered.** No undo
history, no calibration record. Whether to keep a copy (for example in a
password manager) is your decision; Usher does not make one.

## Failing closed

If the key exists but cannot be read — a denied keychain prompt, a locked
keychain — the journal is **locked**:

- nothing is read, nothing is written, nothing is written in the clear
- the pipeline refuses to start, and arrivals and drops are refused too
- the panel says why and offers **Relaunch Usher**, which asks the keychain again

An empty journal would mean deciding, and sending, every file again, so "start
anyway" is not an option. A new key is never created over one that exists but
cannot be read: it would orphan every line sealed with the old one.

## Rebuilding

A build signed with a Developer ID keeps one identity across versions, so
"Always Allow" holds. An ad-hoc local build is a new identity every time and
macOS asks again. Headless commands never show that dialog; they fail with a
message instead.

## Reading the logs

```bash
Usher log journal     # decrypted NDJSON to stdout
Usher log renames
```

Stdout only, never to a file. Pipe it into whatever analysis you run:

```bash
Usher log journal | jq -r 'select(.outcome=="moved") | .routeProbability'
Usher log renames | jq -r '"\(.to)\t\(.from)"'     # the undo list
```

## Migration from plain text

On launch every `.ndjson` in Usher's folder that is still plain throughout is
sealed into an owner-only staging file, read back line for line, and only then
swapped in atomically. A file that already has sealed lines is left alone.

The old plain-text blocks are freed, not wiped: they can survive in APFS local
snapshots and Time Machine backups taken before the migration.
