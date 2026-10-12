# Bounded English voice constraint candidate

Status: UNVERIFIED FULL CLOSURE / ABI / ARTIFACT / IMPORTS. This is not a release lock and does not resume the canceled recursive metadata resolver.

The known conflict is spaCy 3.8.16 requiring Thinc >=8.3.12,<8.4 while the newer curated transformer plugin requires Thinc 9. The official 0.3.1 plugin source requires curated-transformers >=0.1,<0.2, curated-tokenizers >=0.0.9,<0.1 and torch >=1.12. Its development requirements target spaCy >=3.7.dev0,<4 and Thinc >=8.1.6,<9.1. The proposed three exact constraints intersect the known spaCy branch, preserving Kokoro/Misaki0.9.4, bf_isabella and all 14 Bionic direct pins.

Sources:
- https://github.com/explosion/spacy-curated-transformers/blob/release-v0.3.1/setup.cfg
- https://github.com/explosion/spacy-curated-transformers/blob/release-v0.3.1/requirements.txt
- https://github.com/explosion/curated-transformers/blob/v0.1.1/setup.cfg
- https://github.com/explosion/curated-tokenizers/blob/v0.0.9/setup.cfg

The publisher file listing for curated-tokenizers0.0.9 reports a cp311-cp311-macosx_11_0_arm64 wheel with expected SHA256 2d1fef3e861df50bd6337364a87f447fbd0a6f01c095cec121b7404d15512138: https://pypi.org/project/curated-tokenizers/0.0.9/#files . The artifact has not been downloaded, independently hashed, linked or imported by this change. A platform tag is not proof of native ABI compatibility.

Next narrowly scoped validation, when authorized: read only the three exact version metadata records (spacy-curated-transformers/0.3.1, curated-transformers/0.1.1, curated-tokenizers/0.0.9) and their selected wheel metadata. Confirm published Requires-Dist, exact filenames/URLs/SHA256/size and complete licenses against the tagged source. Do not recursively traverse other packages, install or execute anything in that step. Record any newly unresolved dependencies instead of claiming closure.

Then, separately, a complete reviewed artifact plan is needed for the isolated CPython3.11 environment, followed by offline distribution-metadata checks, spaCy tok2vec/tagger load, eSpeak initialization and genuine local Kokoro synthesis. The canceled resolver remains stopped. Splash's incompatible Python package environment must not be merged into the voice runtime.
