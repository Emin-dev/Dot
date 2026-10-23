# Phase 7b result — Gatekeeper one-line install

> **Superseded install path (Phase 7s, 2026-10-22):** Dot now installs per-user
to `~/Applications`, never `/Applications` and never with sudo, and runs in the
Apple App Sandbox. The `/Applications` and sudo details below are historical
for `v1.1.1`; use `docs/TEST_TODAY.md` and `docs/PHASE7S_RESULT.md` for the
current install/remove commands.

**Status 2026-10-22:** release
[**`v1.1.1`**](https://github.com/Emin-dev/Dot/releases/tag/v1.1.1) is published
and **Latest**. Every acceptance job is green in run
[`39685174351`](https://github.com/Emin-dev/Dot/actions/runs/39685174351).

```bash
curl -fsSL https://github.com/Emin-dev/Dot/releases/latest/download/install-dot.sh | bash
```

## Root cause

Release `public-f6cc73d` (18 Oct) opened on Emin's MacBook because it was built
and signed on that Mac with Emin's **Apple Development** identity. Since 21 Oct
the CI releases are only **ad-hoc** signed, so Gatekeeper rejects the downloaded
app. Release `v1.1.0` is one of those ad-hoc builds. Right-click → Open does not
work on this macOS, so the fix is to remove the quarantine safely in the
installer rather than asking the owner to click a dialog that is not offered.

## What shipped

### One-line installer (repo and release asset)

[`scripts/install-dot.sh`](../scripts/install-dot.sh) is the first line of
`README.txt`, `docs/TEST_TODAY.md` and the release notes. It:

- downloads `Dot.dmg` with curl (curl adds no `com.apple.quarantine`);
- supports split releases: downloads every `Dot.dmg.partNNN` listed in
  `Dot.dmg.parts.sha256`, checks each part, then joins them;
- verifies the whole DMG SHA-256 against the published `Dot.dmg.sha256`;
- mounts the DMG, copies `Dot.app` to `/Applications`, clears quarantine,
  runs `codesign --verify --deep --strict`, detaches and opens Dot;
- prints one `PASS:` or `FAIL:` line per step;
- is idempotent and safe to re-run; uses sudo only when `/Applications` is not
  writable (non-interactive when possible).

### Local Apple Development path

[`scripts/build-and-sign-on-mac.sh`](../scripts/build-and-sign-on-mac.sh) is the
owner fallback. It builds Dot on the Mac (Xcode/SwiftPM plus the Rust runtime),
takes the first identity from
`security find-identity -v -p codesigning` that starts with `Apple Development`
(ad-hoc fallback when none exists), installs to `/Applications`, verifies the
signature and opens Dot. It reuses an existing complete local payload when one
is present. This is not a public-release path: an Apple Development signature is
trusted only on the Mac that owns the certificate.

### Docs

- `README.txt` (release asset) and `docs/TEST_TODAY.md` start with the exact
  Terminal line.
- The fallback is stated plainly: **System Settings → Privacy & Security → Open
  Anyway**, or `xattr -dr com.apple.quarantine /Applications/Dot.app`.
- The docs state that a no-warning double-click for every Mac needs **Developer
  ID signing plus notarisation**, which needs Emin's paid Apple Developer account
  and is owner-only.

## CI acceptance

The release is created as a **draft** and only flipped to published/Latest by a
`publish` job that needs all three independent macOS acceptance jobs.

Run [`39685174351`](https://github.com/Emin-dev/Dot/actions/runs/39685174351),
**success**, commit `b765892`:

| Job | Evidence |
| --- | --- |
| `installer-one-liner` | ran the exact `curl -fsSL "$DOT_RELEASE_BASE/install-dot.sh" \| bash` shape against the draft assets; Dot launched and was **still running after 60 s** |
| `quarantine-install` | set `com.apple.quarantine` on the downloaded DMG (`0081;<hex>;Safari;`), ran the installer; both the DMG and `/Applications/Dot.app` had **no quarantine** afterwards; Dot was **still running after 60 s** |
| `spctl-codesign` | `codesign --verify --deep --strict` passed; `spctl --assess -vv /Applications/Dot.app` recorded `rejected` for `origin=Apple Development: Emin Ismayilov (7M2G5ULAUF)` in the job summary, which is expected until notarisation |
| `publish` | flipped the draft to `--draft=false --latest` only after the three jobs above were green |

The first gate run ([`39682500218`](https://github.com/Emin-dev/Dot/actions/runs/39682500218))
had all three acceptance jobs green but the publish job failed because `gh` had
no checkout to infer the repository. Fixed once (`b765892`) by setting
`GH_REPO`; the rerun above is fully green. No acceptance result changed.

## Release evidence

- Release: <https://github.com/Emin-dev/Dot/releases/tag/v1.1.1> (**Latest**).
- `Dot.dmg` **793,667,072 bytes**, SHA-256
  `0a409a17626a0d8897d574c67d9cd631b23a14d9eb20d75d45fd44e36104c61a`.
  The published `Dot.dmg.sha256` matches the checksum printed by the CI
  installer.
- Assets: `Dot.dmg`, `Dot.dmg.sha256`, `install-dot.sh`,
  `build-and-sign-on-mac.sh`, `README.txt`, `TEST_TODAY.md`, `model-parts.json`
  + `.sha256`, `join-dot-dmg.command`, `join_release.py`.
- First line of the release notes is the one Terminal command above.
- The downloaded `install-dot.sh` asset matches `scripts/install-dot.sh`
  byte-for-byte (SHA-256
  `ea16866abdbcf887fb4c3322c6db15d69291c9cc5ad7552f37b1462c16014dbe`).

## Gates

- `python3 -B scripts/check_contracts.py`: **76/76**.
- New `Tests/Python/test_phase7b_contract.py` (one-line docs, installer checks,
  local signing fallback, draft/publish gating) plus the existing Phase 7,
  release-parts and review-pipeline contracts: pass.
- `bash -n` on the installer, local signing script, acceptance helper and the
  existing release scripts: pass.
- CI `Native companion checks` run
  [`39680317356`](https://github.com/Emin-dev/Dot/actions/runs/39680317356) at
  `1dc21ef` is green in all four jobs.

## What still needs Emin

A no-warning double-click for every Mac still needs **Developer ID signing and
notarisation** with the paid Apple Developer account, which is owner-only. Until
then the one-line installer removes quarantine for him and prints a clear
`PASS`/`FAIL`; the alternative is `scripts/build-and-sign-on-mac.sh` on his own
Mac.
