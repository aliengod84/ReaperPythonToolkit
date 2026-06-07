# Troubleshooting

- **Wrong/old host:** stop the process on TCP 9901 and run this repository's
  `rptk_host.lua`.
- **Port conflict:** stop the old host or application using TCP 9901/UDP 9900.
- **Missing LuaSocket:** install LuaSocket for Reaper's Lua and architecture.
- **Stale heartbeat/lease expiry:** keep the Python dispatcher running; inspect
  blocking callbacks and Reaper's defer loop.
- **Command timeout:** check the Reaper console for `[RPTK]` errors.
- **UDP unavailable:** precise MIDI item preview still works over TCP.
- **Repeat/metronome changed:** stop the host cleanly; startup restores stale
  setting leases recorded in project ExtState.

