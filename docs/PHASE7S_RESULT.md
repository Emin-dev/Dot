# Phase 7s — sandboxed, per-user, leave-no-trace Dot

**Status 2026-10-22:** implementation complete, released and green on hosted
macOS. Release **`v1.1.2`** is Latest; every acceptance and no-trace job passed
in run [`39716661710`](https://github.com/Emin-dev/Dot/actions/runs/39716661710).

## What changed

### 1. Apple App Sandbox by default

`Resources/Dot.entitlements` is applied by every packaging path through
[`scripts/sign_sandbox_app.sh`](../scripts/sign_sandbox_app.sh):

- `com.apple.security.app-sandbox`
- `com.apple.security.network.client` (model download)
- `com.apple.security.network.server` (the two loopback-only listeners)
- `com.apple.security.device.audio-input`
- `com.apple.security.files.user-selected.read-write`
- `com.apple.security.personal-information.calendars`
- `com.apple.security.automation.apple-events`

The hardened runtime is enabled, nested executables and `whisper.framework` are
signed before the app, and the signature is read back to prove the sandbox
entitlement is present. No temporary-exception or broad home-directory
entitlement exists.

**Changed 2026-10-22 by owner decision R21** ([OWNER_DECISIONS.md](OWNER_DECISIONS.md)): the set
now also has `com.apple.security.files.downloads.read-only`, a read-only home-relative exception for
`/Desktop/` and `/Documents/`, and an Apple Events exception for System Events, Safari, Chrome,
TextEdit, Music and Spotify. Without them the documented page reading, dark mode and sleep
commands, media pause and new-file awareness could not work in the sandbox. There is still no
write access outside the folder the owner selects.

Every app byte (the 22.4 GB model, logs, health state, history, SQLite index,
caches and settings) now lands inside
`~/Library/Containers/app.dot.local/Data/`. The downloaded model and safety aux
model use the container's Application Support. Soul exports moved from
Downloads to `.../Dot/Exports`.

### 2. Sandbox compatibility fixes

- Splash's Python bootstrap keeps `splash.sb` for standalone runs. When the
  kernel has already applied the app container (`APP_SANDBOX_CONTAINER_ID`), it
  does not nest `sandbox-exec`; the outer App Sandbox is the boundary.
- The pinned research reader (`dot-fetch`) has the same conditional: it keeps
  its inner profile standalone and runs as an inherited sandboxed child under
  the app.
- `dot-voice`, `dot-search`, `dot-fetch`, `dot-safety` and the Python runtime
  are signed Dot-owned children.
- ScreenCaptureKit, AVFoundation/Whisper, MLX/Metal and the safety model keep
  their existing paths; all are inside the container or the app bundle.
- Simple file utilities (`rm`, `rmdir`, `mkdir`, `touch`) that target the
  owner-selected folder run in-process, because a child shell cannot inherit the
  PowerBox extension. The path must be inside that exact folder. Other commands
  still use the sandboxed `/bin/zsh`, which can only reach the container.
- `UserFolderScope` records the last explicitly selected folder and makes it the
  shell's safety target; it never widens the sandbox.
- A `DOT_SANDBOX_SELF_CHECK` mode writes inside the container, attempts a write
  to the real home, and exits nonzero unless the kernel denied it with
  `EPERM`/`EACCES`. CI uses it to prove confinement rather than inferring it from
  the signature alone.

### 3. Zero system changes, per-user install

[`scripts/install-dot.sh`](../scripts/install-dot.sh) now:

- installs to `~/Applications` (default) and refuses `/Applications`;
- never invokes sudo and never asks for an administrator password;
- creates `~/Applications` only when missing and records that with a hidden
  marker so the uninstaller can remove it;
- clears `com.apple.quarantine` only on Dot's own staged bundle, never on the DMG
  or any other file;
- verifies the sandbox entitlements and signature before installing;
- waits for any previous Dot to exit before replacing it;
- prints the exact `open` error and the `spctl` Gatekeeper verdict if macOS
  blocks the first open, instead of hiding it;
- cleans its marker/directory if a later step fails.

There is no LaunchAgent, LaunchDaemon, login item, background item, profile,
extension, PATH/shell-rc edit, `defaults write`, or privileged helper. The app
menu item is the only launcher for the one-shot removal script.

### 4. Complete removal

[`scripts/uninstall-dot.sh`](../scripts/uninstall-dot.sh) is published as a
release asset and is the same script bundled inside the app:

```bash
curl -fsSL https://github.com/Emin-dev/Dot/releases/latest/download/uninstall-dot.sh | bash
```

The in-app **Remove Dot completely…** item confirms, writes the bundled
uninstaller to Dot's own container, and opens Terminal for that one action. A
sandboxed app cannot delete its own bundle or container, so this is the only
honest in-app route without a privileged helper. If Terminal cannot be opened,
the exact command is copied to the clipboard.

Both paths remove the app, `~/Library/Containers/app.dot.local/`, group
containers, caches, saved state, HTTPStorages, WebKit/Cookies data, preferences,
ByHost preferences, recent-documents entries, legacy `Application Support/Dot`,
crash reports, LaunchServices registration and the downloaded model; unload
Dot-owned child processes; run `tccutil reset All app.dot.local`; and remove
`~/Applications` only when the installer created it and it is empty. They end
with `PASS: your Mac is back to how it was` or a precise `FAIL:` line.

### 5. CI proof

[`.github/workflows/privacy-clean.yml`](../.github/workflows/privacy-clean.yml)
runs on hosted `macos-26` (never the Pi or Emin's Mac):

1. package the sandboxed default app from the audited runtime donor;
2. snapshot the user home, `/Applications` and `/Library` with type, mode, size
   and file mtime, plus launchctl labels, background items, defaults domains,
   packages and readable TCC rows;
3. install through the documented `curl | bash` shape;
4. verify the entitlements, the kernel self-check and a real launch smoke test;
5. uninstall through the documented one-liner and require the PASS line;
6. snapshot again, require an empty diff, and require no installer temp
   directory;
7. upload both snapshots and the sandbox evidence as artifacts.

The diff allowlist is only Apple/OS-owned transient cache, log, preference and
database paths that macOS rewrites when Launch Services opens an app, TCC resets
an approval, Shortcuts indexes App Intents, or background agents run. The
allowlist is in [`scripts/privacy_allowlist.txt`](../scripts/privacy_allowlist.txt)
with a reason on every line. Dot-owned paths (`app.dot.local`, `Dot.app`) are
never allowlisted; the diff refuses them before checking any pattern. `release.yml` calls this lane
as the `privacy` job and will not publish until it is green.

### 6. Install paste and Gatekeeper

The install line is short, plain ASCII and has no smart quotes. If Terminal asks
to confirm a paste, choose **Paste Anyway** or type it. The installer no longer
asks for sudo and no longer writes to `/Applications`; if macOS still refuses
the app it prints the exact `open`/Gatekeeper text. The public build remains
ad-hoc signed; a warning-free double-click for every Mac still needs Developer
ID signing and notarisation, which requires Emin's paid Apple Developer account.

## Known limits, stated plainly

- A no-warning first open on every Mac still needs Developer ID notarisation.
  This phase fixes the per-user install, quarantine handling, sandbox packaging
  and diagnostics, not the paid certificate.
- In-app removal uses the system Terminal once. That is deliberate: a sandboxed
  process cannot delete its own bundle/container, and no helper or privileged
  daemon is installed.
- The diff allowlist trusts Apple's own transient caches only; anything with
  `app.dot.local` in the path fails.
- The owner still has to grant microphone and screen-recording approvals on
  first use; those are TCC grants, not System Settings changes Dot asks for.

## Verification

Local portable gates on the Pi:

- `python3 -B scripts/check_contracts.py`: 83/83.
- Phase 7, 7b and 7s contracts: 18 tests, OK.
- Release-parts and review-pipeline contracts: 38 tests, OK.
- `bash -n` on every changed/new shell script: pass.
- YAML parse of all changed workflows: pass.
- Snapshot/diff fixture: clean tree passes; Apple transient passes; a
  Dot-owned leftover fails.

Hosted macOS gates:

- Release run
  [`39716661710`](https://github.com/Emin-dev/Dot/actions/runs/39716661710),
  **success**, commit `ae857da`, tag `v1.1.2`: `package`, `privacy / no-trace`,
  `installer-one-liner`, `quarantine-install`, `spctl-codesign` and `publish`
  all green. The release is public, not a draft, and Latest.
- Final no-trace run
  [`39722187295`](https://github.com/Emin-dev/Dot/actions/runs/39722187295),
  **success**, commit `de14804`: snapshot → install → entitlement + kernel
  self-check → real launch smoke test → uninstall → empty diff and no installer
  temp directory. The diff reported only the documented Apple/OS transient
  paths; zero `app.dot.local` or `Dot.app` paths remained after uninstall.
- Final native run
  [`39722187386`](https://github.com/Emin-dev/Dot/actions/runs/39722187386),
  **success**, same commit: `rust-gates`, `swift-test`, `dot-voice`, `macos`
  (including the full Python/XCTest/SwiftPM lane and zero-warning build).
- Earlier no-trace iterations exposed and removed real leftovers
  (`~/Library/Biome/sets/Default/App.Shortcut.Phrase/sourceIdentifier=app.dot.local`)
  and added only OS-owned Apple/runner paths to the allowlist. Those runs are
  retained in GitHub history; the green run above is the acceptance evidence.

## Owner test

Use [TEST_TODAY.md](TEST_TODAY.md): install line, sandbox/model/voice/offline/
screen/safety checks, then the uninstall line and the expected
`PASS: your Mac is back to how it was` output.
