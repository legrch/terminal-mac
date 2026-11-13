import Foundation

/// An optional, finite MCP launch. No app pathname, executable, arguments or
/// environment enters this selection; the accepted app comes from staged bytes.
public struct AppMCPSelection: Equatable {
    public let runID: String
    public let manifestSHA256: String
    public let acceptanceSHA256: String

    public init(options: [String: String]) throws {
        guard Set(options.keys) == ["app-run", "app-manifest", "app-acceptance"],
              let run = options["app-run"], AppServiceContract.run(run),
              let manifest = options["app-manifest"], AppServiceContract.hex(manifest, count: 64),
              let acceptance = options["app-acceptance"], AppServiceContract.hex(acceptance, count: 64) else {
            throw Failure("MCP app bootstrap requires --app-run, --app-manifest and --app-acceptance together")
        }
        runID = run
        manifestSHA256 = manifest
        acceptanceSHA256 = acceptance
    }

    /// Empty options preserve the legacy generic MCP server exactly.
    public static func optional(_ options: [String: String], config: Bool) throws -> AppMCPSelection? {
        guard !options.isEmpty else { return nil }
        guard !config else { throw Failure("MCP --config cannot contain app bootstrap options") }
        return try AppMCPSelection(options: options)
    }
}

public enum AppMCPPhase: String, Codable {
    case idle, ready, installed, launched, active, quitting, closed, unknown
}

public struct AppMCPIntent: Codable, Equatable {
    public let schema: String
    public let runID: String
    public let nonce: String
    public let owner: String
    public let manifestSHA256: String
    public let acceptanceSHA256: String
    public let command: String
    public let sequence: Int
    public let operationID: String

    public var arguments: [String: String] {
        ["serviceCommand": command, "serviceRun": runID, "serviceNonce": nonce,
         "serviceOperation": operationID, "serviceSequence": String(sequence),
         "serviceManifest": manifestSHA256, "serviceAcceptance": acceptanceSHA256,
         "leaseOwner": owner]
    }
}

/// Content-free, run-local readback; never contains nonce or arbitrary guest
/// output. The original effect ID is the retained reference for observation.
public struct AppMCPReceipt: Codable, Equatable {
    public let schema: String
    public let command: String
    public let sequence: Int
    public let operationID: String
    public let helperInstance: String
    public let phase: String
    public let applicationPID: String
    public let launchRootPID: String
    public let rootStartIdentity: String
    public let primaryStartIdentity: String
    public let installedApplication: String
    public let installationEvidence: String
    public let rootExit: String
    public let primaryExit: String
}

public struct AppMCPObservation: Codable, Equatable {
    public let schema: String
    public let operationID: String
    public let sequence: Int
    public let phase: String
    public let helperInstance: String
    public let applicationPID: String
    public let launchRootPID: String
    public let foreground: String
    public let windows: String
    public let rootExit: String
    public let primaryExit: String
    public let installationEvidence: String
}

public enum AppMCPAdmission {
    public static let contract = "terminal-mac.mcp-app-session/1"
    public static let budget: TimeInterval = AppServiceContract.lifetime
    public static let shutdownReserve: TimeInterval = 120

    public static func host(_ values: [String: String]) throws {
        guard values["state"] == "running",
              values["artifactShareReadOnly"] == "true",
              values["artifactShareEvidence"] == "live-vz-configuration/1" else {
            throw Failure("MCP app bootstrap requires a live read-only VZ artifact share")
        }
    }

    public static func guest(_ values: [String: String]) throws {
        guard values["appServiceContract"] == AppServiceContract.version,
              values["appServiceContract"] == "terminal-mac.app-service/4",
              values["appServiceExecutor"] == "compiled-native-helper",
              values["appServiceLaunchIdentityContract"] == AppLaunchIdentity.contract,
              values["appServiceAdmission"] == "available",
              values["accessibility"] == "true", values["screenRecording"] == "true",
              let version = values["version"], !version.isEmpty, version.utf8.count <= 48,
              let build = values["build"], !build.isEmpty, build.utf8.count <= 96 else {
            throw Failure("Guest app-service/4, launch identity, permissions or admission unavailable")
        }
    }

