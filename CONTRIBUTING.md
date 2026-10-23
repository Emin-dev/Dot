# Contributing

1. Read [docs/AI_HANDOFF.md](docs/AI_HANDOFF.md), [docs/OWNER_DECISIONS.md](docs/OWNER_DECISIONS.md)
   and [AGENTS.md](AGENTS.md).
2. Work on `main` only. Small commits, normal pushes, never force-push or delete branches.
3. Every change gets a test or a guardrail in `scripts/check_contracts.py`, and the docs it touches
   stay true.
4. Before pushing run `python3 -B -m unittest discover -s Tests/Python` and
   `python3 -B scripts/check_contracts.py`; macOS CI builds Swift and runs XCTest.
5. Do not change a decided behavior; ask Emin first (one question, numbered options) and record the
   answer in OWNER_DECISIONS.md.
