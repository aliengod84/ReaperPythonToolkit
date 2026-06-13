# Manual Reaper Validation

Release `0.2.0` automated tests were completed on 2026-06-07. The checks below
require a live Reaper installation and remain unrecorded until run there.

## Automated Live Smoke Tests

Start the installed `rptk_host.lua` action, then run:

```bash
RPTK_LIVE_REAPER=1 python -m pytest -m live_reaper
```

Optional endpoint variables are `RPTK_LIVE_HOST` and `RPTK_LIVE_TCP_PORT`.
Without `RPTK_LIVE_REAPER=1`, these tests are skipped and cannot accidentally
mutate an open project.

The fixture restores the original edit cursor and playing state. Preview
cleanup restores Repeat and metronome settings. The workflow test creates or
reuses a track named `RPTK Integration Test` and leaves one tagged durable MIDI
resource because protocol 1.1 has no public delete-resource command. Run live
validation in a disposable project or remove that item afterward.

Do not record a successful live validation result here unless the command was
actually run against Reaper. The headless `lua_integration` marker is not a
substitute for this step.

## Remaining Manual Checks

- Install and clean-upgrade the action.
- Connect two clients and verify independent READY/session IDs.
- Read transport state, move cursor, play, stop, disconnect, and reconnect.
- Capture, resolve, and create tracks with GUID/name precedence.
- Insert and exact-replace durable MIDI items for differently named concepts.
- Audition two UDP sessions and reset one without cancelling the other.
- Preview in 4/4, 3/4, 6/8, and 7/8 with count-in.
- Stage a live revision and verify the reported revision after the boundary.
- Verify cleanup after stop, seek, disconnect, action stop, and Reaper restart.
- Verify exact Repeat and metronome restoration.