    public static func staged(_ payload: Data, accepted: Data,
                              selection: AppMCPSelection) throws {
        guard AppServiceDirectory.digest(payload) == selection.manifestSHA256,
              AppServiceDirectory.digest(accepted) == selection.acceptanceSHA256 else {
            throw Failure("MCP app staged acceptance or manifest changed")
        }
    }

    public static func positivePID(_ value: String?) -> Bool {
        guard let raw = value, let pid = Int32(raw), pid > 0, String(pid) == raw else { return false }
        return true
    }

    public static func boundAncestry(_ value: String?) -> Bool {
        guard let value, value.utf8.count <= 4096 else { return false }
        let parts = value.split(separator: ">", omittingEmptySubsequences: false)
        return (1...32).contains(parts.count) && parts.allSatisfy {
            let fields = $0.split(separator: ":")
            guard fields.count == 3 else { return false }
            return fields.allSatisfy { part in
                !part.isEmpty && part.utf8.count <= 20 &&
                part.utf8.allSatisfy { (48...57).contains($0) }
            }
        }
    }

    public static func boundToken(_ value: String?) -> Bool {
        guard let value, value.utf8.count <= 96 else { return false }
        let fields = value.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 3, positivePID(String(fields[0])),
              let seconds = UInt64(fields[1]), seconds > 0,
              String(seconds) == fields[1], let micros = UInt32(fields[2]),
              micros < 1_000_000, String(micros) == fields[2] else { return false }
        return true
    }
}

/// Strict one-session, one-helper admission. All transitions are pure; callers
/// durably publish intents before sending the one native action.
public struct AppMCPSession {
    public let selection: AppMCPSelection
    public let appName: String
    public let owner: String
    public let nonce: String
    public let helperVersion: String
    public let helperBuild: String
    public let expiresAt: Date

    public private(set) var phase: AppMCPPhase = .idle
    public private(set) var nextSequence = 0
    public private(set) var helperInstance: String?
    public private(set) var pending: AppMCPIntent?
    public private(set) var lastReceipt: AppMCPReceipt?
    public private(set) var readyObserved = false
    private var primaryPID: String?
    private var rootPID: String?
    private var rootStart: String?
    private var primaryStart: String?

    public init(selection: AppMCPSelection, appName: String, owner: String, nonce: String,
                helperVersion: String, helperBuild: String, at start: Date = Date()) throws {
        guard AppServiceContract.path(appName), !appName.contains("/"),
              appName.hasSuffix(".app"), !appName.hasPrefix("."),
              AppServiceContract.owner(owner),
              AppServiceContract.hex(nonce, count: 64),
              !helperVersion.isEmpty, helperVersion.utf8.count <= 48,
              !helperBuild.isEmpty, helperBuild.utf8.count <= 96,
              start.timeIntervalSince1970.isFinite else {
            throw Failure("MCP app-session identity invalid")
        }
        self.selection = selection; self.appName = appName; self.owner = owner
        self.nonce = nonce; self.helperVersion = helperVersion; self.helperBuild = helperBuild
        expiresAt = start.addingTimeInterval(AppMCPAdmission.budget)
    }

    public var isClosed: Bool { phase == .closed && pending == nil }
    public var isUnconfirmed: Bool { phase == .unknown || pending != nil }
    public var isReady: Bool { phase == .active && readyObserved && pending == nil }
    public var installedApplication: String {
        AppServiceContract.installationRoot + "/" + appName
    }

    public func secondsRemaining(at now: Date = Date()) -> Int {
        max(0, Int(expiresAt.timeIntervalSince(now).rounded(.down)))
    }

