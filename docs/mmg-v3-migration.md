# Metal MIDI Generator v3 Migration

MMG should add an adapter that converts rendered notes to `MidiPhrase`, maps
the MMG Drums fallback to `TrackRef`, renders `BridgeStatus`, and forwards the
MMG preview revision. Keep old and RPTK backends behind a development switch
until automated and manual parity pass.

The toolkit must not contain MMG session schemas, saved-groove metadata, or
drum-specific protocol fields. Remove MMG's copied host and receiver only after
the RPTK path is stable.

