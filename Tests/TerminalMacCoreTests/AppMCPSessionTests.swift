import Foundation
import XCTest
@testable import TerminalMacCore

/// Pure host protocol admission only. No VM, TCC, mailbox, filesystem, app,
/// network, process, or session token is accessed by any test.
final class AppMCPSessionTests: XCTestCase {
    private let run = "run-" + String(repeating: "a", count: 32)
    private let manifest = String(repeating: "b", count: 64)
    private let acceptance = String(repeating: "c", count: 64)
    private let nonce = String(repeating: "d", count: 64)
    private let helper = "00000000-0000-4000-8000-000000000010"
    private let owner = "mcp:00000000-0000-4000-8000-000000000011"
    private let start = Date(timeIntervalSince1970: 2_000_000_000)

    private var selection: AppMCPSelection {
        get throws {
            try AppMCPSelection(options: ["app-run": run,
                                          "app-manifest": manifest,
                                          "app-acceptance": acceptance])
        }
    }
    private func newSession() throws -> AppMCPSession {
        try AppMCPSession(selection: selection, appName: "Fixture.app",
                          owner: owner, nonce: nonce, helperVersion: "0.2.0",
                          helperBuild: "build11", at: start)
    }
    private func operation(_ i: Int) -> String {
        String(format: "00000000-0000-4000-8000-%012d", i + 1)
    }

    private func reply(for intent: AppMCPIntent, helperInstance: String? = nil) -> [String: String] {
        let command = intent.command
        let running = command == "launch" || command == "activate"
        let afterLaunch = ["launch", "activate", "quit", "close"].contains(command)
        let exited = command == "quit" || command == "close"
        let phase: String
        switch command {
        case "open": phase = "ready"
        case "install", "quit": phase = "installed"
        case "launch", "activate": phase = "running"
        default: phase = "closed"
        }
        return [
            "serviceContract": "terminal-mac.app-service/4",
            "executor": "compiled-native-helper",
            "serverCodeSource": "helper-binary",
            "shell": "not-used", "runId": run, "nonce": nonce,
            "manifestSHA256": manifest, "acceptanceSHA256": acceptance,
            "operationId": intent.operationID, "sequence": String(intent.sequence),
            "state": phase, "pending": "", "restoredObservation": "false",
            "serviceReady": command == "close" ? "false" : "true",
            "helperInstance": helperInstance ?? helper,
            "installationRoot": "/Applications",
            "installationLocation": "guest-applications/1",
            "installedApplication": command == "open" ? "" : "/Applications/Fixture.app",
            "installationEvidence": command == "open" ? "not-installed" :
                command == "close" ? "verified-at-close" : "verified-at-install",
            "applicationPID": running ? "42" : "",
            "uiPrimaryPID": afterLaunch ? "42" : "",
            "launchRootPID": afterLaunch ? "41" : "",
            "launchRootStartIdentity": afterLaunch ? "41:1999999991:3" : "",
            "uiPrimaryStartIdentity": afterLaunch ? "42:1999999991:4" : "",
            "launchAncestry": afterLaunch ?
                "41:1999999991:3>42:1999999991:4" : "",
            "launchIdentityContract": afterLaunch ? "terminal-mac.launch-identity/1" : "",
            "launchIdentityState": afterLaunch ? "bound" : "unconfirmed",
            "launchEvidencePublication": afterLaunch ? "durable-resolution" : "not-attempted",
            "applicationRunning": running ? "true" : "false",
            "rootExit": !afterLaunch ? "no-owned-root" :
                exited ? "observed" : "not-observed",
            "uiPrimaryExit": !afterLaunch ? "unconfirmed" :
                exited ? "observed" : "not-observed",
            "foreground": command == "activate" ? "true" : "false",
            "windows": running ? "1" : "0"
        ]
    }
    private func advance(_ current: inout AppMCPSession, command: String,
                         index: Int, at delay: TimeInterval = 0) throws -> AppMCPReceipt {
        let at = start.addingTimeInterval(Double(index * 10) + delay)
        let intent = try current.prepare(command, operationID: operation(index), at: at)
        XCTAssertEqual(intent.arguments["leaseOwner"], owner)
        XCTAssertEqual(intent.arguments["serviceRun"], run)
        XCTAssertEqual(intent.arguments["serviceNonce"], nonce)
        XCTAssertEqual(intent.arguments["serviceManifest"], manifest)
        XCTAssertEqual(intent.arguments["serviceAcceptance"], acceptance)
        XCTAssertEqual(intent.arguments["serviceSequence"], String(index))
        let payload = reply(for: intent)
        let receipt = try current.accept(payload, intent: intent, at: at)
        let readUUID = operation(index + 20)
        let readArguments = try current.observeArguments(for: receipt, observationID: readUUID)
        XCTAssertEqual(readArguments["serviceCommand"], "observe")
        XCTAssertEqual(readArguments["serviceOperation"], readUUID)
        XCTAssertNotEqual(readArguments["serviceOperation"], receipt.operationID)
        let observation = try XCTUnwrap(current.admitObservation(payload, for: receipt, at: at))
        XCTAssertEqual(observation.operationID, receipt.operationID)
        XCTAssertEqual(observation.helperInstance, helper)
        return receipt
    }
    private func launchedSession() throws -> AppMCPSession {
        var s = try newSession()
        for (index, command) in ["open", "install", "launch", "activate"].enumerated() {
            _ = try advance(&s, command: command, index: index)
        }
        return s
    }

