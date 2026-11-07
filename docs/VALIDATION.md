# Validation

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

No inline-terminal rendering, guest privacy grant, guest screenshot or guest input behavior should be described as live-verified until these checks are performed.
