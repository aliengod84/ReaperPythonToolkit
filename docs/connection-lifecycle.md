# Connection Lifecycle

```text
DISCONNECTED -> CONNECTING -> HANDSHAKING -> SYNCING_STATE -> READY
                                      |             |
                                      v             v
                                INCOMPATIBLE      ERROR
READY -> DEGRADED -> RECONNECTING -> CONNECTING
READY -> CLOSING -> DISCONNECTED
```

The client sends a session heartbeat every second. Three seconds without host
traffic marks state stale and status degraded. Five seconds closes the socket.
Reconnect delays are 0.25, 0.5, 1, 2, then 5 seconds. Commands are never
replayed into a new session.

GUI mapping: disconnected/connecting is gray or blue; ready is green; degraded
or reconnecting is amber; incompatible/error is red.

