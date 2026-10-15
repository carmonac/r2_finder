// TransferServiceTests.swift
// Ports of the transfer.zig integration tests, using the bundled bin/rsync.

import XCTest
@testable import R2FinderServices

final class TransferServiceTests: XCTestCase {
    var base = ""
    var srcDir = ""
    var dstDir = ""

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: rsyncPath),
                          "bin/rsync not found — run from a full checkout")
        base = try makeScratchDir("transfer")
        srcDir = base + "/src"
        dstDir = base + "/dst"
        try FileManager.default.createDirectory(atPath: srcDir, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(atPath: dstDir, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: base)
    }

    func testCopyFilesCopiesFileToDestination() throws {
        try write("hello from rs_2finder\n", to: srcDir + "/hello.txt")

        let done = Completion()
        TransferService.copy(rsyncPath: rsyncPath, sources: [srcDir + "/hello.txt"],
                             dstDir: dstDir, conflict: .replace,
                             onProgress: { _, _, _, _, _ in },
                             onDone: done.handler)
        XCTAssertTrue(done.wait())
        XCTAssertTrue(done.success, done.message ?? "")

        XCTAssertTrue(FileManager.default.fileExists(atPath: dstDir + "/hello.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: srcDir + "/hello.txt"),
                      "copy must keep the original")
    }

    func testCopyRespectsOverwriteFalse() throws {
        try write("original", to: dstDir + "/data.txt")
        try write("new", to: srcDir + "/data.txt")

        let done = Completion()
        // .skip → rsync --ignore-existing
        TransferService.copy(rsyncPath: rsyncPath, sources: [srcDir + "/data.txt"],
                             dstDir: dstDir, conflict: .skip,
                             onProgress: { _, _, _, _, _ in },
                             onDone: done.handler)
        XCTAssertTrue(done.wait())
        XCTAssertTrue(done.success, done.message ?? "")

        XCTAssertEqual(try String(contentsOfFile: dstDir + "/data.txt", encoding: .utf8), "original")
    }

    func testMoveFilesMovesAndRemovesSource() throws {
        try write("move me\n", to: srcDir + "/move_me.txt")

        let done = Completion()
        TransferService.move(rsyncPath: rsyncPath, sources: [srcDir + "/move_me.txt"],
                             dstDir: dstDir, conflict: .replace,
                             onProgress: { _, _, _, _, _ in },
                             onDone: done.handler)
        XCTAssertTrue(done.wait())
        XCTAssertTrue(done.success, done.message ?? "")

        XCTAssertTrue(FileManager.default.fileExists(atPath: dstDir + "/move_me.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: srcDir + "/move_me.txt"))
    }

    func testMoveDirectoryOnSameVolumeRenames() throws {
        try FileManager.default.createDirectory(atPath: srcDir + "/folder/sub",
                                                withIntermediateDirectories: true)
        try write("nested\n", to: srcDir + "/folder/sub/file.txt")
        let inodeBefore = try inode(srcDir + "/folder")

        let done = Completion()
        TransferService.move(rsyncPath: rsyncPath, sources: [srcDir + "/folder"],
                             dstDir: dstDir, conflict: .skip,
                             onProgress: { _, _, _, _, _ in },
                             onDone: done.handler)
        XCTAssertTrue(done.wait())
        XCTAssertTrue(done.success, done.message ?? "")

        XCTAssertFalse(FileManager.default.fileExists(atPath: srcDir + "/folder"))
        XCTAssertEqual(try String(contentsOfFile: dstDir + "/folder/sub/file.txt", encoding: .utf8),
                       "nested\n")
        XCTAssertEqual(try inode(dstDir + "/folder"), inodeBefore,
                       "same-volume move must rename, not copy")
    }

    func testMoveWithExistingTargetFallsBackToRsync() throws {
        try write("original", to: dstDir + "/data.txt")
        try write("new", to: srcDir + "/data.txt")

        let done = Completion()
        TransferService.move(rsyncPath: rsyncPath, sources: [srcDir + "/data.txt"],
                             dstDir: dstDir, conflict: .replace,
                             onProgress: { _, _, _, _, _ in },
                             onDone: done.handler)
        XCTAssertTrue(done.wait())
        XCTAssertTrue(done.success, done.message ?? "")

        XCTAssertEqual(try String(contentsOfFile: dstDir + "/data.txt", encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: srcDir + "/data.txt"))
    }

    func testMoveWithoutOverwriteKeepsSkippedSourceFiles() throws {
        try FileManager.default.createDirectory(atPath: srcDir + "/folder/sub",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dstDir + "/folder",
                                                withIntermediateDirectories: false)
        try write("dst version", to: dstDir + "/folder/clash.txt")
        try write("src version", to: srcDir + "/folder/clash.txt")
        try write("only in src", to: srcDir + "/folder/sub/fresh.txt")

        let done = Completion()
        // .skip → rsync --ignore-existing skips clash.txt
        TransferService.move(rsyncPath: rsyncPath, sources: [srcDir + "/folder"],
                             dstDir: dstDir, conflict: .skip,
                             onProgress: { _, _, _, _, _ in },
                             onDone: done.handler)
        XCTAssertTrue(done.wait())
        XCTAssertTrue(done.success, done.message ?? "")

        XCTAssertEqual(try String(contentsOfFile: dstDir + "/folder/clash.txt", encoding: .utf8),
                       "dst version")
        XCTAssertEqual(try String(contentsOfFile: srcDir + "/folder/clash.txt", encoding: .utf8),
                       "src version", "skipped file must survive in the source")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dstDir + "/folder/sub/fresh.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: srcDir + "/folder/sub"),
                       "directories emptied by the move are cleaned up")
    }

    func testCopyKeepBothRenamesClashingFileAndFolder() throws {
        try write("dst", to: dstDir + "/data.txt")
        try write("dst 2", to: dstDir + "/data 2.txt")
        try write("src", to: srcDir + "/data.txt")
        try FileManager.default.createDirectory(atPath: dstDir + "/folder",
                                                withIntermediateDirectories: false)
        try FileManager.default.createDirectory(atPath: srcDir + "/folder/sub",
                                                withIntermediateDirectories: true)
        try write("nested", to: srcDir + "/folder/sub/file.txt")
        try write("no clash", to: srcDir + "/other.txt")

        let done = Completion()
        TransferService.copy(rsyncPath: rsyncPath,
                             sources: [srcDir + "/data.txt", srcDir + "/folder", srcDir + "/other.txt"],
                             dstDir: dstDir, conflict: .keepBoth,
                             onProgress: { _, _, _, _, _ in },
                             onDone: done.handler)
        XCTAssertTrue(done.wait())
        XCTAssertTrue(done.success, done.message ?? "")

        XCTAssertEqual(try String(contentsOfFile: dstDir + "/data.txt", encoding: .utf8), "dst")
        XCTAssertEqual(try String(contentsOfFile: dstDir + "/data 2.txt", encoding: .utf8), "dst 2")
        XCTAssertEqual(try String(contentsOfFile: dstDir + "/data 3.txt", encoding: .utf8), "src")
        XCTAssertEqual(try String(contentsOfFile: dstDir + "/folder 2/sub/file.txt", encoding: .utf8),
                       "nested", "folder copied whole under the new name, not nested inside it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dstDir + "/other.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: srcDir + "/data.txt"))
    }

    func testMoveKeepBothRenamesClashingFolder() throws {
        try FileManager.default.createDirectory(atPath: dstDir + "/folder",
                                                withIntermediateDirectories: false)
        try write("dst", to: dstDir + "/folder/file.txt")
        try FileManager.default.createDirectory(atPath: srcDir + "/folder",
                                                withIntermediateDirectories: false)
        try write("src", to: srcDir + "/folder/file.txt")

        let done = Completion()
        TransferService.move(rsyncPath: rsyncPath, sources: [srcDir + "/folder"],
                             dstDir: dstDir, conflict: .keepBoth,
                             onProgress: { _, _, _, _, _ in },
                             onDone: done.handler)
        XCTAssertTrue(done.wait())
        XCTAssertTrue(done.success, done.message ?? "")

        XCTAssertEqual(try String(contentsOfFile: dstDir + "/folder/file.txt", encoding: .utf8), "dst")
        XCTAssertEqual(try String(contentsOfFile: dstDir + "/folder 2/file.txt", encoding: .utf8), "src")
        XCTAssertFalse(FileManager.default.fileExists(atPath: srcDir + "/folder"))
    }

    func testFreeNameFollowsFinderStyle() throws {
        try write("", to: dstDir + "/photo.jpg")
        try write("", to: dstDir + "/photo 2.jpg")
        XCTAssertEqual(TransferService.freeName(for: "photo.jpg", in: dstDir + "/"), "photo 3.jpg")
        XCTAssertEqual(TransferService.freeName(for: "Folder", in: dstDir + "/"), "Folder 2")
        XCTAssertEqual(TransferService.freeName(for: ".env", in: dstDir + "/"), ".env 2")
        XCTAssertEqual(TransferService.freeName(for: "a.txt", in: dstDir + "/", taken: ["a 2.txt"]),
                       "a 3.txt")
    }

    private func inode(_ path: String) throws -> UInt64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        return (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }

    func testFailedTransferReportsError() {
        let done = Completion()
        TransferService.copy(rsyncPath: rsyncPath, sources: [base + "/does_not_exist.txt"],
                             dstDir: dstDir, conflict: .replace,
                             onProgress: { _, _, _, _, _ in },
                             onDone: done.handler)
        XCTAssertTrue(done.wait())
        XCTAssertFalse(done.success)
        XCTAssertNotNil(done.message)
    }
}
