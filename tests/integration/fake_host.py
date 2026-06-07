from __future__ import annotations

import asyncio
import json
from typing import Any

CAPABILITIES = {
    "project.state", "transport.read", "transport.control", "track.read",
    "track.resolve", "track.capture_selection", "midi.item", "midi.preview",
    "midi.udp_audition", "settings.repeat_guard", "settings.metronome_guard",
    "session.multi_client", "track.binding", "resource.read",
}


def state(seq: int = 1) -> dict[str, Any]:
    return {
        "state_seq": seq, "project_generation": "fake-project",
        "project": {
            "guid": "fake-guid", "ppq": 960, "bpm": 120.0,
            "meter": {"numerator": 4, "denominator": 4},
            "playing": False, "recording": False, "repeat_enabled": False,
            "edit_cursor": {"seconds": 0.0, "ppq": 0},
            "play_cursor": {"seconds": 0.0, "ppq": 0},
        },
        "sessions": [], "resources": [],
    }


class FakeHost:
    def __init__(
        self,
        *,
        command_delay: float = 0.0,
        slow_methods: set[str] | None = None,
        emit_host_heartbeats: bool = False,
        heartbeat_interval_ms: int = 100,
        lease_timeout_ms: int = 5000,
        answer_session_heartbeat: bool = True,
    ) -> None:
        self.server: asyncio.Server | None = None
        self.port = 0
        self.clients = 0
        # Delay applied to command responses, to simulate a busy single-threaded
        # host. If slow_methods is given, only those methods are delayed.
        self.command_delay = command_delay
        self.slow_methods = slow_methods
        # When set, a background task writes bridge.heartbeat events ~1/interval,
        # mirroring the real host. These keep _last_traffic fresh independently of
        # the client's own session.heartbeat probes.
        self.emit_host_heartbeats = emit_host_heartbeats
        self.heartbeat_interval_ms = heartbeat_interval_ms
        self.lease_timeout_ms = lease_timeout_ms
        # When False, the host ignores session.heartbeat (never replies), to test
        # that inbound bridge.heartbeat events alone keep the connection fresh.
        self.answer_session_heartbeat = answer_session_heartbeat

    async def __aenter__(self):
        self.server = await asyncio.start_server(self._client, "127.0.0.1", 0)
        self.port = self.server.sockets[0].getsockname()[1]
        return self

    async def __aexit__(self, *_):
        self.server.close()
        await self.server.wait_closed()

    async def _client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        self.clients += 1
        try:
            hello = json.loads(await reader.readline())
            missing = set(hello["required_capabilities"]) - CAPABILITIES
            if missing:
                ack = {
                    "protocol": "rptk", "type": "hello_ack",
                    "request_id": hello["request_id"], "ok": False,
                    "error": {"code": "missing_capability", "message": "missing capability",
                              "retryable": False, "details": {}},
                }
            else:
                ack = {
                    "protocol": "rptk", "type": "hello_ack",
                    "request_id": hello["request_id"], "ok": True,
                    "negotiated_protocol": {"major": 1, "minor": 1},
                    "host": {"host_version": "0.2.0", "reaper_version": "fake",
                             "platform": "test", "capabilities": sorted(CAPABILITIES)},
                    "session": {"session_id": f"session-{self.clients}",
                                "lease_timeout_ms": self.lease_timeout_ms,
                                "heartbeat_interval_ms": self.heartbeat_interval_ms,
                                "udp_token": f"{self.clients:032x}", "udp_host": "127.0.0.1",
                                "udp_port": 9900},
                    "initial_state": state(),
                }
            writer.write(json.dumps(ack).encode() + b"\n")
            await writer.drain()
            if missing:
                return
            # Serialize writes so the background heartbeat emitter and the command
            # responder never interleave bytes on the same stream.
            write_lock = asyncio.Lock()

            async def emit(message: dict[str, Any]) -> None:
                async with write_lock:
                    try:
                        writer.write(json.dumps(message).encode() + b"\n")
                        await writer.drain()
                    except (ConnectionError, OSError):
                        pass  # client went away; nothing to send to

            heartbeat_task: asyncio.Task[None] | None = None
            if self.emit_host_heartbeats:
                heartbeat_task = asyncio.create_task(self._emit_heartbeats(emit))
            try:
                while line := await reader.readline():
                    request = json.loads(line)
                    method = request["method"]
                    payload = request["payload"]
                    if self.command_delay and (
                        self.slow_methods is None or method in self.slow_methods
                    ):
                        await asyncio.sleep(self.command_delay)
                    if method == "session.heartbeat" and not self.answer_session_heartbeat:
                        continue
                    result: dict[str, Any] = {}
                    if method == "state.get":
                        result = state(2)
                    elif method == "transport.set":
                        result = {"playing": payload["playing"]}
                    elif method in {"track.resolve", "track.capture_selection"}:
                        result = {"guid": "track-1", "name": "Track", "exists": True,
                                  "created": False, "role": payload.get("role", "")}
                    elif method == "session.heartbeat":
                        result = {"lease_deadline": 0.0}
                    await emit({
                        "protocol": "rptk", "protocol_major": 1, "type": "response",
                        "request_id": request["request_id"], "ok": True, "result": result,
                    })
            finally:
                if heartbeat_task is not None:
                    heartbeat_task.cancel()
        except (ConnectionError, OSError):
            pass  # client disconnected abruptly
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except (ConnectionError, OSError):
                pass

    async def _emit_heartbeats(self, emit) -> None:
        seq = 0
        try:
            while True:
                await asyncio.sleep(self.heartbeat_interval_ms / 1000)
                seq += 1
                await emit({
                    "protocol": "rptk", "protocol_major": 1, "type": "event",
                    "event": "bridge.heartbeat", "event_seq": seq,
                    "payload": {"state_seq": 1, "host_monotonic_time": 0.0,
                                "project_generation": "fake-project"},
                })
        except asyncio.CancelledError:
            return
