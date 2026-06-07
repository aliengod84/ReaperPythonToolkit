# Changelog

## 0.2.0 - 2026-06-07

- Added protocol 1.1 persistent app/role track bindings and durable resource discovery.
- Added atomic layered MIDI insertion, cursor advancement, undo labels, and exact replacement.
- Completed count-in/live-revision preview state, loop/timebase behavior, seek cleanup,
  and exact Repeat/metronome restoration.
- Added nonblocking synchronous-client startup with initial reconnect.
- Added typed resource/preview models, per-command timeouts, and ordered thread-safe UDP sends.
- Added Lua host-module tests and MMG v3 migration coverage.

## 0.1.0 - 2026-06-07

- Added protocol 1.0 TCP handshake, requests, responses, events, and schemas.
- Added async and persistent-worker synchronous Python clients.
- Added immutable status/project/track/MIDI/preview models.
- Added multi-client Reaper Lua host, MIDI items, preview ownership, and UDP audition.
- Added loopback integration tests, examples, and public documentation.
