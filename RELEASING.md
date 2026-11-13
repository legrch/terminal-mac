# Releasing terminal-mac

The customer package contains precompiled signed apps and a user-local installer. Customers do not need Swift, Xcode, or a separately downloaded helper. macOS itself is fetched from Apple on first run, rather than bundled into the CLI archive.

## Signing

Public releases are signed with a self-signed certificate, **"Govijr Code Signing"**, kept in your login keychain. It names no person, needs no Apple account, and stays the same across releases. macOS ties the guest helper's Screen Recording and Accessibility approvals to it, so users approve them once and updates keep them. (An ad-hoc signature changes with every build and would make users approve again after each update.)

```sh
bash scripts/create-signing-identity.sh   # once per Mac; does nothing if it already exists
```

**Back it up:** Keychain Access → My Certificates → "Govijr Code Signing" → Export. Use that backup to release from another Mac. A new certificate would make every user approve the guest permissions once more.

Files downloaded with `curl` are not quarantined, so Gatekeeper does not require notarization for them. A ZIP downloaded in a browser is quarantined and Gatekeeper will block it, so the README points users to the curl installer.

## Commands

```sh
# Public release, self-signed (default):
VERSION=0.2.0 BUILD_NUMBER=6 bash scripts/release.sh

# Local-only ad-hoc test package:
VERSION=0.2.0 BUILD_NUMBER=6 bash scripts/release.sh --local

# Optional: Developer ID signed and notarized by Apple. The certificate carries the developer's legal
# name, which `codesign -dvv` shows, so this is not the default.
VERSION=0.2.0 BUILD_NUMBER=6 NOTARY_PROFILE=PROFILE bash scripts/release.sh --notarized
```

Increment the positive integer `BUILD_NUMBER` for each build: installed guest helpers update themselves when a higher build appears. `VERSION` uses `major.minor.patch`. Archives are immutable; the scripts refuse to replace an existing release with the same version and build.

Settings in `scripts/release-config.sh`:

- Signing identity: `SIGNING_NAME` (default "Govijr Code Signing"); `SIGN_IDENTITY` overrides it, and `SIGN_IDENTITY=-` signs ad-hoc.
- Signing keychain: `SIGN_KEYCHAIN` (optional absolute path) uses a dedicated, unlocked build keychain without adding it to the user's search list.
- Notary profile (only `--notarized`): `NOTARY_PROFILE`, created with `xcrun notarytool store-credentials PROFILE`. Credentials stay in the Keychain.
- Host bundle: `dev.terminal-mac.host`; guest bundle: `dev.terminal-mac.guest`.
- Architecture: arm64; minimum macOS: 14.
- Artifacts: `dist/releases/terminal-mac-VERSION-BUILD-macos-arm64.zip` and `.zip.sha256` (`--local` adds a `-local` suffix).

Each app is signed independently with Hardened Runtime; only Developer ID signatures get a secure timestamp. The guest has no Virtualization entitlement; the host has `com.apple.security.virtualization`. `--notarized` notarizes and staples the guest separately (users install it inside their VM), re-seals the host, then notarizes, staples and assesses the host. It rejects any result other than `Accepted` and never falls back to another signature.

## Test the package

Extract the release ZIP into a clean temporary location, then:

```sh
bash install.sh --prefix /tmp/terminal-mac-install-test
/tmp/terminal-mac-install-test/bin/terminal-mac --version
/tmp/terminal-mac-install-test/bin/terminal-mac doctor
/tmp/terminal-mac-install-test/bin/terminal-mac up --plan
```

The installed launcher points to a complete versioned app bundle under `PREFIX/lib/terminal-mac`. Do not distribute only the inner executable: that loses the signed resources and bundled guest tools. The installer switches the launcher to the new version and leaves VM data under the user's Library untouched. It does not overwrite unrelated executables or edit shell profiles.

Before announcing production readiness, finish the live guest checklist in `docs/VALIDATION.md`, ideally on a separate clean Mac. Notarization verifies distribution signing; it does not prove VM boot, guest setup, privacy grants, input or terminal rendering work correctly.

## Publishing (GitHub Releases and curl)

The repository is `GITHUB_REPO` in `scripts/release-config.sh` (default `govijr/terminal-mac`). With it set, `release.sh` also writes `dist/releases/NAME-publish/`, which contains:

- the archive and its `.sha256`;
- `get.sh`, the curl installer, pinned to this archive's URL and checksum.

To publish, create a GitHub release tagged `vVERSION-BUILD` (for example `v0.2.0-6`) and attach every file in that folder: on github.com under Releases → Draft a new release, or with `gh release create v0.2.0-6 dist/releases/terminal-mac-0.2.0-6-macos-arm64-publish/* --title "terminal-mac 0.2.0"`.

Users install with `curl -fsSL https://github.com/govijr/terminal-mac/releases/latest/download/get.sh | bash`. Because `get.sh` is attached to each release, `latest/download/get.sh` always installs the newest release. Public releases are self-signed (see Signing).

The repository is also a Claude Code plugin marketplace. `.claude-plugin/plugin.json` registers the MCP server (`terminal-mac mcp`, which must be on PATH) and the skill in `skills/`. Users run `/plugin install terminal-mac --marketplace govijr/terminal-mac`. Check with `claude plugin validate .`, and keep `plugin.json`'s version in step with `VERSION`. The same `skills/` folder works with `npx skills add govijr/terminal-mac --skill terminal-mac`.

## Hosting and current release status

Releases go to `govijr/terminal-mac`. Release scripts produce local immutable artifacts and upload-ready files; they never publish. Once a download host is selected, publish the production ZIP and its checksum there; do not advertise a placeholder installation URL.

Public releases are self-signed and are not uploaded to Apple. `--notarized` is optional and has not been run.

## Fork releases

This fork keeps `scripts/release-config.sh` defaults pointing at the upstream repository and its
`Govijr Code Signing` identity. That is deliberate for upstream compatibility, but it means a fork
release built without overriding `GITHUB_REPO` and `SIGNING_NAME` would bind the upstream channel
and identity. A fork channel must set both explicitly, must pin the exact source revision it
packages, and must never silently substitute upstream release bytes for patched ones; the guest
helper's designated-requirement update check treats a changed signing identity as a different
helper, so a fork identity change re-requires in-guest permission grants. No fork release workflow
is qualified yet; until one is, source here is not evidence of an installable fork release.
