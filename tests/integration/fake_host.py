from __future__ import annotations

import asyncio
import json
from typing import Any

CAPABILITIES = {
    "project.state", "transport.read", "transport.control", "track.read",
    "track.resolve", "track.capture_selection", "midi.item", "midi.preview",
    "midi.udp_audition", "settings.repeat_guard", "settings.metronome_guard",
    "session.multi_client",
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
    def __init__(self) -> None:
        self.server: asyncio.Server | None = None
        self.port = 0
        self.clients = 0

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
                    "negotiated_protocol": {"major": 1, "minor": 0},
                    "host": {"host_version": "0.1.0", "reaper_version": "fake",
                             "platform": "test", "capabilities": sorted(CAPABILITIES)},
                    "session": {"session_id": f"session-{self.clients}",
                                "lease_timeout_ms": 5000, "heartbeat_interval_ms": 100,
                                "udp_token": f"{self.clients:032x}", "udp_host": "127.0.0.1",
                                "udp_port": 9900},
                    "initial_state": state(),
                }
            writer.write(json.dumps(ack).encode() + b"\n")
            await writer.drain()
            if missing:
                return
            while line := await reader.readline():
                request = json.loads(line)
                method = request["method"]
                payload = request["payload"]
                result: dict[str, Any] = {}
                if method == "state.get":
                    result = state(2)
                elif method == "transport.set":
                    result = {"playing": payload["playing"]}
                elif method in {"track.resolve", "track.capture_selection"}:
                    result = {"guid": "track-1", "name": "Track", "exists": True,
                              "created": False, "role": payload.get("role", "")}
                writer.write(json.dumps({
                    "protocol": "rptk", "protocol_major": 1, "type": "response",
                    "request_id": request["request_id"], "ok": True, "result": result,
                }).encode() + b"\n")
                await writer.drain()
        finally:
            writer.close()
            await writer.wait_closed()

