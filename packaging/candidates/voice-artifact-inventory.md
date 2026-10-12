# Remaining bundled voice artifacts

This inventory uses already saved metadata only. It is not a dependency lock and does not rerun the canceled resolver.

- 14 exact Bionic direct pins remain to acquire and verify; 13 have saved expected hashes, 12 lack retained download URLs.
- The three constrained curated wheels were downloaded and verified (967,246 bytes total); imports and their complete license/source closure remain unverified.
- 33 distinct first-hop packages have ranges but no selected artifact in the saved inputs.
- en_core_web_sm 3.8.0 still needs actual wheel verification against its saved publisher hash.
- eSpeak NG and embedded SentencePiece corresponding-source/notice gaps remain release gates.

## Next finite action
Read exactly the 14 official PyPI version-metadata URLs in voice-artifact-inventory.json, with a 2 MiB response cap and 28 MiB aggregate cap. Recover exact URLs and Requires-Dist, verify existing expected hashes, and fill the missing huggingface-hub artifact. No dependency recursion, installation, execution, or speculative version selection. This proposed step has not run.

## Unselected first-hop names
addict, attrs, catalogue, click, confection, cymem, dlinfo, docopt, filelock, fsspec, hf-xet, httpx2, jinja2, joblib, murmurhash, networkx, packaging, preshed, pydantic, pyyaml, requests, segments, setuptools, spacy-legacy, spacy-loggers, srsly, sympy, thinc, tqdm, typer, typing-extensions, wasabi, weasel

Then select and inspect an explicitly enumerated compatible batch. Real offline import and neural synthesis tests remain mandatory; metadata compatibility alone does not establish a working voice runtime.
