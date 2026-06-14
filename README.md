# Reaper Python Toolkit

Reaper Python Toolkit (`rptk`) is a reusable bridge between ordinary Python
applications and [Reaper](https://www.reaper.fm/). One Reaper Lua action serves
multiple local Python clients with project state, transport control, track
resolution, MIDI item workflows, synchronized temporary previews, and
low-latency MIDI audition.

> **Maturity:** `0.2.0` incubation release. Protocol 1.1 is frozen, but Python
> APIs may change between 0.x minor releases. Reaper 7 on Windows is the first
> validation target.

## Architecture

- Newline-delimited JSON over localhost TCP for reliable commands and state.
- A versioned binary localhost UDP channel for disposable MIDI audition.
- Precise synchronized playback uses temporary Reaper MIDI items.
- Every client has a leased session; temporary resources are isolated and
  removed when that lease ends.
- The Python package has no GUI dependency. Status and state are immutable
  dataclasses suitable for any event loop.

## Installation

```bash
python -m pip install -e C:\Github\ReaperPythonToolkit
```

Install LuaSocket for the Lua version embedded in Reaper. Copy the complete
`reaper/` directory into Reaper's Scripts directory, then use **Actions > Show
action list > ReaScript: Load** to load `rptk_host.lua`. Run that action to
start or stop the host. Load `rptk_host_reload.lua` as a second action when
developing the host; it requests a clean stop, waits for the TCP/UDP sockets to
be released, then reloads `rptk_host.lua` without restarting REAPER.

Transport state snapshots intentionally omit durable resource lists. Use
`resource.list` for item discovery and metadata; this keeps 10 Hz play-position
updates small regardless of how many tagged MIDI items exist in the project.
Transport snapshots use a small bounded per-client output allowance. This avoids
both unbounded phase history and starvation when heartbeat replies briefly keep
the non-blocking socket busy.

The repository intentionally does not bundle LuaSocket binaries. The host does
support a project-local `reaper/lua/` directory, matching the layout previously
used by Metal MIDI Generator v3. See
[installation](docs/installation.md) for the exact files.

## Five-Minute Example

```python
import asyncio
from reaper_toolkit import AsyncReaperClient, ClientIdentity

async def main():
    client = AsyncReaperClient(
        ClientIdentity("com.example.transport", "0.2.0", "Transport Example"),
        {"project.state", "transport.control"},
    )
    await client.connect()
    print(client.last_status.summary, client.last_state.project.bpm)
    await client.set_transport(playing=True)
    await asyncio.sleep(1)
    await client.set_transport(playing=False)
    await client.close()

asyncio.run(main())
```

See [quickstart](docs/quickstart.md), [Python API](docs/python-api.md), and the
[`examples/`](examples/) directory.

## Supported Workflows

- Project tempo, meter, cursor, transport, Repeat, session, and resource state.
- Desired-state transport and cursor commands.
- Selected-track capture and GUID/name/create-based track resolution.
- Durable MIDI item insertion and exact owned-resource replacement.
- Count-in synchronized MIDI preview with revision updates and cleanup.
- Session-tokenized UDP MIDI generations and all-notes-off reset.
- Sync and async Python clients with status/state/event callbacks.

UDP MIDI is approximate because ReaScript runs in a deferred loop. Use MIDI
item preview for timing-critical synchronized playback.

## Development

```bash
python -m pip install -e '.[test]'
python -m pytest
python -m ruff check .
```

The default suite includes Python fake-host tests and Lua module tests. The
cross-language suite runs the production Lua host core in a subprocess and
connects the real Python client over TCP and UDP:

```bash
RPTK_LUA=/path/to/lua python -m pytest -m lua_integration
```

`RPTK_LUA` must select Lua 5.3+ with LuaSocket. If `lua` on `PATH` meets those
requirements, the variable is optional. The tests skip with an actionable
message when that runtime is unavailable.

Tests against an actual Reaper process are intentionally opt-in:

```bash
RPTK_LIVE_REAPER=1 python -m pytest -m live_reaper
```

Start `rptk_host.lua` in Reaper first. Override `RPTK_LIVE_HOST` and
`RPTK_LIVE_TCP_PORT` when the host is not at `127.0.0.1:9901`. See
[the manual validation guide](docs/manual-reaper-validation.md) for side
effects and the remaining manual checks.

License: MIT.