    func testCLIOptionsAreAllOrNoneAndConfigCannotHideAcceptedApplication() throws {
        XCTAssertNil(try AppMCPSelection.optional([:], config: false))
        XCTAssertNil(try AppMCPSelection.optional([:], config: true))
        let chosen = try XCTUnwrap(AppMCPSelection.optional(
            ["app-run": run, "app-manifest": manifest, "app-acceptance": acceptance],
            config: false))
        XCTAssertEqual(chosen.runID, run)
        for invalid in [
            ["app-run": run], ["app-run": run, "app-manifest": manifest],
            ["app-run": "run-invalid", "app-manifest": manifest, "app-acceptance": acceptance],
            ["app-run": run, "app-manifest": "NOT_SHA", "app-acceptance": acceptance],
            ["app-run": run, "app-manifest": manifest, "app-acceptance": acceptance,
             "app-path": "/Applications/Farol.app"],
        ] {
            XCTAssertThrowsError(try AppMCPSelection.optional(invalid, config: false))
        }
        XCTAssertThrowsError(try AppMCPSelection.optional(
            ["app-run": run, "app-manifest": manifest, "app-acceptance": acceptance],
            config: true))
    }

    func testLiveVZShareAndExactGuestCapabilitiesRequiredBeforeEffects() throws {
        let host: [String: String] = [
            "state": "running", "artifactShareReadOnly": "true",
            "artifactShareEvidence": "live-vz-configuration/1"]
        let guest: [String: String] = [
            "appServiceContract": "terminal-mac.app-service/4",
            "appServiceExecutor": "compiled-native-helper",
            "appServiceLaunchIdentityContract": "terminal-mac.launch-identity/1",
            "appServiceAdmission": "available",
            "screenRecording": "true", "accessibility": "true",
            "version": "0.2.0", "build": "build11"]
        XCTAssertNoThrow(try AppMCPAdmission.host(host))
        XCTAssertNoThrow(try AppMCPAdmission.guest(guest))
        for (key, value) in [("state", "stopped"), ("artifactShareReadOnly", "false"),
                             ("artifactShareEvidence", "offline-machine-json")] {
            XCTAssertThrowsError(try AppMCPAdmission.host(host.merging([key: value]) { _, new in new }))
        }
        for (key, value) in [("appServiceContract", "terminal-mac.app-service/2"),
                             ("appServiceAdmission", "active-or-unresolved"),
                             ("appServiceLaunchIdentityContract", "old"),
                             ("screenRecording", "false"), ("accessibility", "false")] {
            XCTAssertThrowsError(try AppMCPAdmission.guest(guest.merging([key: value]) { _, new in new }))
        }
    }

    func testSeparateExpectedStagedHashesMustMatch() throws {
        let payload = Data("synthetic app-payload".utf8)
        let accepted = Data("synthetic accepted-application".utf8)
        let right = try AppMCPSelection(options: [
            "app-run": run,
            "app-manifest": AppServiceDirectory.digest(payload),
            "app-acceptance": AppServiceDirectory.digest(accepted)])
        try AppMCPAdmission.staged(payload, accepted: accepted, selection: right)
        XCTAssertThrowsError(try AppMCPAdmission.staged(
            Data("different".utf8), accepted: accepted, selection: right))
        XCTAssertThrowsError(try AppMCPAdmission.staged(
            payload, accepted: Data("different".utf8), selection: right))
    }

