import Foundation

/// Files that Usher must never classify. Not "hold and don't send" — never read,
/// never run through a rule, never moved, never renamed. The pipeline checks this
/// before it looks at anything else about the file.
///
/// The core list is fixed in code on purpose. A setting can widen it but cannot
/// remove from it, so no edit to settings.json can ever put a password vault
/// back in front of the classifier.
enum SecretFormats {

    /// Immutable floor. Password managers, key material, wallets.
    static let core: Set<String> = [
        // Password managers
        "rfp", "rfo", "rfn",                 // RoboForm
        "kdbx", "kdb",                       // KeePass
        "1pif", "1pux", "agilekeychain", "opvault",   // 1Password
        "psafe3",                            // Password Safe
        "lpcsv",                             // LastPass export
        "bitwarden", "enpass", "dashlane",
        // Keys, certificates, keychains
        "pem", "key", "p12", "pfx", "ppk", "jks",
        "p8",                                // Apple APNs / App Store Connect private keys
        "mobileprovision", "provisionprofile",
        "keychain", "keychain-db",
        "gpg", "pgp", "asc", "kbx",
        "crt", "cer", "der", "csr",
        "id_rsa", "id_ed25519", "id_ecdsa",
        // Wallets and seeds
        "wallet", "seed", "mnemonic"
    ]

    /// Filenames that carry no extension but are secrets by convention.
    static let coreNames: Set<String> = [
        "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa",
        ".netrc", ".npmrc", ".pypirc", ".env", "credentials", ".htpasswd",
        // `.dat` is too generic to block as an extension; the wallet is caught
        // by its conventional name instead (Bitcoin Core, Electrum-style forks).
        "wallet.dat", "electrum.dat", "default_wallet"
    ]

    /// Secrets by naming convention rather than format. A recovery-codes file
    /// is a plain `.txt`, an OAuth client secret a plain `.json` — the
    /// extension floor waved both through, and their contents were sent.
    ///
    /// Matched against the name with its seams opened (`apiKey` -> `api Key`,
    /// `client_secret` -> `client secret`), as whole words.
    static let coreNamePatterns: [String] = [
        #"(recovery|backup|2fa|mfa|otp) (codes?|keys?)"#,
        #"client secrets?"#,
        #"(api|secret|access|private|signing) keys?"#,
        #"apikeys?"#,
        #"(access|auth|refresh|bearer|oauth|personal access) tokens?"#,
        #"passwords?|passwd|passwort|kennwort"#,
        #"service account|seed phrase|totp|otpauth"#,
        // Password-manager exports carry every password in plain text. The
        // manager's name in a filename is enough: a guide to Bitwarden is a
        // small price next to a vault export sent as an excerpt.
        // Written with optional spaces: names are matched after camelCase is
        // opened, so "KeePassXC" arrives as "Kee Pass XC", "LastPass" as "Last Pass".
        #"bit ?warden|last ?pass|1 ?password|kee ?pass( ?xc)?|dash ?lane|robo ?form|enpass|nord ?pass|proton ?pass|keeper"#,
        #"(vault|password|logins?) (export|backup)"#,
        // Not "pwd" (Public Works Department) and not "credentials" on its own
        // (a degree-evaluation letter) — see `credentialFile` for the files
        // that really are. Not "secrets", "master key" or "mnemonic": those name books
        // (The Secrets of Sanskrit, The Master Key System, a mnemonics
        // guide). A real secret behind a harmless name is caught by content.
    ]

    private static let namePattern: NSRegularExpression = {
        let body = coreNamePatterns.joined(separator: "|")
        return try! NSRegularExpression(pattern: "(^|[^\\p{L}\\p{N}])(\(body))($|[^\\p{L}\\p{N}])",
                                        options: [.caseInsensitive])
    }()

