import pytest

from reaper_toolkit import MidiNote, MidiPhrase


def test_phrase_revision_is_canonical():
    notes = [MidiNote(120, 60, 9, 38, 90), MidiNote(0, 60, 9, 36, 100)]
    assert MidiPhrase.create(96, 384, notes) == MidiPhrase.create(96, 384, list(reversed(notes)))


def test_note_must_fit_phrase():
    with pytest.raises(ValueError):
        MidiPhrase.create(96, 100, [MidiNote(90, 20, 0, 60, 100)])
