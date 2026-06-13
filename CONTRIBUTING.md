# Contributing

Open an issue before changing protocol schemas or stable identifiers. Keep
Python 3.11 compatibility, preserve concept-neutral APIs, and include tests for
behavior changes.

Run:

```bash
python -m pytest
RPTK_LUA=/path/to/lua python -m pytest -m lua_integration
python -m ruff check .
for file in reaper/*.lua; do lua -e "assert(loadfile('$file'))"; done
```

The Lua integration marker requires Lua 5.3+ with LuaSocket. Set `RPTK_LUA`
when the desired interpreter is not the first `lua` on `PATH`. Do not satisfy
this requirement by committing local LuaSocket binaries.

Live Reaper validation is excluded unless explicitly enabled:

```bash
RPTK_LIVE_REAPER=1 python -m pytest -m live_reaper
```

The live host defaults to `127.0.0.1:9901`; use `RPTK_LIVE_HOST` and
`RPTK_LIVE_TCP_PORT` to override it.

Reaper mutations also require the manual validation checklist. Do not commit
LuaSocket binaries without documented provenance, licensing, architecture,
checksums, and build method.