    func testCompletePositiveOrderedLifecycleIncludesBoundReadonlyObservations() throws {
        var s = try launchedSession()
        XCTAssertTrue(s.isReady)
        XCTAssertFalse(s.isClosed)
        XCTAssertEqual(s.nextSequence, 4)
        XCTAssertEqual(s.helperInstance, helper)
        XCTAssertEqual(s.installedApplication, "/Applications/Fixture.app")
        try s.requireInteractiveBudget(at: start.addingTimeInterval(100))
        let quit = try advance(&s, command: "quit", index: 4)
        XCTAssertEqual(quit.rootExit, "observed")
        XCTAssertEqual(quit.primaryExit, "observed")
        XCTAssertFalse(s.isReady)
        let close = try advance(&s, command: "close", index: 5)
        XCTAssertEqual(close.installationEvidence, "verified-at-close")
        XCTAssertTrue(s.isClosed)
        XCTAssertEqual(s.nextSequence, 6)
        XCTAssertFalse(s.isUnconfirmed)
        XCTAssertThrowsError(try s.prepare("launch", operationID: operation(7),
                                           at: start.addingTimeInterval(70)))
    }

    func testOneLaunchReceiptDoesNotClaimReadyBeforeActivateObservation() throws {
        var s = try newSession()
        for (index, command) in ["open", "install", "launch"].enumerated() {
            _ = try advance(&s, command: command, index: index)
        }
        XCTAssertFalse(s.isReady)
        XCTAssertThrowsError(try s.requireInteractiveBudget(at: start.addingTimeInterval(30)))
        let intent = try s.prepare("activate", operationID: operation(3),
                                   at: start.addingTimeInterval(30))
        let ack = reply(for: intent)
        let receipt = try s.accept(ack, intent: intent, at: start.addingTimeInterval(30))
        XCTAssertFalse(s.isReady)
        let waiting = ack.merging(["foreground": "false", "windows": "0"]) { _, v in v }
        XCTAssertNil(try s.admitObservation(waiting, for: receipt, waitForGUI: true,
                                            at: start.addingTimeInterval(31)))
        XCTAssertFalse(s.isReady)
        XCTAssertThrowsError(try s.admitObservation(waiting, for: receipt,
                                                    at: start.addingTimeInterval(31)))
        _ = try XCTUnwrap(s.admitObservation(ack, for: receipt, waitForGUI: true,
                                             at: start.addingTimeInterval(32)))
        XCTAssertTrue(s.isReady)
    }

    func testWrongOperationSequenceHelperAndHashesRefuseBeforeNextEffect() throws {
        for change in [
            ["runId": "run-" + String(repeating: "f", count: 32)],
            ["nonce": String(repeating: "f", count: 64)],
            ["manifestSHA256": String(repeating: "f", count: 64)],
            ["acceptanceSHA256": String(repeating: "f", count: 64)],
            ["operationId": operation(19)],
            ["sequence": "1"],
            ["helperInstance": "invalid-instance"],
            ["state": "running"],
            ["pending": "launch"],
            ["restoredObservation": "true"],
        ] {
            var s = try newSession()
            let intent = try s.prepare("open", operationID: operation(0), at: start)
            let payload = reply(for: intent).merging(change) { _, changed in changed }
            XCTAssertThrowsError(try s.accept(payload, intent: intent, at: start))
            XCTAssertEqual(s.nextSequence, 0)
            XCTAssertTrue(s.isUnconfirmed)
            XCTAssertThrowsError(try s.prepare("install", operationID: operation(1), at: start))
        }
        var s = try newSession()
        _ = try advance(&s, command: "open", index: 0)
        let intent = try s.prepare("install", operationID: operation(1),
                                   at: start.addingTimeInterval(10))
        let conflicting = reply(for: intent, helperInstance: operation(45))
        XCTAssertThrowsError(try s.accept(conflicting, intent: intent,
                                           at: start.addingTimeInterval(10)))
    }

    func testRootAndGUIPrimaryMustBeDistinctlyBound() throws {
        for change in [
            ["applicationPID": "41"],
            ["uiPrimaryPID": "41"],
            ["launchRootPID": "0"],
            ["launchRootStartIdentity": "unconfirmed"],
            ["uiPrimaryStartIdentity": ""],
            ["launchAncestry": ""],
            ["launchIdentityState": "unknown"],
            ["launchIdentityContract": "legacy"],
            ["rootExit": "unconfirmed"],
            ["uiPrimaryExit": "observed"],
            ["launchEvidencePublication": "not-attempted"],
        ] {
            var s = try newSession()
            _ = try advance(&s, command: "open", index: 0)
            _ = try advance(&s, command: "install", index: 1)
            let intent = try s.prepare("launch", operationID: operation(2),
                                       at: start.addingTimeInterval(20))
            XCTAssertThrowsError(try s.accept(
                reply(for: intent).merging(change) { _, changed in changed },
                intent: intent, at: start.addingTimeInterval(20)))
        }
    }