    static func isSecret(_ url: URL, settings: AppSettings) -> Bool {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()
        if core.contains(ext) { return true }
        if coreNames.contains(name) { return true }
        // A trailing ".env.local", ".env.production" and so on.
        if name.hasPrefix(".env") { return true }
        // Google's downloaded OAuth client files are named after the client.
        if name.hasSuffix(".apps.googleusercontent.com.json") { return true }
        if hasSecretName(url.lastPathComponent) { return true }
        // Browser password exports: logins.csv (Firefox), and a credentials
        // file by its conventional name only.
        if name.range(of: #"^(logins?|credentials?)(\.[a-z0-9]+)?\.(csv|json|txt|ya?ml|ini|xml|conf|cfg)$"#,
                      options: .regularExpression) != nil { return true }
        // User additions can only ever widen the set.
        return settings.sensitiveExtensions.contains(ext)
    }

    static func hasSecretName(_ filename: String) -> Bool {
        let opened = SensitiveFilter.opened(filename)
        return namePattern.firstMatch(in: opened, range: NSRange(opened.startIndex..., in: opened)) != nil
    }
}

/// Secrets recognised by their shape, for the ones whose name gives nothing
/// away — `notes.txt` with an API key pasted into it. The file has been read
/// on this machine by the time this runs (that is how the shape is seen); what
/// it guarantees is that nothing read is sent, and the file is not moved.
///
/// Runs before local rules and before Jev. Returns what kind of secret, never
/// the secret itself: the kind goes in the journal, the value goes nowhere.
enum SecretContent {

