# What only Emin can provide

Everything else is decided; the answers are in [OWNER_DECISIONS.md](OWNER_DECISIONS.md) and are not
asked again. Settled defaults (change only with a new answer): logs are text only on `dot-logs`;
minimum M5 Pro class, 48 GB, macOS 27; the fixed Qwen3.8 27B Q4 model; British Kokoro voices with
Isabella as fallback; model parts hosted on the `model-parts-v1` release. The full earlier version
of this file is [archive/QUESTIONS_FOR_EMIN_FULL.md](archive/QUESTIONS_FOR_EMIN_FULL.md).

## 1. Log-upload token (needed for the first real upload)

**What is needed:** one GitHub fine-grained personal access token for `Emin-dev/Dot` with
**Contents: Read and write**. A classic token with `repo` also works. Do **not** send it in chat and
never commit it.

**Why:** Dot can already write `dot/<install-id>/<launch>/...` to the dedicated `dot-logs` branch,
with an offline queue and backoff. It reads the credential from Keychain service
`dot-github-token`, then falls back to `~/Library/Containers/app.dot.local/Data/Library/Application Support/Dot/github.token` (0600).
No token exists on this machine, so uploads stay queued and the app logs one honest line.
Requests that carry the token never follow a redirect, so it is only ever sent to `api.github.com`.

**Exact steps for Emin on the Mac:**

1. Create the token at <https://github.com/settings/personal-access-tokens> for `Emin-dev/Dot` with
   **Contents: Read and write** (or a classic token with `repo`).
2. Store it without printing it. `-w` comes last with no value, so `security` asks for the token
   itself (twice, input hidden) and it never appears on a command line, where `ps` could see it:

```bash
security add-generic-password -a "$USER" -s dot-github-token -U -w
```

   `bash scripts/store_github_token.sh` does the same and then checks the token with GitHub (it
   removes the item again if GitHub does not accept it).
3. Confirm only the service name is visible: `security find-generic-password -s dot-github-token`
   (it prints metadata, not the secret).
4. Restart Dot. `~/Library/Containers/app.dot.local/Data/Library/Application Support/Dot/Logs/dot-sync.log` should show one `[SYNC] text logs are uploading ...` line.

**Fallback if Keychain is unavailable:** write the token to
`~/Library/Containers/app.dot.local/Data/Library/Application Support/Dot/github.token` as a regular
file (not a symbolic link) that you own, with mode 0600 (`chmod 600`). Dot ignores the file
otherwise and writes one `[SYNC] ignored the fallback file ...` line to `dot-sync.log`, never its
contents. Dot redacts the token from logs.

**Recommended default while waiting:** keep queueing locally; never upload unauthenticated and never
create a token automatically.

## 2. Developer ID signing and notarisation (the one production blocker)

Today every release is ad-hoc signed and not notarised. It installs and runs through the one-line
installer, and every release gate (install, quarantine, `spctl`/`codesign`, no-trace) is green. A
double-click install with no warning on any Mac needs Developer ID signing plus notarisation.

What only Emin can provide (never created by an AI, per AGENTS.md):

1. A paid Apple Developer account and a **Developer ID Application** certificate exported as `.p12`.
2. An app-specific password (or App Store Connect API key) for `notarytool`, plus the team id.
3. These stored as repository secrets, for example `DEVELOPER_ID_P12_BASE64`,
   `DEVELOPER_ID_P12_PASSWORD`, `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD`.

The engineering step after that (found 2026-10-23): notarisation rejects any unsigned Mach-O file,
and the bundled Splash/Python runtime in `Contents/Resources/Offline` holds many. Signing them
changes their bytes, but `OfflinePayload` checks every runtime file against
`runtime-manifest.json` at launch. So the release must sign those binaries with the Developer ID and
the hardened runtime, then regenerate the manifest from the signed files (or have the manifest
record pre-signature hashes plus a `codesign --verify` check). Only then can `release.yml` run
`xcrun notarytool submit --wait` and `xcrun stapler staple` on `Dot.dmg`. This needs one real
notarised run to finish; it cannot be proved without the credentials.

## 3. All-in-one DMG (owner-run, optional)

The complete DMG is about 22 GB, so GitHub requires <2 GB parts. After the complete
installer exists and passes native acceptance:

```bash
DOT_ALL_IN_ONE_DMG=build-complete/Dot.dmg bash scripts/package_all_in_one.sh
```

This uploads `Dot.dmg.partNNN`, `Dot.dmg.parts.json`, `join-dot-dmg.command` and
`join_release.py` to the `all-in-one-v1` release. Users double-click the command; it
downloads missing parts, verifies every part and the joined DMG, then opens it.

## 4. Not decided yet

Ask one at a time with 2 to 4 numbered options, then record the answer in OWNER_DECISIONS.md.

- R4 voice upgrade: evaluate Chatterbox or Orpheus against Kokoro, or keep Kokoro.
- R9 self-modification: a writable plugin layer with snapshots, self-test, rollback and a Rust
  watcher, or not at all.
- Personality between turns: idle animations, small reactions, mood.
- From [AUDIT_2026-10-23.md](AUDIT_2026-10-23.md), in order of value (N3 answered: R25):
  - S1: approval card for typing, keys and clicks when a turn carries page or screen text.
  - N5, N7, N10: search, page fetching and the Splash link on Apple frameworks instead of Rust and
    Python helpers.
  - S3: whether proactive comments about the screen are logged in full or masked.
  - D9: remove the old `dots/` per-install logs from the public repository.
  - S9, N12, S10: an XPC helper for the runtime, Data Protection Keychain, a logs-only token (all
    after Developer ID signing).
