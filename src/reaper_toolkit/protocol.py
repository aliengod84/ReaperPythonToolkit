from __future__ import annotations

import json
from typing import Any

from .version import PROTOCOL_MAJOR

MAX_MESSAGE_BYTES = 1024 * 1024


class ProtocolError(ValueError):
    pass


class LineCodec:
    def __init__(self, max_message_bytes: int = MAX_MESSAGE_BYTES) -> None:
        self.buffer = bytearray()
        self.max_message_bytes = max_message_bytes

    def feed(self, data: bytes) -> list[dict[str, Any]]:
        self.buffer.extend(data)
        if len(self.buffer) > self.max_message_bytes:
            raise ProtocolError("message exceeds 1 MiB")
        messages: list[dict[str, Any]] = []
        while (newline := self.buffer.find(b"\n")) >= 0:
            line = bytes(self.buffer[:newline])
            del self.buffer[: newline + 1]
            if not line:
                continue
            if len(line) > self.max_message_bytes:
                raise ProtocolError("message exceeds 1 MiB")
            try:
                value = json.loads(line.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise ProtocolError("invalid UTF-8 JSON message") from exc
            if not isinstance(value, dict):
                raise ProtocolError("message must be a JSON object")
            messages.append(value)
        return messages


def encode_message(value: dict[str, Any]) -> bytes:
    encoded = json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    if len(encoded) > MAX_MESSAGE_BYTES:
        raise ProtocolError("message exceeds 1 MiB")
    return encoded + b"\n"


def request_envelope(request_id: str, method: str, payload: dict[str, Any]) -> dict[str, Any]:
    return {
        "protocol": "rptk",
        "protocol_major": PROTOCOL_MAJOR,
        "type": "request",
        "request_id": request_id,
        "method": method,
        "payload": payload,
    }


def validate_post_handshake(value: dict[str, Any]) -> None:
    if value.get("protocol") != "rptk" or value.get("protocol_major") != PROTOCOL_MAJOR:
        raise ProtocolError("not an RPTK protocol 1 message")
    if value.get("type") not in {"request", "response", "event"}:
        raise ProtocolError("invalid message type")

