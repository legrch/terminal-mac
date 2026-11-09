import Foundation
import Darwin
import XCTest
@testable import TerminalMacCore

/// Regression for a free flock with retained machine metadata or helper-update marker.
/// Every fixture is disposable, synthetic, and has no virtual machine or live helper.
final class InputLeaseOrphanCustodyTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orphan-custody-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func predecessorMetadata(_ directory: URL) throws -> Data {
        let data = Data(#"{"schema":"terminal-mac.input-lease/1","owner":"predecessor","generation":9,"acquiredAt":100}"#.utf8)
        try data.write(to: directory.appendingPathComponent(InputLease.metadataName))
        return data
    }

    private func predecessorMarker(_ directory: URL) throws -> Data {
        let box = try Mailbox(directory.appendingPathComponent("exchange"), create: true)
        try box.publishLeaseFlag(owner: "predecessor", ttl: 120, now: Date(timeIntervalSince1970: 1000))
        return try Data(contentsOf: directory.appendingPathComponent("exchange/" + Mailbox.leaseFlagName))
    }

    private func assertInputRefused(_ directory: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let state = try InputLease.probe(directory: directory)
        XCTAssertNotEqual(state, .free, "free kernel flock does not clear predecessor evidence", file: file, line: line)
        XCTAssertEqual(String(describing: state), "unresolved", "not a live holder or FREE", file: file, line: line)
        XCTAssertNotEqual(InputLease.admission(probe: state, claimedOwner: nil), .allowed, file: file, line: line)
        XCTAssertNotEqual(InputLease.admission(probe: state, claimedOwner: "predecessor"), .allowed, file: file, line: line)
        XCTAssertNotEqual(InputLease.admission(probe: state, claimedOwner: "unknown"), .allowed, file: file, line: line)
        XCTAssertNotNil(InputLease.nativeWindowDenial(probe: state, windowOwner: nil), file: file, line: line)
        XCTAssertNotNil(InputLease.nativeWindowDenial(probe: state, windowOwner: "predecessor"), file: file, line: line)
    }

