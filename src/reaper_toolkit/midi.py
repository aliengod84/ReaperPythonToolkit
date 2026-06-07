from __future__ import annotations

import socket
import struct
import threading
from dataclasses import dataclass

MAGIC = b"RPTK"
MIDI_EVENT = 1
GENERATION_RESET = 2
PROBE = 3
PROBE_RESPONSE = 4
EVENT_STRUCT = struct.Struct("!4sBB16sIIdBBB")
RESET_STRUCT = struct.Struct("!4sBB16sII")


def _token_bytes(token: str) -> bytes:
    value = bytes.fromhex(token)
    if len(value) != 16:
        raise ValueError("UDP token must be 128-bit lowercase hex")
    return value


def encode_midi_event(
    token: str,
    generation: int,
    sequence: int,
    delay_seconds: float,
    status: int,
    data1: int,
    data2: int,
) -> bytes:
    if delay_seconds < 0 or not all(0 <= value <= 255 for value in (status, data1, data2)):
        raise ValueError("invalid MIDI event packet")
    return EVENT_STRUCT.pack(
        MAGIC, 1, MIDI_EVENT, _token_bytes(token), generation, sequence,
        delay_seconds, status, data1, data2,
    )


def encode_reset(token: str, generation: int, sequence: int = 0) -> bytes:
    return RESET_STRUCT.pack(MAGIC, 1, GENERATION_RESET, _token_bytes(token), generation, sequence)


@dataclass
class MidiAuditionSender:
    host: str
    port: int
    token: str
    generation: int = 0
    sequence: int = 0

    def __post_init__(self) -> None:
        self._socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._lock = threading.Lock()

    def send(
        self, status: int, data1: int, data2: int, *, delay_seconds: float = 0.0
    ) -> None:
        with self._lock:
            self.sequence += 1
            packet = encode_midi_event(
                self.token, self.generation, self.sequence, delay_seconds, status, data1, data2
            )
            self._socket.sendto(packet, (self.host, self.port))

    def reset(self) -> None:
        with self._lock:
            self.generation = (self.generation + 1) & 0xFFFFFFFF
            self.sequence = 0
            self._socket.sendto(encode_reset(self.token, self.generation), (self.host, self.port))

    def close(self) -> None:
        with self._lock:
            self._socket.close()
