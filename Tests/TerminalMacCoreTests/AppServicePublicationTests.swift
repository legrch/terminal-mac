import XCTest
import Foundation
@testable import TerminalMacCore

final class AppServicePublicationTests: XCTestCase {
    func testAtomicPublicationNeverOverwritesInstalledApplication() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
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
}
