import AppKit
import Virtualization
import TerminalMacCore
import Darwin

@MainActor
final class CLI {
    let store = Store()
    var runtime: MachineRuntime?
    var guest: GuestRuntime?
    var executableURL: URL {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .standardizedFileURL.resolvingSymlinksInPath()
    }
    var toolsURL: URL {
        executableURL
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/guest-tools")
    }
    func run(_ input: [String], quietStartup: Bool = false) async throws {
        let command = input.first ?? (Bundle.main.bundleIdentifier == "dev.terminal-mac.guest" ? "guest" : (isatty(STDIN_FILENO) == 1 ? "up" : "help"))
        let tail = Array(input.dropFirst())
        switch command {
        case "help", "--help", "-h": print(Self.help)
        case "--version", "version": print("terminal-mac \(appVersion)")
        case "up", "setup": try await up(tail)
        case "doctor":
            _ = try Arguments(tail)
            try printJSON(["architecture": "arm64", "virtualizationSupported": String(VZVirtualMachine.isSupported),
                           "macOS": ProcessInfo.processInfo.operatingSystemVersionString, "dataDirectory": store.root.path,
                           "guestToolsBundled": String(FileManager.default.fileExists(atPath: toolsURL.appendingPathComponent("TerminalMacGuest.app").path))])
        case "image":
            let args = try Arguments(tail, options: ["output"])
            guard args.positionals.isEmpty else { throw Failure("Usage: terminal-mac image [--output /path/to/restore.ipsw]") }
            let image = try await VZMacOSRestoreImage.latestSupported
            guard let output = args.options["output"] else {
                try printJSON(["url": image.url.absoluteString, "build": image.buildVersion, "version": "\(image.operatingSystemVersion.majorVersion).\(image.operatingSystemVersion.minorVersion).\(image.operatingSystemVersion.patchVersion)"])
                return
            }
            let destination = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw Failure("Output already exists; it will not be overwritten") }
            stderr("Downloading macOS from Apple. Restore images are several gigabytes; this may take a while…")
            let (temporary, response) = try await URLSession.shared.download(from: image.url)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("Apple restore-image download failed") }
            try FileManager.default.moveItem(at: temporary, to: destination)
            print(destination.path)
        case "create":
            let args = try Arguments(tail, flags: ["offline", "standard"], options: ["ipsw", "cpus", "memory", "disk", "width", "height"])
            try await VirtualMachines.create(args, store: store)
        case "ls", "list":
            _ = try Arguments(tail)
            let directory = store.root.appendingPathComponent("machines")
            let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            let machines = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { try? store.load($0.lastPathComponent) }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(machines), as: UTF8.self))
        case "start":
            let args = try Arguments(tail, flags: ["window"])
            let name = try args.machineName()
            let machine = try store.load(name)
            guard machine.installed else { throw Failure("Installation did not complete. See the VM directory and README recovery instructions.") }
            let directory = try store.directory(name)
            if try runtimeIsLocked(directory) {
                if args.flags.contains("window") { _ = try await host(name, action: "show") }
                if !quietStartup { try printJSON(["name": name, "state": "already-running"]) }; return
            }
            guard FileManager.default.fileExists(atPath: toolsURL.appendingPathComponent("TerminalMacGuest.app").path) else { throw Failure("Guest tools are missing. Run scripts/build.sh and use dist/terminal-mac.") }
            let log = directory.appendingPathComponent("runtime.log")
            if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            let logHandle = try FileHandle(forWritingTo: log)
            try logHandle.seekToEnd()
            defer { try? logHandle.close() }
            let process = Process()
            process.executableURL = executableURL
            process.arguments = ["__run", name] + (args.flags.contains("window") ? ["--window"] : [])
            var environment = ProcessInfo.processInfo.environment; environment["TERMINAL_MAC_HOME"] = store.root.path
            process.environment = environment
            process.standardOutput = logHandle; process.standardError = logHandle; process.standardInput = FileHandle.nullDevice
            try process.run()
            // A host mailbox responds only after VZ has booted successfully.
            _ = try Mailbox(directory.appendingPathComponent("host-control"), create: true)
            do {
                let reply = try await host(name, action: "status", timeout: 30)
                if !quietStartup { try printJSON(reply.values) }
            } catch {
                throw Failure("VM did not become ready: \(error.localizedDescription). Details: \(log.path)")
            }
        case "__run":
            let args = try Arguments(tail, flags: ["window"])
            let name = try args.machineName()
            let machine = try store.load(name)
            guard machine.installed else { throw Failure("VM installation is incomplete") }
            runtime = try MachineRuntime(machine: machine, directory: store.directory(name), tools: toolsURL)
            try await runtime!.start(show: args.flags.contains("window"))
            // Keep the app event loop and runtime alive until guest shutdown.
            while true { try await Task.sleep(nanoseconds: 1_000_000_000) }
        case "status", "show", "hide", "pause", "resume", "stop":
            let args = try Arguments(tail, flags: command == "stop" ? ["force"] : [], options: ["owner"])
            let name = try args.machineName()
            _ = try store.load(name)
            if command == "status", !(try runtimeIsLocked(store.directory(name))) {
                try printJSON(["name": name, "state": "stopped"]); return
            }
            var lifecycle = ["force": String(args.flags.contains("force"))]
            // The lease holder that deliberately shows the login window stays interactive in it.
            if let owner = args.options["owner"] { lifecycle["leaseOwner"] = owner }
            let reply = try await host(name, action: command, arguments: lifecycle)
            try printJSON(reply.values)
        case "lease":
            let args = try Arguments(tail)
            guard args.positionals.count == 2, args.positionals[1] == "status" else {
                throw Failure("Usage: terminal-mac lease NAME status. Acquisition is programmatic: long-running clients flock <machine>/input-lease.lock; `action --owner NAME` drives the guest under that lease.")
            }
            let name = args.positionals[0]
            try validateName(name)
            let directory = try store.directory(name)
            _ = try store.load(name)
            let state = try InputLease.probe(directory: directory)
            let response: [String: Any]
            switch state {
            case .free: response = ["held": false, "owner": NSNull()]
            case .held(let owner, _): response = ["held": true, "owner": owner]
            case .heldUnknown: response = ["held": true, "owner": NSNull(), "state": "holder-unknown"]
            case .unresolved:
                // The kernel lock is free but persistent evidence forbids new input.
                // Preserve held's kernel-lock meaning; consumers must inspect state.
                response = ["held": false, "owner": NSNull(), "state": "unresolved-predecessor",
                            "inputAllowed": false]
            }
            let status = try JSONSerialization.data(withJSONObject: response,
                                                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            print(String(decoding: status, as: UTF8.self))
        case "rename":
            let args = try Arguments(tail)
            guard args.positionals.count == 2 else { throw Failure("Usage: terminal-mac rename OLD NEW") }
            try store.rename(args.positionals[0], to: args.positionals[1])
            try printJSON(["from": args.positionals[0], "to": args.positionals[1], "state": "RENAMED"])
        case "clone":
            let args = try Arguments(tail, flags: ["offline"])
            guard args.positionals.count == 2 else { throw Failure("Usage: terminal-mac clone OLD NEW [--offline]") }
            let identity = VZMacMachineIdentifier().dataRepresentation
            try store.clone(from: args.positionals[0], to: args.positionals[1], identityData: identity,
                            offline: args.flags.contains("offline"))
            try printJSON(["from": args.positionals[0], "to": args.positionals[1], "state": "CLONED"])
        case "display":
            let args = try Arguments(tail, flags: ["hidpi", "standard"])
            let name = try args.machineName()
            var machine = try store.load(name)
            guard args.flags.count == 1 else { throw Failure("Usage: terminal-mac display [NAME] --hidpi|--standard") }
            guard !(try runtimeIsLocked(store.directory(name))) else { throw Failure("Stop the VM first: terminal-mac stop \(name). The display mode applies at the next boot.") }
            machine.scale = args.flags.contains("hidpi") ? 2 : 1
            try store.save(machine)
            try printJSON(["name": name, "display": "\(machine.width)×\(machine.height) points at \(machine.displayScale)x"])
        case "clipboard":
            guard tail.count == 2, ["copy", "paste"].contains(tail[1]) else { throw Failure("Usage: terminal-mac clipboard NAME copy|paste") }
            let name = tail[0]
            try validateName(name)
            let directory = try store.directory(name)
            switch try InputLease.probe(directory: directory) {
            case .free: break
            case .unresolved:
                throw Failure("Previous guest input operation is unresolved; reconcile retained lease evidence before clipboard transfer")
            case .held, .heldUnknown:
                throw Failure("Guest input is locked; use a lease-holder action or wait for its completion")
            }
            guard try Self.isRunning(directory) else { throw Failure("VM is not running") }
            let mailbox = try Mailbox(directory.appendingPathComponent("exchange"))
            if tail[1] == "paste" { try await ClipboardBridge.paste(mailbox) }
            else { try await ClipboardBridge.copy(mailbox) }
            try printJSON(["clipboard": tail[1], "state": "done"])
        case "action": try await action(tail)
        case "mcp":
            let args = try Arguments(tail, flags: ["config"])
            let name = try args.machineName()
            if args.flags.contains("config") {
                // Point clients at the launcher, not the versioned bundle, so upgrades keep working.
                let server: [String: Any] = ["command": launcherPath, "args": name == "default" ? ["mcp"] : ["mcp", name]]
                let data = try JSONSerialization.data(withJSONObject: ["mcpServers": ["terminal-mac": server]], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                print(String(decoding: data, as: UTF8.self)); return
            }
            try await AgentServer(store: store, name: name).run()
        case "skills":
            let args = try Arguments(tail, options: ["dir"])
            guard let skill = bundledSkill else { throw Failure("This build has no bundled skill. Reinstall terminal-mac.") }
            switch args.positionals {
            case ["get"], []: print(try String(contentsOf: skill, encoding: .utf8), terminator: "")
            case ["path"]: print(skill.path)
            case ["install"]:
                let root = args.options["dir"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills")
                let destination = root.appendingPathComponent("terminal-mac/SKILL.md")
                if let existing = try? String(contentsOf: destination, encoding: .utf8), !existing.contains("\nname: terminal-mac\n") {
                    throw Failure("Refusing to replace a different skill at \(destination.path)")
                }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contentsOf: skill).write(to: destination, options: .atomic)
                try printJSON(["installed": destination.path])
            default: throw Failure("Usage: terminal-mac skills [get|path|install [--dir ~/.claude/skills]]")
            }
        case "view":
            let args = try Arguments(tail, flags: ["read-only"], options: ["protocol"])
            let name = try args.machineName()
            let machine = try store.load(name)
            guard try runtimeIsLocked(store.directory(name)) else { throw Failure("VM '\(name)' is stopped. Start it with: terminal-mac start \(name)") }
            let viewer = try TerminalViewer(directory: store.directory(name), machine: machine, graphics: args.options["protocol"], readOnly: args.flags.contains("read-only"))
            try await viewer.run()
        case "guest":
            let args = try Arguments(tail, flags: ["check"], options: ["exchange"])
            guard args.positionals.isEmpty else { throw Failure("Usage: terminal-mac guest [--check] [--exchange PATH]") }
            try GuestGuard.requireVirtualMac()
            if args.flags.contains("check") { print("virtual-mac"); return }
            if try await GuestBootstrap.installAndRelaunchIfNeeded() { return }
            let exchange = URL(fileURLWithPath: args.options["exchange"] ?? "/Volumes/My Shared Files/control")
            guest = try GuestRuntime(exchange: exchange)
            guest!.start()
            while true { try await Task.sleep(nanoseconds: 1_000_000_000) }
        default: throw Failure("Unknown command: \(command). Run terminal-mac help.")
        }
    }
    func host(_ name: String, action: String, arguments: [String: String] = [:], timeout: Double = 5) async throws -> Reply {
        try await Mailbox(store.directory(name).appendingPathComponent("host-control")).call(Request(action: action, arguments: arguments, timeout: timeout))
    }
    func action(_ input: [String]) async throws {
        // Diagnostics opt-in never copies error text or input operands. Respect
        // '--' so literal payload cannot enable an option accidentally.
        let structured = input.prefix(while: { $0 != "--" }).contains("--structured-errors")
        var dispatched = false
        var diagnosticPhase = "validation"
        do {
        let args = try Arguments(input, flags: ["double", "structured-errors"], options: ["vm", "x", "y", "x2", "y2", "dx", "dy", "text", "key", "button", "count", "output", "timeout", "owner", "terminal-proof", "terminal-pid", "terminal-window"])
        let target = try GuestActionTarget(positionals: args.positionals, explicitName: args.options["vm"])
        let name = target.name, verb = target.verb
        let requestedKey = try TerminalInputContract.resolvedKey(
            verb: verb, option: args.options["key"], operands: target.operands)
        let wireVerb = try TerminalInputContract.wireAction(verb, proof: args.options["terminal-proof"],
            pid: args.options["terminal-pid"], window: args.options["terminal-window"], key: requestedKey)
        var positions = target.operands
        var parameters = args.options
        parameters.removeValue(forKey: "output"); parameters.removeValue(forKey: "timeout")
        parameters.removeValue(forKey: "vm"); parameters.removeValue(forKey: "owner")
        if let proof = parameters.removeValue(forKey: "terminal-proof") { parameters["terminalProof"] = proof }
        if let pid = parameters.removeValue(forKey: "terminal-pid") { parameters["terminalPID"] = pid }
        if let window = parameters.removeValue(forKey: "terminal-window") { parameters["terminalWindow"] = window }
        if ["type", "terminal-type", "clipboard-paste"].contains(verb), !positions.isEmpty { parameters["text"] = positions.joined(separator: " "); positions.removeAll() }
        if ["key", "terminal-key"].contains(verb), !positions.isEmpty {
            parameters["key"] = requestedKey
            positions.removeAll()
        }
        if ["click", "move"].contains(verb), positions.count == 2 { parameters["x"] = positions.removeFirst(); parameters["y"] = positions.removeFirst() }
        if verb == "drag", positions.count == 4 {
            for key in ["x", "y", "x2", "y2"] { parameters[key] = positions.removeFirst() }
        }
        guard positions.isEmpty else { throw Failure("Unexpected action arguments") }
        if args.flags.contains("double") { parameters["double"] = "true" }
        let timeout = try args.integer("timeout", default: 15, range: 1...120)
        if verb == "terminal-open", !parameters.isEmpty { throw OutcomeFailure("TERMINAL_GUARD_INVALID", outcome: .noEffect) }
        diagnosticPhase = "admission"
        _ = try store.load(name)
        let directory = try store.directory(name)
        // A scenario holding the run lease drives its own CLI actions with the same owner token;
        // anyone else is refused before a request is written.
        switch InputLease.admission(probe: try InputLease.probe(directory: directory), claimedOwner: args.options["owner"]) {
        case .allowed: break
        case .locked(let holder): throw Failure("Guest input is locked by \(holder); wait for its holder to finish")
        case .lockedUnknown: throw Failure("Guest input is locked by another client; holder identity is unavailable")
        case .lockedUnresolved:
            throw Failure("Previous guest input operation is unresolved; reconcile retained lease evidence before dispatch")
        }
        let mailbox = try Mailbox(directory.appendingPathComponent("exchange"))
        let request = Request(action: wireVerb, arguments: parameters, timeout: Double(timeout))
        let imageName = "image-\(request.id.uuidString).png"
        defer { mailbox.remove(imageName) }
        if verb == "screenshot" || verb == "snapshot" { try mailbox.prepareSlot(imageName) }
        diagnosticPhase = "dispatch"
        dispatched = true
        let reply = try await mailbox.call(request)
        diagnosticPhase = "output"
        var values = reply.values
        if verb == "screenshot" || verb == "snapshot" {
            guard values["image"] == imageName, let png = try mailbox.read(imageName, limit: 32 * 1024 * 1024) else { throw Failure("Invalid guest image response") }
            let output = URL(fileURLWithPath: ((args.options["output"] ?? "terminal-mac-\(name).png") as NSString).expandingTildeInPath)
            try png.write(to: output, options: .atomic)
            values["image"] = output.path
        }
        try printJSON(values)
        } catch {
            guard structured else { throw error }
            let diagnostic = ActionFailureDiagnostic(error: error, dispatched: dispatched, phase: diagnosticPhase)
            let data = try JSONEncoder().encode(diagnostic)
            print(String(decoding: data, as: UTF8.self))
            // The top-level CLI handler must not echo a possibly sensitive
            // original error after the sanitized envelope has been emitted.
            throw Failure("ACTION_FAILED")
        }
    }
    /// The agent skill shipped inside the app bundle, so its instructions match this version.
    /// Development builds outside a bundle fall back to the repository copy.
    var bundledSkill: URL? {
        let bundled = executableURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/skills/terminal-mac/SKILL.md")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        var directory = executableURL.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("skills/terminal-mac/SKILL.md")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        return nil
    }
    /// How the user invoked us, before symlinks: the installer's stable launcher.
    var launcherPath: String {
        let invoked = CommandLine.arguments[0]
        if invoked.contains("/") { return URL(fileURLWithPath: invoked).standardizedFileURL.path }
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(directory)/\(invoked)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return executableURL.path
    }
    func runtimeIsLocked(_ directory: URL) throws -> Bool { try Self.isRunning(directory) }
    static func isRunning(_ directory: URL) throws -> Bool {
        try RuntimeLock.isHeld(in: directory)
    }
    static let help = """
    terminal-mac — a separate macOS desktop for computer-use agents

    up [NAME]                   Download, install, boot and open your virtual Mac
      [--ipsw PATH]             Optional existing image; otherwise downloaded from Apple
      [--no-view | --detach]    Wait for readiness without viewing, or just boot
      [--plan] [--timeout 1800] Preview steps without changes; setup wait in seconds
    setup [NAME]                Same guided flow as up
    terminal-mac                Runs up in an interactive terminal

    image [--output PATH]         Find or download Apple's latest supported IPSW
    create [NAME] --ipsw PATH     Install a new virtual Mac (default name: default)
      [--cpus 4 --memory 4 --disk 64 --width 1280 --height 800 --offline]
      [--standard]                1x display; new VMs default to sharp 2x HiDPI
    display [NAME] --hidpi|--standard  Switch a stopped VM between 2x and 1x
    start [NAME] [--window]       Boot in the background; show setup window if requested
    view [NAME] [--read-only]     Live terminal desktop (Ghostty, Kitty, iTerm2)
      [--protocol kitty|iterm]    Ctrl+G opens Mac shortcuts; Ctrl+] exits
    show|hide [NAME]             Show or hide the native VM window
    status|pause|resume [NAME]   Manage the VM
    stop [NAME] [--force]        Request guest shutdown (or immediately power off)
    ls                          List installed VMs as JSON
    doctor                      Check host support and bundled guest tools
    rename OLD NEW              Rename a stopped VM, preserving identity and guest data
    clone OLD NEW [--offline]   Clone a stopped VM with a fresh identity; optionally disable its network
    lease NAME status           Report which client currently owns guest input

    clipboard NAME copy|paste    Transfer selected guest text to host, or paste host text in guest
    action --vm NAME status
    action --vm NAME screenshot [--output PATH]
    action --vm NAME click X Y [--button right] [--double]
    action --vm NAME move X Y
    action --vm NAME drag X Y X2 Y2
    action --vm NAME type 'text'
    action --vm NAME key cmd+space
    action --vm NAME scroll --dy -300 [--dx 0 --x 640 --y 400]
    action --vm NAME clipboard-copy|clipboard-paste [--text TEXT]
    action --vm NAME terminal-open     Launch only the guest's system Terminal app
    action --vm NAME type|key ... --terminal-proof terminal-input/2 --terminal-pid PID --terminal-window TOKEN
      Guarded input uses distinct wire verbs; a legacy helper cannot ignore the guard.
      Terminal UI focus is not shell-prompt readiness. --structured-errors emits safe JSON errors.
      Legacy action NAME ACTION and default-target ACTION remain supported
      when unambiguous. Verb-named VMs and verb-like text require explicit syntax.

    mcp [NAME]                  MCP server (stdio) with computer-use tools for agents:
                                claude mcp add terminal-mac -- terminal-mac mcp
      [--config]                Print an mcpServers entry for Cursor, VS Code, Codex…
    skills get|path|install     The agent skill for this version; install copies it
      [--dir ~/.claude/skills]  into an agent's skills folder

    Actions require TerminalMacGuest.app running inside the logged-in guest.
    Screen Recording and Accessibility are granted inside the guest only.
    TERMINAL_MAC_HOME overrides the host data directory.
    """
}

/// The app bundle around the running executable. Bundle.main cannot find it when the CLI is
/// started through the installer's symlink, so versions would fall back to a guess.
let appBundle: Bundle = {
    let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).standardizedFileURL.resolvingSymlinksInPath()
    return Bundle(url: executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) ?? Bundle.main
}()
var appVersion: String { appBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

func printJSON(_ value: [String: String]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}
