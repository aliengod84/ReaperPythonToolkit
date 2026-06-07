# Reaper Python Toolkit

Reaper Python Toolkit (`rptk`) is a reusable bridge between ordinary Python
applications and [Reaper](https://www.reaper.fm/). One Reaper Lua action serves
multiple local Python clients with project state, transport control, track
resolution, MIDI item workflows, synchronized temporary previews, and
low-latency MIDI audition.

> **Maturity:** `0.1.0` incubation release. Protocol 1.0 is frozen, but Python
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
action list > ReaScript: Load** to load `rptk_host.lua`. Run that one action.
Run it again to request a clean stop.

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
        ClientIdentity("com.example.transport", "0.1.0", "Transport Example"),
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

Headless CI uses a loopback fake host. Reaper behavior must also pass
[the manual checklist](docs/manual-reaper-validation.md).

License: MIT.