    /// No new agent mutation can consume the reserved graceful-quit budget.
    /// An expired session is NEVER renewed by refreshing a mailbox marker.
    public func requireInteractiveBudget(at now: Date = Date()) throws {
        guard isReady, !isUnconfirmed, expiresAt.timeIntervalSince(now) > AppMCPAdmission.shutdownReserve else {
            throw Failure("MCP app session is not ready or has insufficient time for graceful Quit")
        }
    }

    public mutating func markUnconfirmed() {
        phase = .unknown
        readyObserved = false
    }

    private func expectation(_ command: String) -> (AppMCPPhase, AppMCPPhase, Int)? {
        switch command {
        case "open": return (.idle, .ready, 0)
        case "install": return (.ready, .installed, 1)
        case "launch": return (.installed, .launched, 2)
        case "activate": return (.launched, .active, 3)
        case "quit": return (.active, .quitting, 4)
        case "close": return (.quitting, .closed, 5)
        default: return nil
        }
    }

    public mutating func prepare(_ command: String, operationID: String, at now: Date = Date()) throws -> AppMCPIntent {
        guard let (from, _, sequence) = expectation(command), phase == from,
              pending == nil, nextSequence == sequence,
              AppServiceContract.operation(operationID),
              now < expiresAt,
              (command == "quit" || command == "close" ||
               expiresAt.timeIntervalSince(now) > AppMCPAdmission.shutdownReserve) else {
            throw Failure("MCP app-session command, deadline or operation refused")
        }
        let intent = AppMCPIntent(schema: AppMCPAdmission.contract, runID: selection.runID,
                                nonce: nonce, owner: owner,
                                manifestSHA256: selection.manifestSHA256,
                                acceptanceSHA256: selection.acceptanceSHA256,
                                command: command, sequence: sequence, operationID: operationID)
        pending = intent
        return intent
    }

