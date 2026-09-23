import XCTest
@testable import Usher

/// The German folder held two 2.4MB mp3s — Track41 and Track44 — that are not the
/// same audio. Anything that convicts on size alone deletes real material.
final class DuplicatesTests: XCTestCase {

    private var dest: URL!
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("usher-dupe-\(UUID().uuidString)")
        dest = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ path: URL, _ contents: String) throws -> URL {
        try Data(contents.utf8).write(to: path)
        return path
    }

    func testIdenticalBytesAreADuplicate() throws {
        try write(dest.appendingPathComponent("original.pdf"), "identical contents here")
        let incoming = try write(root.appendingPathComponent("copy.pdf"), "identical contents here")

        guard case .duplicateOf(let existing) = Duplicates.check(incoming, against: dest) else {
            return XCTFail("byte-identical file should be reported as a duplicate")
        }
        XCTAssertEqual(existing.lastPathComponent, "original.pdf")
    }

    func testSameSizeDifferentBytesIsNotADuplicate() throws {
        try write(dest.appendingPathComponent("track41.mp3"), "AAAAAAAAAAAAAAAAAAAA")
        let incoming = try write(root.appendingPathComponent("track44.mp3"), "BBBBBBBBBBBBBBBBBBBB")

        XCTAssertEqual(Duplicates.size(of: incoming), 20)
        guard case .unique = Duplicates.check(incoming, against: dest) else {
            return XCTFail("same size but different bytes must not be called a duplicate")
        }
    }

    func testDifferentSizeSkipsHashingEntirely() throws {
        try write(dest.appendingPathComponent("a.pdf"), "short")
        let incoming = try write(root.appendingPathComponent("b.pdf"), "considerably longer content")
        guard case .unique = Duplicates.check(incoming, against: dest) else {
            return XCTFail("different sizes cannot be duplicates")
        }
    }

    func testFileDoesNotMatchItself() throws {
        let file = try write(dest.appendingPathComponent("self.pdf"), "contents")
        guard case .unique = Duplicates.check(file, against: dest) else {
            return XCTFail("a file must not be reported as a duplicate of itself")
        }
    }
}

final class FolderNameCandidatesTests: XCTestCase {
    private func ev(_ name: String, url: String? = nil, ref: String? = nil) -> Evidence {
        var e = Evidence(filename: name, ext: (name as NSString).pathExtension, sizeBytes: 1)
        e.sourceURL = url; e.referrerURL = ref
        return e
    }

    /// The first live pass proposed folders called "98d1d F5", "Attachment" and
    /// "Snsd91g m1j1lsntkAv1n5xvh7mp". A proposal made of ids is worse than none.
    func testOpaqueNamesProposeNothing() {
        XCTAssertEqual(FolderNameCandidates.build(for: ev("98d1d0f5-0182-41a5-9ef1-f947c189486b.jpe")), [])
        XCTAssertEqual(FolderNameCandidates.build(for: ev("IMG_1783 2 (1).jpg",
            url: "https://cdn.example/Snsd91g_m1j1lsntkAv1n5xvh7mp.jpg")), [])
        XCTAssertEqual(FolderNameCandidates.build(for: ev("20260509_165937.jpg", url: "https://x/Attachment")), [])
    }

    func testRealNamesStillPropose() {
        let names = FolderNameCandidates.build(for: ev("alia-bhatt-red-carpet-met-gala.jpg"))
        XCTAssertTrue(names.contains("Alia Bhatt"), "\(names)")
    }
}