    func testReadonlyObserveMustReferenceOriginalEffectAndSameHelper() throws {
        var s = try newSession()
        let intent = try s.prepare("open", operationID: operation(0), at: start)
        let ack = reply(for: intent)
        let receipt = try s.accept(ack, intent: intent, at: start)
        let arguments = try s.observeArguments(for: receipt, observationID: operation(90))
        XCTAssertEqual(arguments["serviceOperation"], operation(90))
        XCTAssertNotEqual(arguments["serviceOperation"], receipt.operationID)
        for change in [["operationId": operation(90)],
                       ["helperInstance": operation(33)],
                       ["sequence": "3"], ["restoredObservation": "true"],
                       ["installationRoot": "/Users/tester/Library/Caches"]] {
            XCTAssertThrowsError(try s.admitObservation(
                ack.merging(change) { _, changed in changed },
                for: receipt, at: start.addingTimeInterval(1)))
        }
        XCTAssertEqual(s.nextSequence, 1)
        XCTAssertNotNil(try s.admitObservation(ack, for: receipt,
                                               at: start.addingTimeInterval(1)))
    }

    func testFalseOrMalformedGUIEvidenceNeverBecomesReady() throws {
        var s = try newSession()
        for (i, command) in ["open", "install", "launch"].enumerated() {
            _ = try advance(&s, command: command, index: i)
        }
        let intent = try s.prepare("activate", operationID: operation(3),
                                   at: start.addingTimeInterval(30))
        let ack = reply(for: intent)
        let receipt = try s.accept(ack, intent: intent, at: start.addingTimeInterval(30))
        for invalid in [["foreground": "unconfirmed"], ["windows": "99"],
                        ["windows": "synthetic-secret"], ["applicationPID": "43"],
                        ["uiPrimaryStartIdentity": "42:1999999991:5"]] {
            XCTAssertThrowsError(try s.admitObservation(
                ack.merging(invalid) { _, changed in changed },
                for: receipt, waitForGUI: true, at: start.addingTimeInterval(31)))
        }
        XCTAssertFalse(s.isReady)
    }

    func testLostACKStaysPendingAndUNKNOWNBlocksMutation() throws {
        var s = try newSession()
        let intent = try s.prepare("open", operationID: operation(0), at: start)
        XCTAssertEqual(s.pending, intent)
        XCTAssertTrue(s.isUnconfirmed)
        s.markUnconfirmed()
        XCTAssertEqual(s.phase, .unknown)
        XCTAssertThrowsError(try s.prepare("open", operationID: operation(1),
                                           at: start.addingTimeInterval(1)))
        var gate = GuestSessionOutcomeGuard()
        gate.markUnconfirmed()
        XCTAssertThrowsError(try gate.requireAllowed(action: "app-service"))
        XCTAssertThrowsError(try gate.requireAllowed(action: "key"))
        XCTAssertNoThrow(try gate.requireAllowed(action: "status"))
        XCTAssertNoThrow(try gate.requireAllowed(action: "screenshot"))
    }

    func testDeadlineRequiresReservedTimeForGUIAndForbidsExpiredRestart() throws {
        var s = try launchedSession()
        XCTAssertEqual(s.secondsRemaining(at: start.addingTimeInterval(600)), 0)
        XCTAssertThrowsError(try s.requireInteractiveBudget(
            at: start.addingTimeInterval(480)))
        XCTAssertThrowsError(try s.requireInteractiveBudget(
            at: start.addingTimeInterval(601)))
        XCTAssertThrowsError(try s.prepare("quit", operationID: operation(4),
                                           at: start.addingTimeInterval(601)))
        XCTAssertNoThrow(try s.prepare("quit", operationID: operation(4),
                                       at: start.addingTimeInterval(470)))
    }

    func testNormalQuitAndCloseRequireOriginalRootAndPrimaryExits() throws {
        for change in [["rootExit": "unconfirmed"],
                       ["uiPrimaryExit": "unconfirmed"],
                       ["applicationPID": "42"],
                       ["applicationRunning": "true"],
                       ["launchRootStartIdentity": "41:1999999991:9"]] {
            var s = try launchedSession()
            let intent = try s.prepare("quit", operationID: operation(4),
                                       at: start.addingTimeInterval(40))
            let response = reply(for: intent).merging(change) { _, changed in changed }
            XCTAssertThrowsError(try s.accept(response, intent: intent,
                                               at: start.addingTimeInterval(40)))
            XCTAssertFalse(s.isClosed)
        }
        var s = try launchedSession()
        _ = try advance(&s, command: "quit", index: 4)
        let intent = try s.prepare("close", operationID: operation(5),
                                   at: start.addingTimeInterval(50))
        let changed = reply(for: intent).merging(
            ["installationEvidence": "verified-at-install"]) { _, value in value }
        XCTAssertThrowsError(try s.accept(changed, intent: intent,
                                           at: start.addingTimeInterval(50)))
        XCTAssertFalse(s.isClosed)
    }
}
