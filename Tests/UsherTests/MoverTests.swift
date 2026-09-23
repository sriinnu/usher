import XCTest
@testable import Usher

/// Regression: a file already sitting in its destination collided with *itself*,
/// got planned as "… 2", and the resulting rename fired another FSEvent — an
/// endless rename loop over every file in a watched destination folder.
final class MoverTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("usher-mover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func make(_ name: String, _ contents: String = "x") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func evidence(_ name: String) -> Evidence {
        Evidence(filename: name, ext: (name as NSString).pathExtension, sizeBytes: 1)
    }

    func testFileAlreadyInPlaceIsANoOp() throws {
        let file = try make("report.pdf")
        let plan = Mover.plan(source: file, folder: dir, template: "{name}.{ext}",
                              chosenName: "report.pdf", evidence: evidence("report.pdf"))
        XCTAssertTrue(Mover.isNoOp(plan), "a file in its own destination must not move")
        XCTAssertEqual(plan.destination.lastPathComponent, "report.pdf")
    }

    func testRenameInPlaceIsNotANoOp() throws {
        let file = try make("ugly (Z-Library).pdf")
        let plan = Mover.plan(source: file, folder: dir, template: "{name}.{ext}",
                              chosenName: "clean.pdf", evidence: evidence("ugly (Z-Library).pdf"))
        XCTAssertFalse(Mover.isNoOp(plan))
        XCTAssertEqual(plan.destination.lastPathComponent, "clean.pdf")
    }

    func testGenuineCollisionGetsASuffix() throws {
        _ = try make("taken.pdf", "existing")
        let incoming = try make("incoming.pdf", "new")
        let plan = Mover.plan(source: incoming, folder: dir, template: "{name}.{ext}",
                              chosenName: "taken.pdf", evidence: evidence("incoming.pdf"))
        XCTAssertEqual(plan.destination.lastPathComponent, "taken 2.pdf")
    }

    func testTemplateTokens() throws {
        let file = try make("photo.jpg")
        var e = evidence("photo.jpg")
        e.sourceHost = "example.com"
        let plan = Mover.plan(source: file, folder: dir, template: "{yyyy}-{source_host}-{name}.{ext}",
                              chosenName: "photo.jpg", evidence: e)
        let name = plan.destination.lastPathComponent
        XCTAssertTrue(name.contains("example.com"), name)
        XCTAssertTrue(name.hasSuffix("photo.jpg"), name)
    }
}

extension MoverTests {
    /// A file was filed as "…(z-library.sk, 1lib.sk, z-lib.sk).pdf" because the
    /// raw original was among the model's options. Whatever is chosen, the
    /// mirror junk must be gone by the time a path is planned.
    func testMirrorJunkNeverSurvivesWhateverNameWasChosen() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("usher-junk-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let raw = "German Grammar Simplified (Coles Notes) (z-library.sk, 1lib.sk, z-lib.sk).pdf"
        let src = dir.appendingPathComponent(raw)
        try Data("x".utf8).write(to: src)
        let e = Evidence(filename: raw, ext: "pdf", sizeBytes: 1)

        // The model "chose" the raw original.
        let plan = Mover.plan(source: src, folder: dir, template: "{name}.{ext}", chosenName: raw, evidence: e)
        XCTAssertEqual(plan.destination.lastPathComponent, "German Grammar Simplified (Coles Notes).pdf")

        // And the raw original is not even offered as a candidate any more.
        let offered = NameCandidates.build(for: src, evidence: e)
        XCTAssertFalse(offered.contains(raw), "raw junk name must not be a candidate: \(offered)")
        XCTAssertTrue(offered.contains("German Grammar Simplified (Coles Notes).pdf"))
    }
}

final class TrashRoundTripTests: XCTestCase {
    /// Delete from the panel means the Trash, and the Trash copy is the undo:
    /// the file must come back to the exact path it left.
    func testTrashThenUndoRestoresTheFileWhereItWas() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("usher-trash-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("junk.pdf")
        try Data("x".utf8).write(to: file)

        let binned = try Mover.trash(file)
        defer { try? FileManager.default.removeItem(at: binned) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: binned.path))
        XCTAssertTrue(binned.path.contains(".Trash"), binned.path)

        let back = try Mover.undo(from: binned, to: file)
        XCTAssertEqual(back.canonicalPath, file.canonicalPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}
