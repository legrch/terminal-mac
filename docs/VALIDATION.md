# Validation

## Native application service source qualification (November 12, 2026)

The compiled guest service uses `terminal-mac.app-service/4` plus the separately
advertised `terminal-mac.launch-identity/1` capability. Clients requiring the
new lifecycle must check both before effects. It accepts data-only payloads
bound to an independently accepted tree and finite executable-signature policy.
Installation verifies a private sibling under guest `/Applications` before
atomic no-overwrite publication; an existing application is never replaced.

Launch root and the unique regular GUI primary have separate native executable,
PID/start and ancestry bindings. AX/foreground and normal Quit use the proven
primary; original root exit is separately observed through kernel events. No
shell, arbitrary argv/environment, force termination, restart adoption or replay
is available. Returned launch diagnostics survive failed admission. Unknown
outcomes retain custody, and MCP permits only status/screenshots afterward.

A full native suite at this checkpoint passed 173 tests. These are source/Core
and compilation results, not installed-helper or live-guest acceptance. New
helper packaging and a fresh guest lifecycle remain qualification gates. Old
failed or outcome-unknown runs are not repeated to obtain acceptance.

The desired live receipt is a bound `open → install → launch → activate → quit
→ close` sequence, plus one separately observed relaunch when selected, with
create-only intents/receipts, accepted guest path/tree, original process exits,
foreground AX windows and screenshots. Signature integrity does not prove
publisher identity, notarization, Gatekeeper approval, provider/tunnel readiness
or visual semantics. OS warnings and privacy requirements remain in force.

This file distinguishes build/protocol verification from a live macOS guest test. Results are updated after local checks.

## Automated checks

Verified locally on November 1, 2026 (Apple silicon, macOS 26.0, Swift 6.2.1):

- Debug build and 14 XCTest protocol/input/setup tests passed, with zero failures.
- Release build passed using `scripts/build.sh`.
- The packaged host and guest apps passed strict recursive signature verification.
- Host entitlements contain `com.apple.security.virtualization`; guest entitlements do not.
- The packaged `doctor` reports virtualization supported and guest tools bundled when run with ordinary system access. The restricted build environment reports virtualization unavailable; that result does not describe host hardware capability.
- `help`, empty `ls`, and the missing-VM error path behaved as expected.
- `guest --check` refused to run on the physical host and exited nonzero before initializing the app UI or requesting privacy permissions.
- Build-script shell syntax passed.
- `image` successfully fetched Apple's supported restore-image metadata without downloading the IPSW.

Version 0.2.0 packaging checks:

- Built `dist/releases/terminal-mac-0.2.0-2-macos-arm64-signed-local.zip` and verified its SHA-256 checksum.
- Both bundled apps have Developer ID signatures, Hardened Runtime and secure timestamps. Strict recursive verification passed with normal macOS signing-service access. Restricted tooling cannot resolve the signing authority and can incorrectly report a signature failure.
- Extracted the actual ZIP and installed it twice to a fresh temporary prefix containing spaces.
- Ran the installed version command and `up --plan`; the plan created no VM data or network download.
- Verified the physical-host guest guard, invalid machine-name rejection and preservation of an unrelated existing executable.
- Confirmed the packaged runtime links macOS system frameworks/libraries rather than development-only libraries.
- Read-only `doctor` reports bundled guest tools and host virtualization support.
- All release/install/package-test scripts passed shell syntax checks.
- An existing Developer ID identity and authenticated notary profile are available. Automatic approval review rejected the application-binary upload to Apple; notarization has not run, and the candidate is explicitly labeled not notarized. No application binaries were submitted or published.

No macOS restore image was found in the user's Downloads/Desktop during a targeted search. No restore-image download, VM installation or boot was performed.

## Live guest acceptance (not yet completed)

- Download a compatible Apple IPSW and create a VM; verify sparse disk storage.
- Start it in the native window and complete Setup Assistant.
- Copy the bundled helper into the guest's Applications folder and grant guest privacy permissions.
- Verify opening the shared helper installs/updates its guest-local copy, relaunches it and registers for guest login without host-side changes.
- Exercise `terminal-mac up` from a fresh data root, cached image, recorded incomplete install and configured VM; confirm the guest-readiness wait and default terminal/native-window fallback.
- Verify `action status`, screenshot content and coordinate alignment on Retina/non-Retina guest modes.
- While typing in a host app, have an agent type/click in the guest; verify host focus, pointer and clipboard stay unchanged.
- Test live viewing in Ghostty, Kitty and iTerm2, including window resize, Unicode, arrows, click/scroll, Ctrl+], terminal close and signal cleanup.
- Hide the VM window, continue guest control, then show it again.
- Pause/resume and graceful shutdown; confirm helper timeouts while paused or unavailable.
- Verify forced stop and a fresh boot without disk corruption after a deliberately disposable run.
- With bundled tools, verify the guest sees only `control` (read/write), `tools` (read-only), and `artifacts` (read-only). Without tools, only `control` is mounted. Verify guest artifact writes fail and offline configuration has no guest NIC.
- Rebuild/reinstall the helper and check privacy permission behavior under ad-hoc and stable signing.

