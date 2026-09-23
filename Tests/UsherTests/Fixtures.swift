import Foundation

/// Every secret the tests need, and none of them real.
///
/// Each value is assembled at runtime from obvious TEST parts, so the shape the
/// detectors look for exists only in memory, never as a literal in source.
/// That keeps test files free of anything a reader or GitHub's secret scanning
/// could mistake for a leak — and `NoRealSecretsInTests` fails the suite if a
/// secret-shaped literal ever appears in a test file again.
///
/// Never paste a real key, code, phone number, IBAN or name here "to test".
enum Fake {
    private static func t(_ n: Int, _ unit: String = "TEST") -> String { String(repeating: unit, count: n) }

    // Private keys
    static let opensshKey  = "-----BEGIN " + "OPENSSH PRIVATE KEY" + "-----\n" + "TESTONLY"
    static let rsaKey      = "-----BEGIN " + "RSA PRIVATE KEY" + "-----\n" + "TESTONLY"
    static let pgpKey      = "-----BEGIN " + "PGP PRIVATE KEY BLOCK" + "-----\n" + "TESTONLY"
    /// "-----BEGIN" in base64, as a kubeconfig carries it.
    static let encodedPEM  = "client-key-data: " + "LS0tLS1C" + "RUdJTi" + t(5)

    // Provider tokens
    static let openAIKey   = "sk-" + "proj-" + t(7)
    static let awsKey      = "AKIA" + t(4)
    static let githubToken = "ghp_" + t(9)
    static let hfToken     = "hf_" + t(8)
    static let azureKey    = "DefaultEndpointsProtocol=https;" + "Account" + "Key=" + t(11)
    static let signedURL   = "https://bucket.example.com/f.pdf?X-Amz-" + "Signature=" + t(5, "test")
    static let otpSeed     = "otp" + "auth://totp/Test:tester?secret=" + t(3)
    static let urlWithPassword = "postgres://" + "tester:" + "testpass" + "@db.example.com/test"
    static let cookieFile  = "# Netscape " + "HTTP Cookie File\n.example.com\tTRUE"
    static let oauthClientJSON = #"{"installed":{"client_id":"test","client_"# + #"secret":"test"}}"#

    // Labelled values
    static let labelledCSV = "id,1234567\n" + "api" + "Key,test-test-t." + t(6, "test") + "\n"
    static let labelledEnv = "OPENAI_API_" + "KEY=" + t(7, "test")
    static let germanPassword = "Pass" + "wort: Test24!x"

    // Password-manager exports
    static let bitwardenJSON = #"{"items":[{"login":{"username":"tester@example.com","pass"# + #"word":"Test1234"}}]}"#
    static let firefoxCSV = "\"url\",\"username\",\"pass" + "word\",\"httpRealm\"\n\"https://example.com\",\"tester\",\"Test1234!\",\"\""
    static let chromeCSV  = "name,url,username,pass" + "word\ntest,https://example.com,tester,Test1234"

    // Recovery codes: synthetic, but in the real layouts the detector must catch.
    /// `5-5`, six lines.
    static let recoveryCodes = (1...6).map { "test\($0)-code\($0)" }.joined(separator: "\n")
    /// `8-8`, the layout of a plain recovery-codes.txt.
    static let recoveryCodes8x8 = (1...4).map { "test000\($0)-code000\($0)" }.joined(separator: "\n")
    /// Numbered `5-5-5-5-5-1`, the layout of a service's recovery-key export.
    static let numberedRecoveryKeys = "Recovery keys\nKeep these safe.\n"
        + (1...4).map { "\($0). test\($0)-code\($0)-tests-codes-tests-x" }.joined(separator: "\n")
    /// `4 4`, the layout of printed backup codes.
    static let backupCodes = (1...5).map { "\($0)\($0)\($0)\($0) 000\($0)" }.joined(separator: "\n")

    // Documentation that must NOT count as a secret
    static let placeholderEnv = "export API_" + "KEY=" + "YOUR_API_KEY_HERE"
    static let placeholderAngle = "Set OPENAI_API_" + "KEY=<your key> in .env"
    static let passwordProse = "Pass" + "word: required"

    // Apple key file name — the one fixture ID the guard allows.
    static let appleKeyFile = "AuthKey_ABCDE12345.p8"
}