    /// A successful mailbox ACK is not readiness. It commits only one phase.
    public mutating func accept(_ values: [String: String], intent: AppMCPIntent,
                                at now: Date = Date()) throws -> AppMCPReceipt {
        guard now < expiresAt, pending == intent,
              let (from, target, sequence) = expectation(intent.command),
              phase == from, nextSequence == sequence,
              values["serviceContract"] == "terminal-mac.app-service/4",
              values["executor"] == "compiled-native-helper",
              values["serverCodeSource"] == "helper-binary",
              values["shell"] == "not-used",
              values["runId"] == selection.runID, values["nonce"] == nonce,
              values["manifestSHA256"] == selection.manifestSHA256,
              values["acceptanceSHA256"] == selection.acceptanceSHA256,
              values["operationId"] == intent.operationID,
              values["sequence"] == String(sequence),
              values["state"] == guestPhase(intent.command),
              values["pending"] == "",
              values["restoredObservation"] == "false",
              values["serviceReady"] == (intent.command == "close" ? "false" : "true"),
              values["installationRoot"] == AppServiceContract.installationRoot,
              values["installationLocation"] == AppServiceContract.installationLocation,
              let actualHelper = values["helperInstance"],
              AppServiceContract.operation(actualHelper),
              helperInstance == nil || actualHelper == helperInstance else {
            throw Failure("MCP app-service ACK binding or phase invalid")
        }
        let installed = intent.command == "open" ? "" : installedApplication
        let verification = intent.command == "open" ? "not-installed" :
            intent.command == "close" ? "verified-at-close" : "verified-at-install"
        guard values["installedApplication"] == installed,
              values["installationEvidence"] == verification else {
            throw Failure("MCP app installation identity unconfirmed")
        }
        let pid = values["applicationPID"] ?? ""
        let root = values["launchRootPID"] ?? ""
        let rootIdentity = values["launchRootStartIdentity"] ?? ""
        let primaryIdentity = values["uiPrimaryStartIdentity"] ?? ""
        let rootExit = values["rootExit"] ?? "unconfirmed"
        let primaryExit = values["uiPrimaryExit"] ?? "unconfirmed"
        let running = intent.command == "launch" || intent.command == "activate"
        if running {
            guard AppMCPAdmission.positivePID(pid),
                  AppMCPAdmission.positivePID(root),
                  values["uiPrimaryPID"] == pid,
                  values["launchIdentityContract"] == AppLaunchIdentity.contract,
                  values["launchIdentityState"] == "bound",
                  values["launchEvidencePublication"]?.hasPrefix("durable-") == true,
                  AppMCPAdmission.boundToken(rootIdentity),
                  AppMCPAdmission.boundToken(primaryIdentity),
                  rootIdentity.split(separator: ":").first.map(String.init) == root,
                  primaryIdentity.split(separator: ":").first.map(String.init) == pid,
                  AppMCPAdmission.boundAncestry(values["launchAncestry"]),
                  values["applicationRunning"] == "true",
                  rootExit == "not-observed", primaryExit == "not-observed",
                  primaryPID == nil || primaryPID == pid,
                  rootPID == nil || rootPID == root,
                  rootStart == nil || rootStart == rootIdentity,
                  primaryStart == nil || primaryStart == primaryIdentity else {
                throw Failure("MCP app launch-root or GUI primary identity unconfirmed")
            }
        } else if intent.command == "open" || intent.command == "install" {
            guard pid.isEmpty, values["applicationRunning"] == "false",
                  rootExit == "no-owned-root" else {
                throw Failure("MCP app before-launch state unconfirmed")
            }
        } else {
            guard pid.isEmpty, values["applicationRunning"] == "false",
                  rootExit == "observed", primaryExit == "observed",
                  root == rootPID, rootIdentity == rootStart,
                  primaryIdentity == primaryStart,
                  values["uiPrimaryPID"] == primaryPID,
                  values["launchIdentityState"] == "bound" else {
                throw Failure("MCP app original root/primary exit unconfirmed")
            }
        }
        let receipt = AppMCPReceipt(schema: AppMCPAdmission.contract,
                                   command: intent.command, sequence: sequence,
                                   operationID: intent.operationID, helperInstance: actualHelper,
                                   phase: values["state"]!, applicationPID: pid,
                                   launchRootPID: root, rootStartIdentity: rootIdentity,
                                   primaryStartIdentity: primaryIdentity,
                                   installedApplication: installed,
                                   installationEvidence: verification, rootExit: rootExit,
                                   primaryExit: primaryExit)
        helperInstance = actualHelper
        if running { primaryPID = pid; rootPID = root
            rootStart = rootIdentity; primaryStart = primaryIdentity }
        phase = target
        nextSequence += 1
        pending = nil
        lastReceipt = receipt
        return receipt
    }

    private func guestPhase(_ command: String) -> String {
        switch command {
        case "open": return "ready"
        case "install", "quit": return "installed"
        case "launch", "activate": return "running"
        default: return "closed"
        }
    }

    public func observeArguments(for receipt: AppMCPReceipt, observationID: String) throws -> [String: String] {
        guard lastReceipt == receipt, pending == nil,
              AppServiceContract.operation(observationID),
              observationID != receipt.operationID else {
            throw Failure("MCP app observation identity invalid")
        }
        return ["serviceCommand": "observe", "serviceRun": selection.runID,
                "serviceNonce": nonce, "serviceOperation": observationID,
                "serviceSequence": String(receipt.sequence),
                "serviceManifest": selection.manifestSHA256,
                "serviceAcceptance": selection.acceptanceSHA256,
                "leaseOwner": owner]
    }