Dated live observation (November 8, 2026, macOS 27 guest, installed tool): `vm.requestStop()`
did not complete guest shutdown twice (stuck in "stopping" past the 60-second warning on an idle
desktop and again on a freshly booted one); the standard Apple-menu Shut Down dialog completed a
normal shutdown both times. One cause was leftover Terminal windows running old smoke serve
loops. `stop --force` was never used. This observation is a receipt, not a fix; the ACPI path
needs its own investigation before any reliability claim.

Recent source additions are NOT live-qualified; each needs its own guest receipts before any live claim:

- Input lease: verify a viewer or scenario holds `<machine>/input-lease.lock`; competing CLI actions are refused; the holder's own `--owner` actions pass; and the native window refuses foreign input. Verify the updated guest helper defers self-replacement while a marker is present, including after expiry or when unreadable, and resumes when it is absent after a confirmed release. Installed-helper compatibility and a host–guest handshake remain unqualified.
- Mailbox publication: late replies cannot recreate named reply/artifact files after caller timeout or cancellation (slot refusal); residue from crashed callers is swept only after it outlives any legal deadline; typed outcomes reach the caller and unclassified old-helper errors stop dependent input.
- Stopped rename: run/lease/collision refusals, identity/disk/guest-data preservation across `rename OLD NEW`, helper readiness after restart under the new name, and interrupted-rename detection and recovery.

No inline-terminal rendering, guest privacy grant, guest screenshot or guest input behavior should be described as live-verified until these checks are performed.

### Native application-session checkpoint (November 12, 2026)

The current source has 186 passing XCTest cases and a successful debug package
(build 12). AppService remains `/4` and separately advertises launch identity
`terminal-mac.launch-identity/1`. The accepted-manifest launch plan excludes
accessory/background bundles from regular GUI-primary selection even when their
vendor plist omits `CFBundleExecutable`; regular and outer bundles remain strict.

Optional MCP application bootstrap binds separately supplied payload/acceptance
hashes, the original lease owner, launch root and GUI-primary start identities.
It observes foreground/AX readiness independently, waits only through new
read-only observations, and retains unresolved effects instead of replaying them.
Clean EOF requires normal Quit, both original exit observations and final tree
verification. Pure tests cover the complete positive sequence and negative
binding, deadline and unknown-outcome cases. This checkpoint is source/native
qualification; it does not yet establish live MCP readiness or a successful
installed application lifecycle in the current helper build.

A subsequent cold guest run established launch-root/GUI-primary binding, but
exposed process-inventory churn during a later complete census read. The native
adapter now samples a bounded number of new complete read snapshots; it never
omits an unreadable process or retries an application effect. Persistent churn
and changed owned identity still fail. The updated source has 189 passing
XCTest cases and a successful build13 package. The host application-session GUI
wait is also bounded at 60 seconds within its original 600-second lifetime.
These remain source qualification until a new guest lifecycle closes normally.

### Cold-clone clock synchronization checkpoint (November 12, 2026)

Live helper13 runs reached MCP READY, rendered Farol Dev Setup/Home, accepted
guest keys/text, and closed both original application processes normally. A
separate native official 0.5.22 run installed into guest /Applications and
completed Quit/relaunch/Quit/close with distinct primary PIDs and one observed
window. These do not qualify Dev account/tunnel connectivity.

A later cold clone accepted open then refused install as APP_SERVICE_EXPIRED
within one host timestamp second. The guest record used wall-clock Date for
its 600-second lifetime, so guest clock synchronization could shorten/extend
the live budget. The compiled adapter now anchors a live-only timebase to
ContinuousClock; persisted records remain non-adoptable and normal Quit/close
remain permitted after expiry. The original failed run remains unresolved.
191 XCTest cases pass, including expiry at elapsed 600 seconds, safe close,
invalid/regressing elapsed values. Build14 packages successfully. Guest base
permissions were re-confirmed through normal UI; fresh-clone live qualification
of this timebase fix must be recorded separately.

