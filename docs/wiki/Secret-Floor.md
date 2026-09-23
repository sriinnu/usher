# Secret floor

Some files are not held — they are never classified at all. Not read, not sent,
not rule-matched, not renamed, not moved. The journal records that a file was
floored and what *kind* of secret it looked like, never the value.

The floor is fixed in code. Settings can widen it and cannot shrink it.

## By format (before reading)

Extensions: password managers (`.rfp` `.kdbx` `.1pif` `.1pux` `.opvault`
`.psafe3` …), keys and certificates (`.pem` `.key` `.p8` `.p12` `.pfx` `.ppk`
`.gpg` `.crt` `.mobileprovision` …), wallets (`.wallet` `.seed`). Names:
`id_rsa` and friends, `.env*`, `.netrc`, `.npmrc`, `wallet.dat`, and
`logins.csv` / `credentials.json` style files by their conventional names.

## By naming convention (before reading)

A recovery-codes file is a plain `.txt`; an OAuth client secret is a plain
`.json`. The format list waves both through. So the name is matched too — as
whole words, after opening its seams (`apiKey` → `api Key`, `client_secret` →
`client secret`, `LastPass` → `Last Pass`):

- recovery / backup / 2FA / MFA / OTP codes or keys
- client secret(s); `*.apps.googleusercontent.com.json`
- API / secret / access / private / signing key(s); `apikey`
- access / auth / refresh / bearer / OAuth tokens
- password(s), passwd, Passwort, Kennwort; service account; seed phrase; TOTP
- password-manager names — Bitwarden, LastPass, 1Password, KeePass(XC),
  Dashlane, RoboForm, Enpass, NordPass, Proton Pass, Keeper — and
  "vault / password / login export"

**Deliberately not matched:** `secrets`, `master key`, `mnemonic`, `pwd`, and
`credentials` inside a longer name. Those name books and ordinary documents —
*The Secrets of …*, *The Master Key System*, a "PWD" certificate, an academic
credentials evaluation. A floor that swallows them is a floor people switch off.
A real secret behind a harmless name is caught by content instead.

## By content (after reading, before anything else)

For the file whose name gives nothing away. It has been read on this machine by
the time this runs; what the check guarantees is that nothing read is sent and
the file does not move. The same check runs again on the finished request (see
[Security model](Security-Model.md#the-outbound-screen)).

- private keys: `-----BEGIN … PRIVATE KEY-----`, PGP private key blocks, and
  base64-encoded PEM (`client-key-data` in a kubeconfig)
- provider formats: `sk-…`, AWS `AKIA…`/`ASIA…`, GitHub, GitLab, Slack, Google
  `AIza…`, Stripe, Hugging Face `hf_…`, npm `npm_…`, SendGrid `SG.…`, Azure
  `AccountKey=`
- signed URLs (`X-Amz-Signature`, `sig=`, …) and credentials inside a URL
  (`scheme://user:pass@host`)
- OAuth and service-account JSON fields, JWTs, `otpauth://` seeds, browser
  cookie files
- password-manager exports: JSON `"password": "…"`, and CSV by its header row
- a labelled value — `apiKey,<value>`, `API_KEY=<value>` — and
  `Password:` / `Passwort:` followed by something password-shaped (six or more
  characters with a digit or symbol)
- **a block of recovery codes**

Placeholders are not secrets: `YOUR_API_KEY_HERE`, `<your key>`, `xxxx`,
`example`. "Password: required" is prose.

### Why recovery codes are judged as a block

Recovery codes come as four or more distinct lines with one shape: the same
separator and the same group lengths on every line (`8-8` six times,
`5-5-5-5-5-1` five times, `4 4` for Google backup codes). That uniformity is the
signal. A first version judged lines one at a time and floored three invoices,
because "Invoice number 1234-5678" is also letters, digits and a dash. Dates are
three groups and do not count.

## Re-checking

The floor is re-applied when the logic changes (see
[When Usher asks again](When-Usher-Asks-Again.md)) and again at every move. A
re-check of a file floored by name stops at the name, so nothing is opened.

## Adding to it

`sensitiveExtensions` in `settings.json` widens the format list. Anything more
belongs in `SecretFormats.swift`, with a test naming the file that got through.
