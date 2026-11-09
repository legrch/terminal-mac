# terminal-mac

[![](https://img.shields.io/static/v1?label=Sponsor&message=%E2%9D%A4&logo=GitHub&color=%23fe8e86)](https://github.com/sponsors/govijr)
<a href="https://buymeacoffee.com/govijr" target="_blank"><img src="https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png" alt="Buy Me A Coffee" style="height: 21px !important;width: 108px !important;box-shadow: 0px 3px 2px 0px rgba(190, 190, 190, 0.5) !important;-webkit-box-shadow: 0px 3px 2px 0px rgba(190, 190, 190, 0.5) !important;" ></a>


A separate macOS desktop for computer-use agents, viewed and controlled from a terminal.

`terminal-mac` is an early release candidate for Apple silicon. Apple Virtualization runs a real macOS guest. A bundled helper **inside that guest** captures its screen and posts input events. A terminal viewer streams that screen using Kitty or iTerm2 graphics. Agent commands use the same helper without moving the physical Mac's pointer or changing its clipboard.

The guest is a separate Mac: it has its own apps, files, accounts and permissions. It does not inherit your running host apps or signed-in sessions. The VM still consumes host CPU, memory and storage.

## Requirements

- Apple silicon Mac, macOS 14 or later.
- No development tools are needed for a prebuilt release. Maintainers need Xcode 16 or later / Swift 6 to build.
- Internet on first run to download macOS directly from Apple, or an existing compatible `.ipsw`.
- Space for the cached restore image and a growing VM disk (64 GiB logical size by default).
- Ghostty, Kitty or iTerm2 for the inline viewer. Other terminals can use the native VM window and agent CLI. tmux passthrough and automatic terminal splits are not implemented.

## Install and run

```sh
curl -fsSL https://github.com/govijr/terminal-mac/releases/latest/download/get.sh | bash
```

The installer downloads the latest release and verifies its SHA-256 before installing. You can also extract a release ZIP and run `bash install.sh` from it.

The installer places one launcher in `~/.local/bin` and the bundled runtime under `~/.local/lib/terminal-mac`. Add `~/.local/bin` to your PATH to use simply `terminal-mac`. It needs no administrator rights and does not edit your shell configuration. `bash install.sh --prefix /absolute/path` selects another location.

Running `terminal-mac` in an interactive terminal starts the guided flow. `terminal-mac up` does the same explicitly. It automatically downloads/caches a compatible Apple restore image, installs a virtual Mac, boots it and checks the guest helper. Later runs reuse the existing VM and reconnect. Unsupported terminals get the native desktop window.

**Current status:** early release candidate. Releases are self-signed (no Apple notarization), which the curl installer doesn't need. Live guest acceptance on a clean Mac is still pending.

## Use with agents

terminal-mac gives agents computer use in a separate virtual Mac, through MCP tools (`screenshot`, `click`, `drag`, `scroll`, `type`, `key`, `status`) and a skill that teaches the observe → act → verify loop.

**Claude Code**, with the MCP server and skill in one plugin:

```text
/plugin install terminal-mac --marketplace govijr/terminal-mac
```

Or add them separately:

```sh
claude mcp add terminal-mac -- terminal-mac mcp
terminal-mac skills install                 # → ~/.claude/skills/terminal-mac/SKILL.md
```

**Other MCP clients** (Cursor, VS Code, Codex, Windsurf…): paste the output of `terminal-mac mcp --config` into the client's MCP settings. Use `terminal-mac mcp NAME` for a VM other than `default`.

**Any agent with a skills folder:** `terminal-mac skills install --dir PATH`, or `npx skills add govijr/terminal-mac --skill terminal-mac`. In an `AGENTS.md`, a line like "Before using the virtual Mac, run `terminal-mac skills get`" gives the agent instructions that match the installed version.

The tools only drive the guest helper. They never touch your own desktop. When the guest is at its login screen, they say so, so the agent can ask you to sign in.

## One-time guest setup

The first run opens the virtual Mac's window. Complete macOS setup and create its user account. Inside the guest, open Finder → `/Volumes/My Shared Files/tools` → `TerminalMacGuest.app` once. The helper installs itself in the guest's `~/Applications`, launches that installed copy and registers for future guest logins, subject to macOS approval.

Use its two buttons to grant **Screen Recording** and **Accessibility** inside the guest. Reopen it if macOS asks. If needed, its **Guest Login Items** button opens the startup setting. The host needs neither privacy permission. Once both guest permissions are ready, the CLI automatically continues to the terminal desktop.

This is guided setup, not an unattended guest installation. Apple documents automatic account provisioning for macOS 27 guests; this build targets the APIs available in the installed macOS 26 SDK and does not implement that newer flow. See [Apple's provisioning documentation](https://developer.apple.com/documentation/virtualization/vzmacguestprovisioningoptions).

```sh
terminal-mac up work                  # another virtual Mac
terminal-mac up --ipsw /path/mac.ipsw  # use a local image
terminal-mac up --no-view             # wait for agent readiness, then return JSON
terminal-mac up --detach              # install/boot, return without waiting for guest setup
terminal-mac up --plan                # show steps without network access or disk changes
```

The first download may take time; packaging cannot eliminate downloading and installing macOS. The image cache is reused, and URLSession resume data is retained after recoverable network failures. A hard process kill may require the current download to restart. An incomplete installation with recorded hardware can be retried by `up` using a compatible restore image; an already installed VM is never reinstalled by `up`.

## Build from source

```sh
bash scripts/build.sh
./dist/terminal-mac doctor
```

The build creates `dist/TerminalMac.app`, including `TerminalMacGuest.app`, and the `dist/terminal-mac` launcher. Virtualization needs the host executable's `com.apple.security.virtualization` entitlement; use the packaged launcher instead of the unsigned Swift build product.

It is signed with the self-signed "Govijr Code Signing" identity when your keychain has it (`bash scripts/create-signing-identity.sh` makes one), and ad-hoc otherwise. A stable identity keeps the guest helper's permissions across rebuilds; ad-hoc builds need them granted again. [RELEASING.md](RELEASING.md) covers signing and publishing.

## Create your first Mac

```sh
# Show the URL and version without downloading anything:
./dist/terminal-mac image

# Explicitly download Apple's latest supported restore image (several GB):
./dist/terminal-mac image --output /tmp/RestoreImage.ipsw

# Install macOS. The disk is sparse, and the IPSW is not copied into the VM bundle.
./dist/terminal-mac create default --ipsw /tmp/RestoreImage.ipsw
./dist/terminal-mac start default --window
```

Complete macOS Setup Assistant in the VM window and create a guest account. Inside the guest:

1. Open Finder → `/Volumes/My Shared Files/tools`.
2. Open `TerminalMacGuest.app`. It installs itself to the guest's `~/Applications` and opens the installed copy.
3. Use the helper's buttons to grant **Screen Recording** and **Accessibility** in the guest's System Settings. Reopen the helper if macOS asks. The host does not need either permission.
4. Keep the guest logged in and the helper running. It registers itself for guest login; approve that setting if macOS requests it.

On the host:

```sh
./dist/terminal-mac action default status
./dist/terminal-mac hide default
./dist/terminal-mac view default
```

The viewer supports typing, left/right clicks, double and triple clicks, dragging, scrolling, arrows and common control keys. **Ctrl+G** opens a palette of Mac shortcuts (Spotlight, Mission Control, copy/paste, close/quit and more), because terminals keep ⌘ for themselves. **Ctrl+]** exits the viewer while the VM keeps running. Closing the native VM window hides it and also leaves the VM running.

The guest helper keeps a ScreenCaptureKit stream open while a viewer is watching. It sends a frame only when the screen changes (up to 30 fps), already sized to the pixels the terminal draws, as lossless lz4-compressed pixels. Kitty and Ghostty receive those frames through shared memory rather than the pty. An idle desktop costs nothing, and the stream stops 15 seconds after the viewer leaves. From build 4 on, the guest helper updates itself: within 30 seconds of a newer build appearing in the shared tools folder, it installs that build and relaunches. Helpers from build 3 and earlier still work but poll full screenshots, and the header shows "snapshots". Update those once by opening `/Volumes/My Shared Files/tools/TerminalMacGuest.app` in the guest. Releases are signed with one unchanging self-signed certificate, so the guest keeps its Screen Recording and Accessibility approvals across updates.

Guest helper updates must satisfy the running helper's designated code requirement. Stable certificate-signed builds retain their update identity. An ad-hoc rebuild generally has a different code identity and is refused by automatic updates; install it manually inside the guest and grant its permissions again.

Agents can drive the guest through an MCP server: `claude mcp add terminal-mac -- "$PWD/dist/terminal-mac" mcp default`. See [docs/AGENT.md](docs/AGENT.md).

New VMs use a 2x HiDPI display (for example 2560×1600 pixels at 220 ppi for the default 1280×800 points), so text stays sharp on Retina terminals. Switch a stopped VM with `terminal-mac display default --hidpi` or `--standard`.

The automounted volume is supplied by macOS virtio-fs. If it is absent, check the guest's macOS version and the VM log; this prototype has no fallback guest transport.

## Give an agent computer control

```sh
./dist/terminal-mac action default screenshot --output /tmp/guest.png
./dist/terminal-mac action default click 640 400
./dist/terminal-mac action default type 'Hello from the agent'
./dist/terminal-mac action default key cmd+space
./dist/terminal-mac action default key return
./dist/terminal-mac action default scroll --dy -300 --x 640 --y 400
```

Use `action --vm NAME ACTION` when selecting a VM explicitly, especially if its
name is also an action verb. For example, `action --vm clipboard-paste status`
reads that VM's status. The ambiguous legacy form `action clipboard-paste status`
is rejected; it must never paste into `default`. Existing unambiguous forms such
as `action pilot status`, `action status`, and `action type 'hello'` still work.
For verb-like text, use `action --vm default type status` or
`action type --text status`. Target selection never depends on which VMs exist.

Commands return JSON and a nonzero exit status on failure. Screenshots return a local host PNG path. Coordinates start at the top-left and match the screenshot's dimensions; screenshots use guest display points to keep input coordinates consistent on Retina displays. `snapshot` is currently a screenshot alias, not an accessibility-tree snapshot.

Guest input uses a cooperative lease. While a viewer, an MCP agent or a product scenario
holds it, other clients are refused; a holder can use `action --owner <token>` for its own
actions. `terminal-mac lease NAME status` also reports `state: unresolved-predecessor` and
`inputAllowed: false` when the kernel lock is free but prior custody evidence remains. A
`held: false` response alone does not authorize input: consumers must inspect the state.
Retained or unreadable evidence must be reconciled, not removed automatically. The updated
guest helper defers self-replacement while a marker exists, even after expiry. These checks
do not authenticate the owner token or make a probe and action atomic; older installed
helpers and clients require separate compatibility verification.

The agent instructions are in [docs/AGENT.md](docs/AGENT.md). No global agent settings are modified.

## Lifecycle and resources

```sh
./dist/terminal-mac ls
./dist/terminal-mac status default
./dist/terminal-mac pause default
./dist/terminal-mac resume default
./dist/terminal-mac show default
./dist/terminal-mac stop default          # request a normal guest shutdown
./dist/terminal-mac stop default --force  # immediate power-off; unsaved guest work can be lost
```

Customize a new VM with `--cpus 4 --memory 4 --disk 64 --width 1280 --height 800` (width and height are in points; add `--standard` for a 1x display). CPU, memory and disk arguments are logical CPUs, GiB and GiB respectively. `--offline` omits the guest network device; the shared-folder control channel still works, though some macOS setup workflows may require networking. Rename a stopped machine with `terminal-mac rename OLD NEW`: one atomic same-volume move that preserves identity, disks, auxiliary storage and guest data, refuses running machines, held input leases and collisions, records the old→new mapping in `rename.json`, and detects a half-finished earlier rename instead of adopting it.

VM data lives in `~/Library/Application Support/terminal-mac/machines/NAME/`. `TERMINAL_MAC_HOME` overrides the data root. Each VM has an exclusive file lock, a sparse disk, hardware identity, auxiliary boot storage, `machine.json`, a private host-control mailbox, the guest exchange directory, and `runtime.log`. A VM boot runs as a separate background process. Lifecycle commands must use the same `TERMINAL_MAC_HOME` as the process that started it.

An interrupted or failed installation leaves its directory and `installed: false` for diagnosis. It is never silently overwritten. To retry, ensure no installer/VM is running, move that incomplete directory aside, then create the VM again. There is deliberately no destructive VM-delete command yet.

## Text clipboard between host and guest

The native VM window leaves system shortcuts such as **Cmd+Tab** with the host, so you can switch out of the VM normally.

In the native VM window, **Cmd+V** pastes the host clipboard into the focused guest field;
**Cmd+C** copies the selected guest text to the host clipboard. The guest helper must be
running with Accessibility permission. Only plain text up to 32 KiB is supported; files,
images and rich formatting are not transferred. A failed or empty guest copy keeps the
host clipboard unchanged before a host write is attempted. Paste captures the text when
the command is received, before waiting in an input queue; Copy checks the initiating
host clipboard revision again immediately before writing. This is not an atomic
conditional write: another process can still race that local OS operation. Native
shortcut errors beep and appear in the VM runtime log.

In the terminal viewer, **Ctrl+G**, then **V** pastes host text; **Ctrl+G**, then **C** copies
selected guest text to the host. Command-line equivalents:

```sh
terminal-mac clipboard pilot paste
terminal-mac clipboard pilot copy
```

Cut remains guest-only. After guest **Cmd+X**, use **Control+Cmd+V** in the native
window, or **Ctrl+G**, then **P** in the terminal viewer, to paste the guest clipboard
without replacing it with host text. The ordinary host Paste route does not complete a
guest-only Cut. Keep guest focus/input and other guest clipboard writers idle until an
asynchronous transfer completes. The global guest clipboard cannot attest which app
produced an intervening update. A local OS pasteboard write failure can occur after the
previous destination contents have been cleared; this is reported as a transfer error.

Transfers happen only when requested and overwrite the destination clipboard. Clipboard
contents are not printed by these commands. `action pilot clipboard-paste 'text'` and
`action pilot clipboard-copy` are guest-only protocol actions; the latter returns text.
Never use a paste into a shell unless you intend the copied text to be interpreted there.

After building an updated helper, open `/Volumes/My Shared Files/tools/TerminalMacGuest.app`
inside the guest. Existing guest macOS permission prompts may need confirmation. A VM
runtime already running the old host executable needs a normal guest shutdown and start
to enable native-window shortcuts; CLI transfers use the new binary immediately once the
updated guest helper is running. Do not force-stop a guest with unsaved work.

## Isolation model

- Host input and screen APIs are not used for agent actions. The helper refuses to run unless `hw.model` starts with `VirtualMac`. That check prevents accidental host execution; it is not hardware attestation or a defense against a compromised host.
- The guest sees three explicit shares: `control` (read/write, containing request/reply JSON and screenshots) `tools` (read-only helper app), and `artifacts` (private per-machine read-only inbox). Artifact staging lives under the VM data directory, never inside the signed app bundle. Host home, project folders, microphone, and camera are not attached. Clipboard text crosses only on an explicit Copy/Paste action; neither clipboard is polled or mirrored.
- There is no remote-control network listener. The flat mailbox pins its directory, rejects symlinks, hardlinks and nonregular files on reads, bounds message sizes, checks request IDs, and expires pending actions. The host never executes guest-provided content.
- Default NAT networking permits guest internet access and may reach services on the host or local network. This is **not** a network-isolated or hardened hostile-code environment. `--offline` configures no NAT device; verify the running guest separately before claiming isolation.
- A logged-out/locked guest, missing helper, denied guest permissions, or paused VM prevents normal computer use. TCC grants are interactive guest setup, not bypassed by the CLI.

Rollback checkpoints, accessibility snapshots, fully unattended guest setup, terminal splits and tmux transport remain future work. The native Virtualization framework does not itself render a Mac into a terminal or offer an agent input API; this project supplies the guest transport and terminal presentation layers.

## Development and validation

```sh
CLANG_MODULE_CACHE_PATH=/tmp/terminal-mac-modules \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/terminal-mac-modules \
swift test --disable-sandbox --scratch-path /tmp/terminal-mac-build \
  --cache-path /tmp/terminal-mac-cache \
  --config-path /tmp/terminal-mac-config --security-path /tmp/terminal-mac-security
```

Tests cover mailbox round trips, expiry and cleanup, file-boundary defenses, name/option validation, fragmented UTF-8 and terminal input sequences. These are automated protocol checks, not evidence that a guest was installed, booted, granted permissions, or controlled successfully. See [docs/VALIDATION.md](docs/VALIDATION.md) for recorded results and the live checklist.

References: [terminal-browser](https://terminal-browser.com/), [Apple's macOS virtualization sample](https://developer.apple.com/documentation/virtualization/running-macos-in-a-virtual-machine-on-apple-silicon), [VZVirtualMachineView](https://developer.apple.com/documentation/virtualization/vzvirtualmachineview), [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit).

## Sponsor

terminal-mac is free and maintained in my own time. [Sponsoring](https://github.com/sponsors/govijr) keeps it that way.
