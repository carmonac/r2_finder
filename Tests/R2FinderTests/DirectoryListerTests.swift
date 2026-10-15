// DirectoryListerTests.swift
// Ports of the dir_listing.zig unit tests, plus sort-order coverage.

import XCTest
@testable import R2FinderServices

final class DirectoryListerTests: XCTestCase {
    var base = ""

    override func setUpWithError() throws {
        base = try makeScratchDir("dirlisting")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: base)
    }

    func testListsEntriesDirsFirst() throws {
        try FileManager.default.createDirectory(atPath: base + "/subdir", withIntermediateDirectories: false)
        try write("hello", to: base + "/afile.txt")

        let entries = try XCTUnwrap(DirectoryLister.list(path: base))
        XCTAssertGreaterThanOrEqual(entries.count, 2)
        XCTAssertTrue(entries[0].isDir, "first entry should be the directory")
        XCTAssertEqual(entries[0].name, "subdir")
    }

    func testNonExistentPathReturnsNil() {
        XCTAssertNil(DirectoryLister.list(path: "/tmp/__r2_nonexistent_dir__"))
    }

    func testSortIsCaseInsensitive() throws {
        try write("", to: base + "/banana.txt")
        try write("", to: base + "/Apple.txt")
        try write("", to: base + "/cherry.txt")

        let entries = try XCTUnwrap(DirectoryLister.list(path: base))
        XCTAssertEqual(entries.map(\.name), ["Apple.txt", "banana.txt", "cherry.txt"])
    }

    func testSymlinkToDirectoryCountsAsDirectory() throws {
        try FileManager.default.createDirectory(atPath: base + "/real_dir", withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: base + "/link_dir",
                                                  withDestinationPath: base + "/real_dir")

        let entries = try XCTUnwrap(DirectoryLister.list(path: base))
        let link = try XCTUnwrap(entries.first { $0.name == "link_dir" })
        XCTAssertTrue(link.isSymlink)
        XCTAssertTrue(link.isDir)
    }

    func testFileMetadata() throws {
        try write("12345", to: base + "/five.txt")

        let entries = try XCTUnwrap(DirectoryLister.list(path: base))
        let file = try XCTUnwrap(entries.first { $0.name == "five.txt" })
        XCTAssertFalse(file.isDir)
        XCTAssertEqual(file.size, 5)
        XCTAssertGreaterThan(file.mtime, 0)
    }
}

final class VolumeServiceTests: XCTestCase {

    func testVolumesDoesNotCrashAndPathsAreUnderVolumes() {
        for v in VolumeService.volumes() {
            XCTAssertTrue(v.path.hasPrefix("/Volumes/"))
            XCTAssertFalse(v.name.isEmpty)
        }
    }

    func testSpecialDirsIncludesHome() {
        let dirs = VolumeService.specialDirs()
        XCTAssertGreaterThan(dirs.count, 0)
        // System display name (the user's short name for home, like Finder).
        XCTAssertEqual(dirs.first?.name, FileManager.default.displayName(atPath: NSHomeDirectory()))
        XCTAssertEqual(dirs.first?.path, NSHomeDirectory())
    }
}