    private static let shapes: [(kind: String, pattern: String)] = [
        ("a private key",             #"-----BEGIN [A-Z ]*PRIVATE KEY( BLOCK)?-----"#),
        // "-----BEGIN" in base64: a PEM inside kubeconfig client-key-data.
        ("an encoded private key",    #"LS0tLS1CRUdJTi[A-Za-z0-9+/=]{20,}"#),
        ("a one-time-password seed",  #"otpauth://"#),
        ("credentials inside a URL",  #"\b[a-z][a-z0-9+.-]{1,15}://[^\s:/@"']{1,64}:[^\s/@"']{3,}@[^\s/]+"#),
        ("a browser cookie file",     #"# (Netscape )?HTTP Cookie File"#),
        ("a Hugging Face token",      #"\bhf_[A-Za-z0-9]{30,}"#),
        ("an npm token",              #"\bnpm_[A-Za-z0-9]{36}\b"#),
        ("a SendGrid key",            #"\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}"#),
        ("an Azure storage key",      #"AccountKey=[A-Za-z0-9+/=]{40,}"#),
        ("a signed access URL",       #"[?&](sig|X-Amz-Signature|X-Amz-Security-Token|X-Goog-Signature)=[A-Za-z0-9%+/=._-]{16,}"#),
        // A password-manager export as JSON, and as CSV by its header row.
        ("a password export",         #""password"\s*:\s*"[^"]{4,}""#),
        ("a password export",         #"(?im)^\s*"?(name|url|uri|title|login_uri|username|login)"?\s*,.*\b"?(password|login_password)"?\s*(,|$)"#),
        ("an API key (sk-…)",         #"\bsk-(ant-|proj-)?[A-Za-z0-9_-]{20,}"#),
        ("an AWS access key",         #"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#),
        ("a GitHub token",            #"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}|\bgithub_pat_[A-Za-z0-9_]{30,}"#),
        ("a GitLab token",            #"\bglpat-[A-Za-z0-9_-]{20,}"#),
        ("a Slack token",             #"\bxox[abeoprs]-[A-Za-z0-9-]{10,}"#),
        ("a Google API key",          #"\bAIza[0-9A-Za-z_-]{35}\b"#),
        ("a Stripe key",              #"\b(sk|rk)_(live|test)_[A-Za-z0-9]{20,}"#),
        ("an OAuth client secret",    #""client_secret"\s*:"#),
        ("a service-account key",     #""private_key(_id)?"\s*:"#),
        ("a signed token (JWT)",      #"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\."#),
        // A key exported as `apiKey,<value>` or written as `API_KEY=<value>`:
        // no provider format to recognise, but the label says what it is.
        ("a labelled key or password",
         #"(?i)(^|[^A-Za-z])(api[_ -]?key|apikey|secret[_ -]?key|client[_ -]?secret|access[_ -]?key|auth[_ -]?token|access[_ -]?token|password|passwd)["']?\s*[,:=]\s*["']?[A-Za-z0-9._~+/=-]{16,}"#),
    ]

    /// `Password: <value>` in English or German, where the value looks like a
    /// password rather than prose: six or more characters with a digit or a
    /// symbol in them. "Password: required" is prose; "Passwort: Sommer24!" is not.
    private static let labelledPassword = try! NSRegularExpression(
        pattern: #"(?i)(^|[^A-Za-z])(password|passwd|passwort|kennwort|pin|pwd)\s*[:=]\s*(\S{6,})"#)

    /// Documentation says `API_KEY=YOUR_API_KEY_HERE`. That is not a key, and
    /// flooring every README that shows one teaches people to turn this off.
    static func isPlaceholder(_ value: String) -> Bool {
        let v = value.lowercased()
        if ["your", "here", "xxxx", "example", "placeholder", "changeme", "<", "...", "***", "${", "{{"]
            .contains(where: v.contains) { return true }
        return value.range(of: #"^[A-Z0-9_]+$"#, options: .regularExpression) != nil
            && value.contains("_")
    }

    private static let compiled: [(String, NSRegularExpression)] = shapes.map {
        ($0.kind, try! NSRegularExpression(pattern: $0.pattern))
    }

    /// Recovery codes come as a block of lines with one shape: the same
    /// separator and the same group lengths on every line (`8-8` six times,
    /// `5-5-5-5-5-1` five times), all different. That uniformity is the
    /// signal — "Invoice number 1234-5678" is also letters, digits and a
    /// dash, and a first version that looked at lines one at a time floored
    /// three invoices as recovery codes.
    static func codeBlockShape(_ line: Substring) -> String? {
        var body = line.trimmingCharacters(in: .whitespaces)
        if let r = body.range(of: #"^\d+[.)]\s*"#, options: .regularExpression) { body.removeSubrange(r) }
        let separators = Set(body.filter { $0 == "-" || $0 == " " })
        guard separators.count == 1, let sep = separators.first,
              body.allSatisfy({ $0 == sep || ($0.isASCII && ($0.isLetter || $0.isNumber)) }),
              body.contains(where: \.isNumber) else { return nil }
        let groups = body.split(separator: sep, omittingEmptySubsequences: false)
        let total = groups.reduce(0, { $0 + $1.count })
        // Ten or more characters of code — or exactly two groups of four,
        // which is how Google backup codes and Discord codes are printed. A
        // date is three groups, so it still does not count.
        guard groups.count >= 2, groups.allSatisfy({ (1...10).contains($0.count) }),
              total >= 10 || (groups.count == 2 && groups.allSatisfy { $0.count == 4 })
        else { return nil }
        return "\(sep)" + groups.map { "\($0.count)" }.joined(separator: ".")
    }

    static func detect(_ evidence: Evidence) -> String? {
        let text = [evidence.textExcerpt, evidence.ocrText, evidence.pdfTitle, evidence.pdfAuthor,
                    evidence.sourceURL, evidence.referrerURL]
            .compactMap { $0 }.joined(separator: "\n")
        return detect(text: text)
    }

    static func detect(text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for (kind, regex) in compiled {
            for match in regex.matches(in: text, range: range) {
                // A labelled value that is only a placeholder is documentation.
                if kind == "a labelled key or password",
                   let r = Range(match.range, in: text),
                   let value = text[r].split(whereSeparator: { ",:=\"' ".contains($0) }).last,
                   isPlaceholder(String(value)) { continue }
                return kind
            }
        }
        for match in labelledPassword.matches(in: text, range: range) {
            guard let r = Range(match.range(at: 3), in: text) else { continue }
            let value = String(text[r])
            let hasDigitOrSymbol = value.contains(where: { $0.isNumber || (!$0.isLetter && !$0.isWhitespace) })
            if hasDigitOrSymbol, !isPlaceholder(value) { return "a labelled key or password" }
        }
        var byShape: [String: Set<Substring>] = [:]
        for line in text.split(separator: "\n") {
            if let shape = codeBlockShape(line) { byShape[shape, default: []].insert(line) }
        }
        return byShape.values.contains { $0.count >= 4 } ? "a list of recovery codes" : nil
    }
}
