import Darwin
import XCTest
import Foundation
@testable import TerminalMacCore

final class AppServicePublicationTests: XCTestCase {
    func testAtomicPublicationNeverOverwritesInstalledApplication() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("native-publication-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try AppServiceDirectory.open(root)
        let stage = try directory.child("stage", create: true, exclusive: true)
        _ = try stage.child("Fixture.app", create: true, exclusive: true)
        let prior = try directory.child("Fixture.app", create: true, exclusive: true)
        try prior.write(Data("prior".utf8), named: "marker", createOnly: true)
        XCTAssertThrowsError(try directory.publishDirectory(from: stage, named: "Fixture.app", as: "Fixture.app"))
        XCTAssertEqual(try prior.read("marker", limit: 32), Data("prior".utf8))
        XCTAssertNoThrow(try stage.child("Fixture.app"))
        try directory.publishDirectory(from: stage, named: "Fixture.app", as: "Other.app")
        XCTAssertNoThrow(try directory.child("Other.app"))
        XCTAssertThrowsError(try stage.child("Fixture.app"))
    }
    func testEvidenceRootParentSyncFailurePreventsLifecycleDispatch() throws {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("service")
        var dispatched = false, calls = 0
        for _ in 0..<2 {
            XCTAssertThrowsError(try {
                _ = try AppServiceDirectory.open(root, createLeaf: true, syncParent: { fd in
                    calls += 1
                    var info = stat(), expected = stat()
                    XCTAssertEqual(fstat(fd, &info), 0)
                    XCTAssertEqual(stat(parent.path, &expected), 0)
                    XCTAssertEqual(info.st_ino, expected.st_ino)
                    errno = EIO
                    return -1
                })
                dispatched = true
            }())
        }
        XCTAssertFalse(dispatched)
        XCTAssertEqual(calls, 2, "An existing leaf from an uncertain mkdir also needs parent sync")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

}
