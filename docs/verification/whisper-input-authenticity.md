# Whisper archive input authenticity

The complete build now requires `DOT_WHISPER_ARCHIVE`, pointing to the local
`whisper-v1.7.6-xcframework.zip`. It does not download the archive or accept a
`DOT_WHISPER_FRAMEWORK` directory as authority.

`scripts/verify_whisper_input.py` reads the repository-owned pin from
`packaging/voice-source-manifest.json`: 41,291,976 bytes and SHA-256
`9fcb28106d0b94a525e59bec057e35b57033195ac7408d7e1ab8e4b597cdfeb5`.
The source file and verifier must be tracked in the clean build snapshot. The
CLI exposes no alternate manifest, expected hash or disabled-verification option.

The verifier opens a bounded regular archive without following its final
symlink, reads detached bytes once, and checks size/hash before parsing. It
reads the XCFramework's authenticated `Info.plist`, selects exactly one macOS
library containing arm64, and derives that library's `whisper.framework`.
No archive member is used as a filesystem extraction command. Invalid,
duplicate, Unicode/case-aliased, special-file and oversized entries fail closed.
Framework links must be relative, non-cyclic, non-dangling and confined to the
selected subtree. Entries beneath a link cannot redirect writes. Files and
directories are written before links, into a new private build staging folder,
and the staged bytes, links, modes and closed inventory are rechecked.

The compiler's `-F` path and the copied framework both come from this staging
folder. A separate supplied framework is never used. The existing framework
signing and final embedded-binary hash remain. Provenance additionally records
the authenticated archive hash/size, source manifest hash, selected library
identifier and canonical pre-signing framework closure hash. Signing changes
binary bytes, so that input closure hash is deliberately distinct from the final
embedded-binary digest.

This gate trusts the clean source and build workspace. It detects substituted
external build inputs relative to the existing source pin. It does not defend
against an owner process actively altering trusted source/staging/tooling, nor
does it supply a new publisher certificate policy or assess the pinned version's
current security suitability or licensing.

## Verification

Run `python3 -B -m unittest discover -s Tests/Python -p test_whisper_input.py -v`.
Tests use tiny ZIP fixtures with explicit test-only pins through a private Python
seam; the production CLI always loads the repository pin. They exercise exact
byte authentication, malicious self-consistent replacement, archive selection,
contained versioned framework links, traversal/alias/type/link failures, fresh
output, detached-byte parsing, and actual build metadata generation.

Fixture tests are not proof that the actual upstream archive layout or native
framework is compatible. Before complete-build acceptance, provide the exact
pinned archive locally and run the verifier, real arm64 link, nested/outer
signature checks, and relocation/load checks on the supported macOS target.

This is partial remediation of executable-input authenticity. The final
Splash/Voice runtime closure still needs an independently approved lock; its
self-manifest is insufficient. Cached runtime/model path verification and the
later native launch/consumption race remain separate open issues. No security
finding or complete-app release gate is closed by this change alone.
