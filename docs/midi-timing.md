# MIDI Timing

Phrase positions use source PPQ and are scaled to the Reaper project's PPQ.
Phrase revisions are opaque lowercase SHA-256 identities.

UDP delay is relative to host receipt and is serviced by Reaper's deferred
ReaScript loop. It is suitable for note audition and approximate Sync-off
playback, not sample-accurate output.

Synchronized preview creates beat-attached temporary MIDI items. A mid-measure
cursor starts count-in at the next measure; content begins one native measure
later. Live updates are staged at a complete measure boundary at least 250 ms
ahead.

