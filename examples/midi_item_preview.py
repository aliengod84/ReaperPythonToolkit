from reaper_toolkit import (
    ClientIdentity,
    MidiNote,
    MidiPhrase,
    PreviewOptions,
    ReaperClient,
    TrackCreate,
    TrackRef,
)

phrase = MidiPhrase.create(96, 384, [
    MidiNote(0, 24, 9, 36, 110),
    MidiNote(96, 24, 9, 38, 105),
])
client = ReaperClient(
    ClientIdentity("com.example.rptk-preview", "0.1.0", "RPTK Preview"),
    {"midi.preview", "track.resolve"},
)
try:
    client.connect()
    preview = client.prepare_midi_preview(
        TrackRef(name="RPTK Preview", create=TrackCreate.IF_MISSING),
        phrase,
        PreviewOptions(),
    )
    input("Press Enter to stop preview...")
    client.stop_midi_preview(preview.resource_id)
finally:
    client.close()
