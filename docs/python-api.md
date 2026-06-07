# Python API

Both clients expose `connect`, `close`, `wait_until_ready`, `refresh_state`,
`set_transport`, `set_edit_cursor`, `capture_selected_track`, `resolve_track`,
`resolve_bound_track`, `clear_track_binding`, `list_resources`,
`insert_midi_item`, `replace_midi_item`, `prepare_midi_preview`,
`update_midi_preview`, and `stop_midi_preview`.

The synchronous `ReaperClient.start()` begins initial connection/reconnect on
its persistent worker and returns immediately. `connect()` remains blocking for
scripts. Public command methods accept an explicit `timeout`.

UDP methods are `send_midi_event` and `reset_midi_generation`. Register
`on_status`, `on_state`, and `on_event` callbacks before connecting. Read
`last_status`, `last_state`, and `has_capability` at any time.

Public structured values are frozen dataclasses. Construct phrases with
`MidiPhrase.create(...)` to sort notes and calculate a canonical SHA-256
revision.

Use `InsertOptions` for exact start PPQ, collision policy, cursor advancement,
and undo label. Use `ReplaceOptions` for cursor advancement and undo label.
`ProjectState.resources` contains typed `ResourceState` values and
`ProjectState.preview` carries the active session preview state.

Command failures are structured exceptions with `code`, `message`,
`retryable`, `request_id`, `method`, and `details`.