    func testFreeKernelLockWithBothOrphanFilesDeniesAllAdmissionsAndPreservesBytes() throws {
        let directory = try temporary()
        let metadata = try predecessorMetadata(directory)
        let marker = try predecessorMarker(directory)
        try assertInputRefused(directory)
        XCTAssertThrowsError(try InputLease.acquire(directory: directory, owner: "new-client", generation: 10))
        try assertInputRefused(directory)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(InputLease.metadataName)), metadata)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("exchange/" + Mailbox.leaseFlagName)), marker)
    }

    func testFreeKernelLockWithEitherOrphanRecordDeniesInput() throws {
        for kind in ["metadata", "marker"] {
            let directory = try temporary()
            if kind == "metadata" { _ = try predecessorMetadata(directory) }
            else { _ = try predecessorMarker(directory) }
            try assertInputRefused(directory)
        }
    }

    func testExpiredAndMalformedMarkersRemainUnresolved() throws {
        for kind in ["expired", "malformed", "dangling-symlink", "hardlink", "fifo", "directory"] {
            let directory = try temporary()
            let exchange = directory.appendingPathComponent("exchange")
            let box = try Mailbox(exchange, create: true)
            let marker = exchange.appendingPathComponent(Mailbox.leaseFlagName)
            let target = exchange.appendingPathComponent("synthetic-sentinel")
            switch kind {
            case "expired": try box.publishLeaseFlag(owner: "predecessor", ttl: 1, now: Date(timeIntervalSince1970: 1000))
            case "malformed": try Data("{bad".utf8).write(to: marker)
            case "dangling-symlink": try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: target)
            case "hardlink":
                try Data("synthetic".utf8).write(to: target)
                try FileManager.default.linkItem(at: target, to: marker)
            case "fifo": XCTAssertEqual(mkfifo(marker.path, 0o600), 0)
            case "directory": try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: false)
            default: XCTFail("invalid fixture")
            }
            try assertInputRefused(directory)
            if kind == "hardlink" { XCTAssertEqual(try Data(contentsOf: target), Data("synthetic".utf8)) }
        }
    }

    func testEveryUnsafeMachineMetadataEntryDeniesEvenWithoutMarker() throws {
        for kind in ["valid", "malformed", "dangling-symlink", "hardlink", "fifo", "directory"] {
            let directory = try temporary()
            let metadata = directory.appendingPathComponent(InputLease.metadataName)
            let target = directory.appendingPathComponent("synthetic-sentinel")
            switch kind {
            case "valid": _ = try predecessorMetadata(directory)
            case "malformed": try Data("{bad".utf8).write(to: metadata)
            case "dangling-symlink": try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: target)
            case "hardlink":
                try Data("synthetic".utf8).write(to: target)
                try FileManager.default.linkItem(at: target, to: metadata)
            case "fifo": XCTAssertEqual(mkfifo(metadata.path, 0o600), 0)
            case "directory": try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
            default: XCTFail("invalid fixture")
            }
            try assertInputRefused(directory)
            if kind == "hardlink" { XCTAssertEqual(try Data(contentsOf: target), Data("synthetic".utf8)) }
        }
    }

    func testUnsafeExchangeOrMissingExchangeAreDistinctFromAValidEmptyExchange() throws {
        let newMachine = try temporary()
        XCTAssertEqual(try InputLease.probe(directory: newMachine), .free, "no exchange is normal before bootstrap")
        XCTAssertFalse(FileManager.default.fileExists(atPath: newMachine.appendingPathComponent("exchange").path),
                       "a read-only probe must not construct guest exchange")
        _ = try Mailbox(newMachine.appendingPathComponent("exchange"), create: true)
        XCTAssertEqual(try InputLease.probe(directory: newMachine), .free, "empty safe exchange has no marker")
        for kind in ["dangling-symlink", "fifo", "ordinary-file"] {
            let directory = try temporary()
            let exchange = directory.appendingPathComponent("exchange")
            switch kind {
            case "dangling-symlink": try FileManager.default.createSymbolicLink(at: exchange, withDestinationURL: directory.appendingPathComponent("missing"))
            case "fifo": XCTAssertEqual(mkfifo(exchange.path, 0o600), 0)
            case "ordinary-file": try Data().write(to: exchange)
            default: XCTFail("invalid fixture")
            }
            try assertInputRefused(directory)
        }
    }

    func testStoppedStoreCloneAndRenameRefuseWithoutMutatingMachineState() throws {
        let root = try temporary()
        let store = Store(root: root)
        let machine = try store.directory("synthetic")
        try FileManager.default.createDirectory(at: machine, withIntermediateDirectories: true)
        try store.save(Machine(name: "synthetic", cpu: 4, memoryGiB: 4, diskGiB: 64, installed: true))
        let previous = try predecessorMarker(machine)
        let priorMetadata = try predecessorMetadata(machine)
        let machineBytes = try Data(contentsOf: machine.appendingPathComponent("machine.json"))
        XCTAssertThrowsError(try store.rename("synthetic", to: "renamed"))
        XCTAssertThrowsError(try store.clone(from: "synthetic", to: "clone", identityData: Data("synthetic-new-id".utf8), offline: true))
        XCTAssertEqual(try Data(contentsOf: machine.appendingPathComponent("machine.json")), machineBytes)
        XCTAssertEqual(try Data(contentsOf: machine.appendingPathComponent(InputLease.metadataName)), priorMetadata)
        XCTAssertEqual(try Data(contentsOf: machine.appendingPathComponent("exchange/" + Mailbox.leaseFlagName)), previous)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("machines/renamed").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("machines/clone").path))
        try assertInputRefused(machine)
    }

    func testCleanFreeAndLiveCooperativeOwnerRemainSupported() throws {
        let directory = try temporary()
        XCTAssertEqual(try InputLease.probe(directory: directory), .free)
        XCTAssertEqual(InputLease.admission(probe: try InputLease.probe(directory: directory), claimedOwner: nil), .allowed)
        let lease = try InputLease.acquire(directory: directory, owner: "live-owner", generation: 18)
        let state = try InputLease.probe(directory: directory)
        XCTAssertEqual(state, .held(owner: "live-owner", generation: 18))
        XCTAssertEqual(InputLease.admission(probe: state, claimedOwner: "live-owner"), .allowed)
        XCTAssertEqual(InputLease.admission(probe: state, claimedOwner: "foreign"), .locked(owner: "live-owner"))
        XCTAssertNil(InputLease.nativeWindowDenial(probe: state, windowOwner: "live-owner"))
        lease.release()
        XCTAssertEqual(try InputLease.probe(directory: directory), .free)
    }
}
