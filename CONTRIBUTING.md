# Contributing

Open an issue before changing protocol schemas or stable identifiers. Keep
Python 3.11 compatibility, preserve concept-neutral APIs, and include tests for
behavior changes.

Run:

```bash
python -m pytest
python -m ruff check .
for file in reaper/*.lua; do lua -e "assert(loadfile('$file'))"; done
```

Reaper mutations also require the manual validation checklist. Do not commit
LuaSocket binaries without documented provenance, licensing, architecture,
checksums, and build method.

