# Manual Reaper Validation

Release `0.2.0` automated tests were completed on 2026-06-07. The checks below
require a live Reaper installation and remain unrecorded until run there.

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
