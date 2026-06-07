from reaper_toolkit import ClientIdentity, ReaperClient

client = ReaperClient(
    ClientIdentity("com.example.rptk-transport", "0.2.0", "RPTK Transport"),
    {"project.state", "transport.control"},
)
try:
    client.connect()
    client.set_transport(playing=True)
    input("Press Enter to stop Reaper...")
    client.set_transport(playing=False)
finally:
    client.close()

