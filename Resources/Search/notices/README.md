# Search source-delta and notice inventory

The build-only `searxng-transient-cache.patch` modifies SearXNG's `searx/engines/duckduckgo.py` at exact source revision `22c64b8d394b680c7ea96be25f36dad14126420a`. Modification date: 2026-10-13. It turns `set_vqd` into a no-op for Dot's fixed page-one-only gateway so query-derived validation tokens are not saved in the engine SQLite cache. The modified function carries a prominent dated notice. No page-two support is claimed.

The original and patched file hashes and exact delta are in `searxng-transient-cache-patch.json`; the complete original source archive/hash is identified in `search-dependency-pins.json`. Preserve and distribute the corresponding original source, this delta, actual build scripts, notices and all applicable source offers with the completed helper. This source-only slice does not contain or certify an assembled binary distribution or complete transitive license closure.

- SearXNG: AGPL-3.0-or-later. Full pinned upstream LICENSE is preserved as SEARXNG-LICENSE.txt. Individual upstream files retain their copyright and SPDX notices in the corresponding source.
- Waitress 3.0.2: ZPL-2.1. Full wheel LICENSE is preserved as WAITRESS-LICENSE.txt. Its corresponding source archive contains accompanying copyright notices, including COPYRIGHT.txt, preserved as WAITRESS-COPYRIGHT.txt. Preserve both in the eventual runtime distribution.
- Python, OpenSSL, SearXNG transitive dependencies, certificates and native libraries: not yet selected/assembled/audited here. Their complete notices and source obligations remain mandatory release work.

Separate-process HTTP does not, by itself, decide whether the final distribution is a combined work. These notices are a provenance inventory, not a legal conclusion or permission to retain third-party search results.
