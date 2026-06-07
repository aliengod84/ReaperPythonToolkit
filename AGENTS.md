# Agent Context

Reaper Python Toolkit (`rptk`) is a framework-independent Python 3.11+ client
and Reaper Lua host for controlling Reaper over localhost.

Key locations:

- `README.md`: supported workflows, setup, and maturity.
- `docs/architecture.md`: component boundaries.
- `docs/protocol.md`: TCP and UDP protocol contracts.
- `docs/compatibility.md`: supported version combinations.
- `src/reaper_toolkit/`: Python package.
- `reaper/`: Reaper action and Lua host modules.
- `schemas/`: normative JSON schemas.
- `tests/`: unit, protocol, and loopback integration tests.

Local verification uses `python -m pytest`, `python -m ruff check .`, and a Lua
syntax check over `reaper/*.lua`.