### Quit-inventory drain checkpoint (November 12, 2026)

The fresh official helper14 run issued one normal Quit, then reported unknown;
a later bound read-only observation showed both original process exits. The
one-shot post-exit inventory check could reject delayed accepted helpers or
LaunchServices registry entries. The corrected live policy freezes complete
pre-Quit identities, issues terminate once, and observes original exits before
waiting only on unchanged known process/registry survivors. Incomplete/torn
reads, new accepted processes and changed identities still freeze the run.
Close performs an independent fresh census and installed-tree verification.
The native close adapter now supplies the original custody/deadline check; it
has no silent unchecked default.

217 XCTest cases pass (including 26 new quit-drain regressions), and the
integrated helper15 package builds. The original UNKNOWN remains unchanged.
Fresh guest qualification of helper15 is a separate pending gate. No force
application termination, PID-name acquisition or historical fence cleanup was
introduced. Arbitrary detached-descendant cleanup remains unverified.

### Pre-effect Quit census qualification (November 12, 2026)

Helper15 in fresh `farol-qa-14` inherited both grants and automatic login.
Install, launch, first normal Quit, relaunch and one-window observation passed.
The second Quit failed before terminate (`normalQuitRequested=false`,
`PROCESS_CENSUS_CHANGED`); its original UNKNOWN and disk/fence remain retained.
The pre-terminate census now uses the existing eight-attempt full torn-read
sampler, with original custody/deadline checks in every attempt. No partial
snapshot is accepted and no application effect is repeated. Post-terminate
drain and close still fail immediately on an unreadable/torn sample. All 217
XCTest cases pass; helper16 live qualification remains pending.

### Helper16 live qualification (November 12, 2026)

Source `e7ab429` / installed build16 passed fresh `farol-qa-15` official
0.5.22 install, launch, activation, normal Quit, distinct-PID relaunch,
second normal Quit and close. Independent relaunch observation found one
window; final installed tree verified at close. All 217 XCTest cases pass.

Farol source `54b407a9` default `task vm:dev` also passed in a fresh hidden
clone with inherited login and both TCC grants. MCP admitted guest screenshot,
click, key and literal text input; clean EOF exited zero with immutable CLOSED,
both original exits and final installed-tree verification. The lease was free
afterward and the guest shut down normally.

After its clean accepted lifecycle, qa15's separate generic MCP journey
qualified the real 0.5.22→0.5.23 updater: completed guest journal, released
archive, successor build ID, rendered Home and normal Quit/reopen UI. This does
not qualify provider/account tools, arbitrary descendants or formal review.
Earlier UNKNOWN runs retain their disks/fences and are not replayed or healed.

For an ad-hoc helper update, Finder may activate the existing installed helper
instead of starting the newer shared app. In a positively identified guest
Terminal, normal `open -n '/Volumes/My Shared Files/tools/TerminalMacGuest.app'`
started the normal installer. Its guest service/lease guards still applied.
Re-add only the installed guest app through normal macOS permission UI when
ad-hoc signing changes; never reset TCC databases or change host security.

### Post-terminate drain torn reads (November 12, 2026)

Helper16 in fresh `farol-qa-59903180cc7c4a62` reached READY and rendered the
Dev app, then the clean-EOF Quit returned `APP_SERVICE_QUIT_UNKNOWN` about 1.5 s
later with no Quit receipt. The guest did not publish its failing step, so the
cause is not proven; the likeliest is a strict single-read census raising
`PROCESS_CENSUS_CHANGED` while Electron helpers exited after terminate. That
original UNKNOWN, its disk and its lease fence remain retained.

After both original exits the drain now re-reads a torn census with the same
eight-attempt sampler (original custody/deadline checked in every attempt). A
sample that is torn on every attempt is `inventoryUnobserved`: neither a
survivor nor quiescence, and the loop waits for the next observation under the
original deadline only. Unreadable or incomplete inventories, changed original
identity, new or reused accepted PIDs and deadline expiry still fail at once.
Terminate is still requested at most once. A failed Quit/Close now returns its
step (`quitStep`), reason, `normalQuitRequested`, drain state and counters (no
paths or identities) in the failure reply; the MCP host publishes them as
`failure-<sequence>-<command>.json` beside the intent. The outcome stays
UNKNOWN. All 222 XCTest cases pass; helper live qualification remains pending.
