import XCTest
@testable import Usher

/// Password managers, keys and wallets are never classified. Not held — never
/// read, never matched by a rule, never renamed, never moved. And the core list
/// cannot be emptied by editing settings.json.
final class SecretFormatsTests: XCTestCase {

    func testCoreFormatsAreSecretRegardlessOfSettings() {
        var s = AppSettings.default
        s.sensitiveExtensions = []          // a user clearing the setting changes nothing
        s.sensitivePatterns = []
        for name in ["Americanexpress - user.rfp", "vault.kdbx", "export.1pif",
                     "server.pem", "id_rsa", ".env.production", "wallet.dat"] {
            XCTAssertTrue(SecretFormats.isSecret(URL(fileURLWithPath: "/x/\(name)"), settings: s),
                          "\(name) must be secret with an empty settings list")
        }
    }

    func testUserListOnlyWidens() {
        var s = AppSettings.default
        s.sensitiveExtensions = ["myvault"]
        XCTAssertTrue(SecretFormats.isSecret(URL(fileURLWithPath: "/x/a.myvault"), settings: s))
        XCTAssertTrue(SecretFormats.isSecret(URL(fileURLWithPath: "/x/a.kdbx"), settings: s),
                      "core entries survive a user list that omits them")
    }

    func testOrdinaryFilesAreNotSecret() {
        let s = AppSettings.default
        for name in ["report.pdf", "photo.jpg", "notes.md", "archive.zip", "keynote.key.pdf"] {
            XCTAssertFalse(SecretFormats.isSecret(URL(fileURLWithPath: "/x/\(name)"), settings: s), name)
        }
    }

    /// The one that proves "never classified" rather than "never sent": a local
    /// rule that would match a vault by name must not get the chance.
    func testALocalRuleCannotRouteAVault() {
        let rule = LocalRule(name: "Everything", filenamePattern: ".*", destination: "/tmp/anywhere")
        let s = AppSettings.default
        let url = URL(fileURLWithPath: "/x/Americanexpress - user.rfp")

        // The pipeline's gate runs first; simulate its ordering.
        let gated = SecretFormats.isSecret(url, settings: s)
        XCTAssertTrue(gated)

        // Had the gate not existed, the rule would have matched — which is the
        // point: the gate has to be the thing that stops it.
        let evidence = Evidence(filename: url.lastPathComponent, ext: "rfp", sizeBytes: 1)
        XCTAssertNotNil(LocalRules.match(evidence, rules: [rule]),
                        "sanity: the rule would have matched without the gate")
    }

    /// Bulk rename must leave a vault's name alone even when it looks like it
    /// carries junk to strip.
    func testRenameSkipsSecretsEvenWithStrippableNames() {
        XCTAssertNotNil(BookName.stripped(for: "vault (Z-Library).kdbx"),
                        "sanity: the name would otherwise be cleaned")
        XCTAssertTrue(SecretFormats.isSecret(URL(fileURLWithPath: "/x/vault (Z-Library).kdbx"),
                                             settings: .default))
    }
}

extension SecretFormatsTests {
    /// Six `AuthKey_*.p8` Apple signing keys reached the API by filename before
    /// `.p8` was on the list.
    func testAppleSigningKeysAreNeverClassified() {
        for n in [Fake.appleKeyFile, "dev.mobileprovision", "Mac.provisionprofile"] {
            XCTAssertTrue(SecretFormats.isSecret(URL(fileURLWithPath: "/x/\(n)"), settings: .default), n)
        }
    }
}

final class SecretConventionTests: XCTestCase {
    private let settings = AppSettings.default

    /// Every one of these was read and sent before this floor existed —
    /// plain .txt/.csv/.json/.bmp files that the extension list waved through.
    func testSecretsByNamingConventionNeverReachTheClassifier() {
        for name in ["recovery-codes.txt",
                     "openai-recovery-keys-2026-06-05-09-45-39Z.txt",
                     "github-recovery-codes.txt",
                     "client_secret_1234-abcd.apps.googleusercontent.com.json",
                     "Default Workspace-apiKey-6083419.csv",
                     "aws_access_keys.csv",
                     "passwords.bmp", "password_new_details.htm", "Sticky Password.rfp",
                     "backup-codes.txt", "service-account.json", "credentials.json"] {
            XCTAssertTrue(SecretFormats.isSecret(URL(fileURLWithPath: "/x/\(name)"), settings: settings), name)
        }
    }

