# Reaper Python Toolkit Context

Reaper Python Toolkit (`rptk`) is a framework-independent Python 3.11+ client
and Reaper Lua host for controlling Reaper over localhost.

Read these before changing behavior:

- `README.md` for supported workflows and maturity.
- `docs/architecture.md` for component boundaries.
- `docs/protocol.md` for the normative TCP and UDP contracts.
- `docs/compatibility.md` for version compatibility.

The Python package is under `src/reaper_toolkit/`. The Reaper action and host
modules are under `reaper/`. JSON schemas are normative and live in `schemas/`.
Run `python -m pytest` and `python -m ruff check .` before committing.

