# Python API

Both clients expose `connect`, `close`, `wait_until_ready`, `refresh_state`,
`set_transport`, `set_edit_cursor`, `capture_selected_track`, `resolve_track`,
`insert_midi_item`, `replace_midi_item`, `prepare_midi_preview`,
`update_midi_preview`, and `stop_midi_preview`.

UDP methods are `send_midi_event` and `reset_midi_generation`. Register
`on_status`, `on_state`, and `on_event` callbacks before connecting. Read
`last_status`, `last_state`, and `has_capability` at any time.

Public structured values are frozen dataclasses. Construct phrases with
`MidiPhrase.create(...)` to sort notes and calculate a canonical SHA-256
revision.

Command failures are structured exceptions with `code`, `message`,
`retryable`, `request_id`, `method`, and `details`.

