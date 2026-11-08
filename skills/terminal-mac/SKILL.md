---
name: terminal-mac
description: Operate a separate virtual Mac (macOS VM) with screenshots, clicks, typing and shortcuts, without touching the user's own desktop. Use when a task needs a real macOS GUI — testing a Mac app, using a website or desktop app, or any computer-use task the user wants sandboxed.
---

# terminal-mac

`terminal-mac` runs a real macOS guest on Apple silicon. A helper inside the guest captures its screen and posts input, so everything you do happens in the VM. It never controls the user's own desktop.

## Prefer the MCP tools

If tools named `screenshot`, `click`, `type`, `key` and so on from the `terminal-mac` MCP server are available, use them:

1. `status`: the VM is running and both guest permissions are `true`.
2. `screenshot`: every x/y you pass to other tools is a pixel in this image (top-left origin).
3. Act with `click` (`clicks: 2` double-clicks, `button: "right"`), `move`, `drag`, `scroll` (negative `dy` scrolls down), `type` (literal text) or `key` (`return`, `tab`, `escape`, `cmd+space`, `cmd+c`, `cmd+shift+4`…).
4. Look again: pass `screenshot: true` to an action, or call `screenshot`, before deciding the next step.

Opening an app: `key cmd+space`, `type "Safari"`, `key return`. Prefer keyboard shortcuts over hunting for small targets.

## Without MCP: the CLI

Every command prints JSON and exits nonzero on failure. `NAME` defaults to `default`.

```bash
terminal-mac status NAME                     # stopped → terminal-mac start NAME
terminal-mac action --vm NAME status
terminal-mac action --vm NAME screenshot --output /tmp/guest.png   # then view the PNG
terminal-mac action --vm NAME click X Y [--double] [--button right]
terminal-mac action --vm NAME move X Y
terminal-mac action --vm NAME drag X Y X2 Y2
terminal-mac action --vm NAME type 'literal text'
terminal-mac action --vm NAME key cmd+space
terminal-mac action --vm NAME scroll --dy -300 --x X --y Y
```

`action --vm NAME ACTION` is the canonical form. The legacy `action NAME ACTION` spelling still
works while unambiguous, but fails closed when the guest action verb (or the payload after
`--text`) could be read as a VM name — pass `--vm` instead of guessing. Text is sent as Unicode
keyboard events, not through the clipboard. No shell-execution action exists.

Guest input is exclusive. While a viewer, an MCP agent or a scenario (for example a Farol test
run) owns the guest, other clients are refused before anything is sent — the error names the
holder. Check who owns input with `terminal-mac lease NAME status`; do not work around a
held lease, wait for it to finish. Long-running holders drive their own `action` calls with
`--owner <their owner token>`. Renaming a stopped machine (identity, disks and guest data are
preserved): `terminal-mac rename OLD NEW`. Cloning a stopped machine into an INDEPENDENT
instance with a fresh VM identity and a copy-on-write disk: `terminal-mac clone OLD NEW`.

## When to stop and ask the user

- The guest is at its login screen, or the helper is not running (tools report "no logged-in session"): ask the user to sign in, for example `terminal-mac view NAME` then Ctrl+O. Automatic login in the guest avoids this on later boots.
- A macOS permission prompt, password, two-factor code or payment appears in the guest.
- The VM does not exist: `terminal-mac up NAME` downloads macOS from Apple (several GB) and needs the user for first-time setup.

## Safety

- Do not run `terminal-mac guest` on the host, and never fall back to host screenshots or host input tools.
- Apps, files and accounts inside the VM are separate from the user's Mac. Do not move secrets into it unless the user asks.
- `stop` requests shutdown; `stop --force` can lose guest work, so use it only when a normal shutdown cannot complete.
