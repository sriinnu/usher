import XCTest
@testable import Usher

/// Downloads/Dev/Hasklig-main is 47,348 files and one font. A folder that is
/// one thing is filed as one thing, and a folder move always waits for approval.
final class FolderUnitTests: XCTestCase {

    private var root: URL!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("usher-unit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func folder(_ name: String, files: [String]) throws -> URL {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in files {
            let u = dir.appendingPathComponent(f)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: u)
        }
        return dir
    }

    func testGitHubExportIsAUnitByName() throws {
        let d = try folder("Hasklig-main", files: ["a.txt", "b.txt"])
        XCTAssertTrue(FolderUnit.isUnit(d, shape: FolderUnit.shape(of: d)))
    }

    func testRepoMarkerMakesAUnit() throws {
        let d = try folder("Takumi", files: ["Package.swift", "Sources/x.swift"])
        XCTAssertTrue(FolderUnit.isUnit(d, shape: FolderUnit.shape(of: d)))
    }

    func testFontFamilyIsAUnitByDominance() throws {
        let d = try folder("Berkeley Mono v2.002 2", files: (1...20).map { "f\($0).ttf" } + ["readme.txt"])
        let shape = FolderUnit.shape(of: d)
        XCTAssertEqual(shape.dominantExtension, "ttf")
        XCTAssertTrue(FolderUnit.isUnit(d, shape: shape))
    }

    /// A folder of photos is not a download unit; that is the Photos phase.
    func testPhotoDumpIsNotAUnit() throws {
        let d = try folder("Images", files: (1...40).map { "IMG_\($0).jpg" })
        XCTAssertFalse(FolderUnit.isUnit(d, shape: FolderUnit.shape(of: d)))
    }

    func testLooseMixedFolderIsNotAUnit() throws {
        let d = try folder("Books", files: ["a.pdf", "b.pdf", "c.epub", "notes.md"])
        XCTAssertFalse(FolderUnit.isUnit(d, shape: FolderUnit.shape(of: d)))
    }

    /// Keys, app bundles, partial downloads and Usher's own duplicates folder are
    /// never walked and never moved.
    func testExclusions() throws {
        var s = AppSettings.default
        s.duplicatesFolder = root.appendingPathComponent("Duplicates").path
        for name in ["apple-auth-keys-review", "_keys", "Install Spotify.app", "X.pdf.download", "Duplicates", "certs"] {
            let d = try folder(name, files: ["a"])
            XCTAssertTrue(FolderUnit.isExcluded(d, settings: s), name)
        }
        XCTAssertFalse(FolderUnit.isExcluded(try folder("German", files: ["a"]), settings: s))
    }

    func testUnitEvidenceLooksLikeAnArchive() throws {
        let d = try folder("elena_rishi_glyph_pack", files: ["glyphs/a.svg", "glyphs/b.svg", "README.md"])
        let e = EvidenceExtractor.extractUnit(from: d)
        XCTAssertTrue(e.isDirectory)
        XCTAssertEqual(e.fileCount, 3)
        XCTAssertEqual(e.archiveEntries?.contains("glyphs/a.svg"), true)
        XCTAssertEqual(e.nameCandidates, ["elena_rishi_glyph_pack"], "folders keep their name")
    }
}

extension FolderUnitTests {
    /// "Berkeley Mono v2.002" was planned as "Berkeley Mono v2": the mover took
    /// ".002" for a file extension. A folder keeps its whole name.
    func testFolderNamesAreNeverSplitOnDots() throws {
        for name in ["Berkeley Mono v2.002", "gh_2.86.0_macOS_amd64", "Foody_2.0", "Hasklig-main"] {
            let d = try folder(name, files: ["a.ttf"])
            let e = EvidenceExtractor.extractUnit(from: d)
            let plan = Mover.plan(source: d, folder: root.appendingPathComponent("dest"),
                                  template: "{name}", chosenName: name, evidence: e)
            XCTAssertEqual(plan.destination.lastPathComponent, name)
        }
    }
}

final class EmptyFolderUnitTests: XCTestCase {
    /// `moltbot-main` was an empty folder. It matched the "-main" name pattern
    /// before anything looked inside, went to the API as "folder of 0 files",
    /// came back unsorted — and unsorted is retried on every config change.
    func testAnEmptyFolderIsNotAUnit() throws {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("usher-\(UUID())")
        let dir = parent.appendingPathComponent("moltbot-main")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        XCTAssertFalse(FolderUnit.isUnit(dir, shape: FolderUnit.shape(of: dir)))

        try Data("x".utf8).write(to: dir.appendingPathComponent("readme.md"))
        XCTAssertTrue(FolderUnit.isUnit(dir, shape: FolderUnit.shape(of: dir)),
                      "the same folder with a file in it is still a unit")
    }
}
