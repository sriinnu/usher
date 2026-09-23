import XCTest
@testable import Usher

/// Every destination used to be an absolute iCloud path, so a file found in
/// Google Drive would have been moved to iCloud. `{root}` resolves per file
/// against its watched folder's root; unset means the default, as before.
final class DestinationRootTests: XCTestCase {

    private let icloud = URL(fileURLWithPath: "/Users/x/Library/Mobile Documents/com~apple~CloudDocs")
    private let gdrive = URL(fileURLWithPath: "/Users/x/Library/CloudStorage/GoogleDrive-tester@example.com")

    func testPlaceholderResolvesAgainstTheGivenRoot() {
        XCTAssertEqual(DestinationRoot.resolve("{root}/German", root: icloud).path,
                       icloud.appendingPathComponent("German").path)
        XCTAssertEqual(DestinationRoot.resolve("{root}/German", root: gdrive).path,
                       gdrive.appendingPathComponent("German").path)
    }

    func testAbsolutePathsAreLeftAlone() {
        XCTAssertEqual(DestinationRoot.resolve("/Volumes/Archive/Books", root: gdrive).path, "/Volumes/Archive/Books")
    }

    func testUnsetFolderUsesTheDefaultRoot() {
        var s = AppSettings.default
        s.defaultDestinationRoot = icloud.path
        s.watchFolders = [WatchFolder(path: "/Users/x/Downloads")]
        let r = DestinationRoot.root(for: URL(fileURLWithPath: "/Users/x/Downloads/a.pdf"), settings: s)
        XCTAssertEqual(r.path, icloud.path)
    }

    /// The whole point: a Drive watch files back into Drive, never across.
    func testExplicitRootConfinesDestinations() {
        var s = AppSettings.default
        s.defaultDestinationRoot = icloud.path
        var drive = WatchFolder(path: gdrive.appendingPathComponent("Inbox").path)
        drive.destinationRoot = gdrive.path
        s.watchFolders = [WatchFolder(path: "/Users/x/Downloads"), drive]

        let file = gdrive.appendingPathComponent("Inbox/report.pdf")
        let root = DestinationRoot.root(for: file, settings: s)
        XCTAssertEqual(root.path, gdrive.path)

        let leaf = RouteLeaf(key: "german", description: "", path: "{root}/German", template: "{name}.{ext}")
        XCTAssertTrue(leaf.destination(root: root).path.hasPrefix(gdrive.path))
        XCTAssertFalse(leaf.destination(root: root).path.contains("CloudDocs"))

        let rule = LocalRule(name: "LIC", filenamePattern: "lic", destination: "{root}/Personal/LIC")
        XCTAssertTrue(rule.destinationURL(root: root).path.hasPrefix(gdrive.path))
    }

    func testLongestMatchingWatchFolderWins() {
        var s = AppSettings.default
        var inner = WatchFolder(path: "/Users/x/Downloads/Work"); inner.destinationRoot = "/Users/x/Work"
        s.watchFolders = [WatchFolder(path: "/Users/x/Downloads"), inner]
        XCTAssertEqual(DestinationRoot.root(for: URL(fileURLWithPath: "/Users/x/Downloads/Work/a.pdf"), settings: s).path, "/Users/x/Work")
        XCTAssertEqual(DestinationRoot.root(for: URL(fileURLWithPath: "/Users/x/Downloads/a.pdf"), settings: s).path,
                       (s.defaultDestinationRoot as NSString).expandingTildeInPath)
    }

    func testAllRootsIncludesDefaultAndEveryExplicitOne() {
        var s = AppSettings.default
        var d = WatchFolder(path: "/x/d"); d.destinationRoot = gdrive.path
        s.watchFolders = [d, d]
        let roots = DestinationRoot.allRoots(settings: s).map(\.path)
        XCTAssertEqual(roots.count, 2, "default + one distinct explicit root")
        XCTAssertTrue(roots.contains(gdrive.path))
    }
}
