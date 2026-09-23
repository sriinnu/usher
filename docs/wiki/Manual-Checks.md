# Manual checks

Some things Usher deliberately does not do for you. They involve credentials,
backups or deletion, where a program acting on its own is the wrong default.

## After first installing, or after upgrading from before the secret floor

- [ ] **Look for credentials that reached the API.** Before the name/content
      floor existed, a plain-text file of recovery codes or an exported key was
      read like any other file and an excerpt was sent. List what went:

      ```bash
      Usher log journal | jq -r 'select(.inputTokens != null) | .filename' \
        | grep -iE 'recovery|backup.?code|secret|api.?key|token|password|credential'
      ```

      Rotate anything on that list at its provider. Encryption and the floor
      protect from now on; they do not recall a request already made.
- [ ] **Move stray secret files into a password manager.** Recovery-code and
      key files sitting in synced folders are floored by Usher but still synced.

## Once

- [ ] **Decide whether to back up the journal key.** Keychain item
      `Usher journal key`. Without it the journal is unrecoverable; with a copy
      somewhere else, that copy needs the same care as the journal.
- [ ] **Review `settings.json`.** It is plain text. The personal identifiers in
      it (emails, phone, address) are yours to keep there, trim, or wait for the
      keychain move.

## Now and then

- [ ] **Review the Needs-you queue before "Move all".** It skips secrets and
      new folders, but a proposal is only as good as the day it was made.
- [ ] **Delete tool transcripts that mention your files.** If you develop Usher
      with an assistant that keeps session logs on disk, those logs are plain
      text and may contain filenames.
