import XCTest
@testable import Usher

/// Google Drive was added to the watch list recursively, Trash included, and
/// 2,108 RoboForm passcards went to the API by filename before anything looked
/// at the extension. Each name is a site plus an account.
final class NeverSendTests: XCTestCase {

    func testPasswordManagerFormatsAreHeldBeforeAnyPatternIsConsulted() {
        var s = AppSettings.default
        s.sensitivePatterns = []                    // extension alone must be enough
        for name in ["Americanexpress - user.rfp", "vault.kdbx", "export.1pif", "id_rsa.pem"] {
            let e = Evidence(filename: name, ext: (name as NSString).pathExtension, sizeBytes: 1)
            XCTAssertTrue(SensitiveFilter.check(e, settings: s).isSensitive, "\(name) must be held")
        }
    }

    func testTrashAndSourceTreesAreNeverWatched() {
        let skipped = [
            "/Volumes/GDrive/.Trash/Americanexpress - user.rfp",
            "/Users/x/Downloads/Dev/app/node_modules/left-pad/index.js",
            "/Users/x/Downloads/repo/.git/objects/ab/cdef",
            "/Users/x/Downloads/proj/.build/release/Usher"
        ]
        for path in skipped {
            XCTAssertTrue(StabilityGate.shouldIgnore(URL(fileURLWithPath: path)), "\(path) must be skipped")
        }
        XCTAssertFalse(StabilityGate.shouldIgnore(URL(fileURLWithPath: "/Users/x/Downloads/report.pdf")))
    }

    func testOldConfigStillDecodesWithTheNewKeyAbsent() throws {
        let legacy = #"{"watchFolders":[],"dryRun":true,"autoMoveThreshold":0.8,"askThreshold":0.45,"model":"jev-latest","sensitivePatterns":[],"sensitiveHosts":[]}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        XCTAssertTrue(s.sensitiveExtensions.contains("rfp"), "absent key must fall back to the default list")
    }
}
