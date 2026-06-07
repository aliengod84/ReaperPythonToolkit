# Quickstart

Start `rptk_host.lua` in Reaper, then run:

```bash
python examples/connection_status.py
```

Applications should require only capabilities they need. A TCP connection is
not readiness: enable Reaper controls only when `client.last_status.ready` is
true and the relevant `has_capability()` check succeeds.

Use `AsyncReaperClient` in asyncio applications. Use `ReaperClient` elsewhere;
it maintains one worker loop and does not call `asyncio.run()` per command.