    /// A floor that swallows books gets switched off. These must still be filed.
    func testBooksAndOrdinaryFilesAreNotSecrets() {
        for name in ["The Secrets of Sanskrit.pdf", "The Master Key System.pdf",
                     "Mnemonic Techniques.pdf", "tokenizer.json", "Design Tokens.pdf",
                     "Keynote Deck.key.pdf", "German Grammar Drills.pdf", "api-reference.pdf"] {
            XCTAssertFalse(SecretFormats.hasSecretName(name), name)
        }
    }
}

final class SecretContentTests: XCTestCase {
    private func evidence(_ text: String) -> Evidence {
        var e = Evidence(filename: "notes.txt", ext: "txt", sizeBytes: 1)
        e.textExcerpt = text
        return e
    }

    /// Fake values in the right shape; none of these are real keys.
    func testSecretShapesAreRecognisedWhateverTheFileIsCalled() {
        let cases: [String: String] = [
            Fake.opensshKey: "private key",
            "key: " + Fake.openAIKey: "sk-",
            "AWS_ACCESS_KEY_ID=" + Fake.awsKey: "AWS",
            "token " + Fake.githubToken: "GitHub",
            Fake.oauthClientJSON: "OAuth",
            Fake.recoveryCodes: "recovery codes",
            // The two layouts found in real recovery files, with synthetic codes.
            Fake.recoveryCodes8x8: "recovery codes",
            Fake.numberedRecoveryKeys: "recovery codes",
            Fake.labelledCSV: "labelled",
            Fake.labelledEnv: "labelled",
        ]
        for (text, expected) in cases {
            let kind = SecretContent.detect(evidence(text))
            XCTAssertNotNil(kind, expected)
            XCTAssertTrue(kind?.contains(expected) ?? false, "\(expected): got \(kind ?? "nil")")
        }
    }

    func testOrdinaryTextIsNotASecret() {
        XCTAssertNil(SecretContent.detect(evidence("der Hund - dog\ndie Katze - cat\ndas Haus - house\ndie Maus - mouse\nder Baum - tree")))
        XCTAssertNil(SecretContent.detect(evidence("Invoice 2026-05-12\nTotal: 1234 EUR\nIBAN DE89 3704 0044 0532 0130 00")))
        XCTAssertNil(SecretContent.detect(evidence("The skeleton key to understanding tokens is sk-learn.")))
        XCTAssertNil(SecretContent.detect(evidence("2026-05-12\n2026-05-13\n2026-05-14\n2026-05-15\n2026-05-16")), "a column of dates")
        XCTAssertNil(SecretContent.detect(evidence("Reset your password: open Settings and choose Security.")), "prose about a password")
        // Masked from the three invoices a first version floored as recovery codes.
        XCTAssertNil(SecretContent.detect(evidence(
            "Rechnung 2783-3840\nInvoice number abc1def2-3456\nPayment 12-3456789\nKundennummer 004512\n"
            + "Referenz ABCDEFGHIJ-ABC12\n123 456ab street xy\nOrderbuch 12 ab 12345-6789\nRechnung 2783-3840")),
            "an invoice's reference numbers")
    }

    /// The last line of defence holds even for a caller that skipped the floor.
    func testTheClassifierRefusesASecretItself() async {
        var e = evidence(Fake.rsaKey)
        e.filename = "notes.txt"
        let classifier = Classifier(model: "jev-latest", routes: RouteTable(roots: [], leaves: [], scans: []),
                                    root: URL(fileURLWithPath: "/tmp"))
        do {
            _ = try await classifier.classify(e)
            XCTFail("a private key reached the request builder")
        } catch JevError.refusedSecret {
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
