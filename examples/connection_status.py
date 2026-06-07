from reaper_toolkit import ClientIdentity, ReaperClient

client = ReaperClient(
    ClientIdentity("com.example.rptk-status", "0.1.0", "RPTK Status"),
    {"project.state"},
)
client.on_status(lambda status: print(status.state.value, status.summary, status.detail))
try:
    client.connect()
    print(client.last_state)
finally:
    client.close()

