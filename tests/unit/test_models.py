import pytest

from reaper_toolkit import (
    InsertOptions,
    MidiNote,
    MidiPhrase,
    PreviewState,
    ProjectState,
    ReplaceOptions,
)


def test_phrase_revision_is_canonical():
    notes = [MidiNote(120, 60, 9, 38, 90), MidiNote(0, 60, 9, 36, 100)]
    assert MidiPhrase.create(96, 384, notes) == MidiPhrase.create(96, 384, list(reversed(notes)))


def test_note_must_fit_phrase():
    with pytest.raises(ValueError):
        MidiPhrase.create(96, 100, [MidiNote(90, 20, 0, 60, 100)])


def test_protocol_11_models_parse_full_resource_and_preview_state():
    state = ProjectState.from_dict(
        {
            "state_seq": 1,
            "project_generation": "p1",
            "project": {
                "guid": "guid",
                "ppq": 960,
                "bpm": 120,
                "meter": {"numerator": 4, "denominator": 4},
                "playing": True,
                "recording": False,
                "repeat_enabled": False,
                "edit_cursor": {"seconds": 0, "ppq": 0},
                "play_cursor": {"seconds": 1, "ppq": 1920},
            },
            "resources": [
                {
                    "resource_id": "r1",
                    "kind": "midi_item",
                    "app_id": "com.example.app",
                    "target_guid": "target",
                    "track_guid": "layer",
                    "start_ppq": 960,
                    "length_ppq": 3840,
                    "metadata": {"schema": 3},
                }
            ],
            "preview": {
                "resource_id": "preview",
                "active": True,
                "status": "switch_pending",
                "origin_ppq": 3840,
                "phrase_length_ppq": 3840,
                "count_in": False,
                "count_in_start_ppq": 0,
                "pending_switch_ppq": 7680,
                "active_revision": "a",
                "pending_revision": "b",
            },
        }
    )
    assert state.resources[0].target_guid == "target"
    assert state.preview == PreviewState(
        resource_id="preview",
        active=True,
        active_revision="a",
        status="switch_pending",
        origin_ppq=3840,
        phrase_length_ppq=3840,
        count_in=False,
        count_in_start_ppq=0,
        pending_switch_ppq=7680,
        pending_revision="b",
    )
    assert InsertOptions(0, "layer", "end").collision_policy == "layer"
    assert ReplaceOptions("start").advance_cursor == "start"
