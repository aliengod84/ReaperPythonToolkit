import time

from reaper_toolkit import ClientIdentity, ReaperClient

client = ReaperClient(
    ClientIdentity("com.example.rptk-audition", "0.1.0", "RPTK Audition"),
    {"midi.udp_audition"},
)
try:
    client.connect()
    client.send_midi_event(0x90, 60, 100)
    time.sleep(0.25)
    client.send_midi_event(0x80, 60, 0)
    client.reset_midi_generation()
finally:
    client.close()