    /// Readonly reply uses the ORIGINAL effect ID, never the read request UUID.
    public mutating func admitObservation(_ values: [String: String], for receipt: AppMCPReceipt,
                                          waitForGUI: Bool = false,
                                          at now: Date = Date()) throws -> AppMCPObservation? {
        guard now < expiresAt, pending == nil, lastReceipt == receipt,
              values["operationId"] == receipt.operationID,
              values["sequence"] == String(receipt.sequence),
              values["runId"] == selection.runID, values["nonce"] == nonce,
              values["manifestSHA256"] == selection.manifestSHA256,
              values["acceptanceSHA256"] == selection.acceptanceSHA256,
              values["helperInstance"] == receipt.helperInstance,
              values["serviceContract"] == "terminal-mac.app-service/4",
              values["executor"] == "compiled-native-helper",
              values["serverCodeSource"] == "helper-binary",
              values["shell"] == "not-used",
              values["state"] == receipt.phase,
              values["pending"] == "",
              values["restoredObservation"] == "false",
              values["installationRoot"] == AppServiceContract.installationRoot,
              values["installationLocation"] == AppServiceContract.installationLocation,
              values["installedApplication"] == receipt.installedApplication,
              values["installationEvidence"] == receipt.installationEvidence,
              (values["launchRootPID"] ?? "") == receipt.launchRootPID,
              values["rootExit"] == receipt.rootExit,
              (values["uiPrimaryExit"] ?? "unconfirmed") == receipt.primaryExit else {
            throw Failure("MCP app readonly observation binding changed")
        }
        let ready = receipt.command == "activate"
        let windows = values["windows"] ?? "unconfirmed"
        let foreground = values["foreground"] ?? "unconfirmed"
        if receipt.command == "launch" || ready {
            guard values["applicationPID"] == receipt.applicationPID,
                  values["uiPrimaryPID"] == receipt.applicationPID,
                  values["launchIdentityState"] == "bound",
                  values["launchIdentityContract"] == AppLaunchIdentity.contract,
                  values["launchRootStartIdentity"] == receipt.rootStartIdentity,
                  values["uiPrimaryStartIdentity"] == receipt.primaryStartIdentity,
                  values["applicationRunning"] == "true",
                  values["launchEvidencePublication"]?.hasPrefix("durable-") == true else {
                throw Failure("MCP app primary identity changed during observation")
            }
            if ready {
                // A LaunchServices activation ACK can precede the AX window.
                // Only a fully bound explicit false/zero/unconfirmed UI result
                // is waitable; malformed values or changed identity refuse.
                let count = Int(windows)
                let positive = foreground == "true" && count != nil &&
                    String(count!) == windows && (1...64).contains(count!)
                if !positive {
                    guard waitForGUI, ["true", "false"].contains(foreground),
                          windows == "unconfirmed" || windows == "0" ||
                          (count != nil && String(count!) == windows &&
                           (0...64).contains(count!)) else {
                        throw Failure("MCP app GUI primary not foreground with confirmed AX window")
                    }
                    return nil
                }
            }
        } else if receipt.command == "quit" || receipt.command == "close" {
            guard values["applicationRunning"] == "false",
                  values["applicationPID"] == "",
                  values["rootExit"] == "observed",
                  values["uiPrimaryExit"] == "observed",
                  values["launchRootStartIdentity"] == receipt.rootStartIdentity,
                  values["uiPrimaryStartIdentity"] == receipt.primaryStartIdentity else {
                throw Failure("MCP app original process exit observation missing")
            }
        } else {
            guard values["applicationPID"] == "",
                  values["applicationRunning"] == "false" else {
                throw Failure("MCP app pre-launch observation invalid")
            }
        }
        if ready { readyObserved = true }
        return AppMCPObservation(schema: AppMCPAdmission.contract,
                                 operationID: receipt.operationID,
                                 sequence: receipt.sequence,
                                 phase: receipt.phase,
                                 helperInstance: receipt.helperInstance,
                                 applicationPID: receipt.applicationPID,
                                 launchRootPID: receipt.launchRootPID,
                                 foreground: foreground, windows: windows,
                                 rootExit: receipt.rootExit,
                                 primaryExit: receipt.primaryExit,
                                 installationEvidence: receipt.installationEvidence)
    }
}
