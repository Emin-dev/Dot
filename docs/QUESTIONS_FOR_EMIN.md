# Questions for Emin

Answers are not blocking where a safe default is stated; Dot proceeds with the default and the
default stays easy to change.

## 1. Log-upload token (blocking the first real upload)

**What is needed:** one GitHub fine-grained personal access token for `Emin-dev/Dot` with
**Contents: Read and write**. A classic token with `repo` also works. Do **not** send it in chat and
never commit it.

**Why:** Dot can already write `dot/<install-id>/<launch>/...` to the dedicated `dot-logs` branch,
with an offline queue and backoff. It reads the credential from Keychain service
`dot-github-token`, then falls back to `~/Library/Containers/app.dot.local/Data/Library/Application Support/Dot/github.token` (0600).
No token exists on this machine, so uploads stay queued and the app logs one honest line.

**Exact steps for Emin on the Mac:**

1. Create the token at <https://github.com/settings/personal-access-tokens> for `Emin-dev/Dot` with
   **Contents: Read and write** (or a classic token with `repo`).
2. Store it without printing it:

```bash
read -rsp "Paste GitHub token: " TOKEN; echo
security add-generic-password -a "$USER" -s dot-github-token -w "$TOKEN" -U
unset TOKEN
```

3. Confirm only the service name is visible: `security find-generic-password -s dot-github-token`
   (it prints metadata, not the secret).
4. Restart Dot. `~/Library/Containers/app.dot.local/Data/Library/Application Support/Dot/Logs/dot-sync.log` should show one `[SYNC] text logs are uploading ...` line.

**Fallback if Keychain is unavailable:** write the token to
`~/Library/Containers/app.dot.local/Data/Library/Application Support/Dot/github.token` with mode 0600. Dot redacts it from logs.

**Recommended default while waiting:** keep queueing locally; never upload unauthenticated and never
create a token automatically.

## 2. Log scope

**Recommended default (implemented):** full user and Dot conversation text, tool outcomes, app and
system events, health snapshots and launch metadata. No images, screenshots, audio, microphone
captures or the memory database. Screenshots only as OCR line counts/short anonymized descriptions.

Change by editing `src/DotLogSync.swift` (+ tests) if a narrower scope is wanted.

## 3. Logs branch and layout

**Recommended default (implemented):** branch `dot-logs`; path
`dot/<16-char-anonymous-install-id>/<YYYY-MM-DDTHH-MM-SSZ>/`; one new folder per launch; 2 MB
rotation with one rotated file; offline queue capped at 64 entries with 8 exponential attempts,
then at most one retry per hour while the entry stays queued.

Change by editing `LogSyncPolicy` in `src/InteractionCore.swift` (+ tests).

## 4. Hardware minimum

**Recommended default (implemented):** refuse to launch below Apple Silicon M5 Pro class, 48 GB
Unified Memory or macOS 27 with one clear blocking message. The exact Qwen3.8 27B Q4 Splash model has
no smaller fallback.

Change by editing `HardwareCompatibility` in `src/InteractionCore.swift` (+ tests).

## 5. Model

**Recommended default (implemented):** exactly `mlx-community/Qwen3.8-27B-4bit` on Splash. No
smaller replacement and no automatic substitution. The separate Gemma-3-4B safety approver remains
the only auxiliary model and never answers conversations.

## 6. Main branch protection

`main` is protected with a pull-request requirement (no force-push, no deletion). Administrators can
still merge directly, which keeps the current single-owner workflow possible. The logs token only
needs the unprotected `dot-logs` branch.

## 7. Voice list

**Recommended default (implemented):** every bundled British Kokoro voice is accepted; a missing
selected voice falls back to the bundled `bf_isabella` with an honest log line. No cloud TTS.

## 8. Model part hosting (no longer owner-gated)

**Resolved by the `Publish model parts` workflow** (`.github/workflows/model-parts.yml`,
`workflow_dispatch`). It needs nothing from Emin: it uses the built-in `GITHUB_TOKEN`,
fetches the pinned Qwen3.8 27B Q4 files from their official public repositories,
verifies every file against `Resources/bundled-models.json`, splits them into
<2 GB parts and uploads the parts plus `model-parts.json` to the `model-parts-v1`
release. The release workflow then bundles that plan into `Dot.dmg`, so the app's
primary route is the pinned Emin-dev/Dot parts; revision-pinned Hugging Face files
remain the hash-checked fallback.

The workflow streams one file at a time, so it fits a hosted runner (~6 GB peak,
22.4 GB total transfer) and refuses to replace an existing release. The manual route
below is kept only for a deliberate re-split:

```bash
python3 scripts/model_parts.py --models "$HOME/Applications/Dot.app/Contents/Resources/OfflineModels" \
  --output build-parts --tag model-parts-v1
# upload every build-parts/*.partNNN plus build-parts/model-parts.json by hand
cp build-parts/model-parts.json Resources/model-parts.json
```

## 9. All-in-one installer parts (owner-run, after complete acceptance)

The complete DMG is about 22 GB, so GitHub requires <2 GB parts. After the complete
installer exists and passes native acceptance:

```bash
DOT_ALL_IN_ONE_DMG=build-complete/Dot.dmg bash scripts/package_all_in_one.sh
```

This uploads `Dot.dmg.partNNN`, `Dot.dmg.parts.json`, `join-dot-dmg.command` and
`join_release.py` to the `all-in-one-v1` release. Users double-click the command; it
downloads missing parts, verifies every part and the joined DMG, then opens it.

## 10. Signing / notarization for a fully public DMG

The CI release DMG is ad-hoc signed and not notarized because the repository has no
Developer ID certificate or notarization credential. Publishing a Gatekeeper-clean app
needs Emin's Apple Developer account (`SIGN_IDENTITY`, `notarytool` credentials). The
current release notes say this explicitly rather than claiming a distributable build.
