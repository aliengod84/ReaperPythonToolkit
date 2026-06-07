# Architecture

`AsyncReaperClient` owns an asyncio TCP stream and a UDP sender. `ReaperClient`
runs one persistent asyncio loop on a worker thread and delegates to the same
implementation. Callbacks run on the owning client dispatcher; GUI adapters
must post them to their UI event loop.

In Reaper, `rptk_host.lua` is the lifecycle action. `rptk_host_core.lua` polls
nonblocking sockets on each deferred callback and serializes all Reaper API
work on that thread. Protocol, sessions, project state, tracks, MIDI items,
preview, and UDP are separate Lua modules.

TCP is authoritative. UDP packets are disposable and can only address the
session associated with their negotiated random token.

