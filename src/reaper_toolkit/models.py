from __future__ import annotations

import hashlib
import json
import time
import uuid
from dataclasses import asdict, dataclass, field
from enum import StrEnum
from typing import Any


class ConnectionState(StrEnum):
    DISCONNECTED = "disconnected"
    CONNECTING = "connecting"
    HANDSHAKING = "handshaking"
    SYNCING_STATE = "syncing_state"
    READY = "ready"
    DEGRADED = "degraded"
    RECONNECTING = "reconnecting"
    INCOMPATIBLE = "incompatible"
    ERROR = "error"
    CLOSING = "closing"


class Severity(StrEnum):
    INFO = "info"
    SUCCESS = "success"
    WARNING = "warning"
    ERROR = "error"


@dataclass(frozen=True)
class BridgeStatus:
    state: ConnectionState
    severity: Severity
    summary: str
    detail: str = ""
    action: str | None = None
    retryable: bool = False
    connected: bool = False
    ready: bool = False
    state_current: bool = False
    host_version: str | None = None
    protocol_version: tuple[int, int] | None = None
    session_id: str | None = None
    changed_at: float = field(default_factory=time.monotonic)


@dataclass(frozen=True)
class ClientIdentity:
    app_id: str
    app_version: str
    display_name: str
    instance_id: str = field(default_factory=lambda: str(uuid.uuid4()))

    def __post_init__(self) -> None:
        if "." not in self.app_id or not self.app_id.strip():
            raise ValueError("app_id must be a collision-resistant dotted identifier")
        if not self.app_version or not self.display_name or not self.instance_id:
            raise ValueError("client identity fields cannot be empty")


@dataclass(frozen=True)
class Meter:
    numerator: int
    denominator: int


@dataclass(frozen=True)
class CursorState:
    seconds: float
    ppq: int


@dataclass(frozen=True)
class Project:
    guid: str
    ppq: int
    bpm: float
    meter: Meter
    playing: bool
    recording: bool
    repeat_enabled: bool
    edit_cursor: CursorState
    play_cursor: CursorState


@dataclass(frozen=True)
class ProjectState:
    state_seq: int
    project_generation: str
    project: Project
    sessions: tuple[dict[str, Any], ...] = ()
    resources: tuple[dict[str, Any], ...] = ()

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> ProjectState:
        project = value["project"]
        return cls(
            state_seq=int(value["state_seq"]),
            project_generation=str(value["project_generation"]),
            project=Project(
                guid=str(project["guid"]),
                ppq=int(project["ppq"]),
                bpm=float(project["bpm"]),
                meter=Meter(**project["meter"]),
                playing=bool(project["playing"]),
                recording=bool(project["recording"]),
                repeat_enabled=bool(project["repeat_enabled"]),
                edit_cursor=CursorState(**project["edit_cursor"]),
                play_cursor=CursorState(**project["play_cursor"]),
            ),
            sessions=tuple(value.get("sessions") or ()),
            resources=tuple(value.get("resources") or ()),
        )


class TrackCreate(StrEnum):
    NEVER = "never"
    IF_MISSING = "if_missing"
    ALWAYS_NEW = "always_new"


@dataclass(frozen=True)
class TrackRef:
    guid: str = ""
    name: str = ""
    role: str = ""
    create: TrackCreate = TrackCreate.NEVER
    selection_fallback: bool = False

    def to_dict(self) -> dict[str, Any]:
        value = asdict(self)
        value["create"] = self.create.value
        return value


@dataclass(frozen=True)
class TrackState:
    guid: str
    name: str
    exists: bool
    created: bool = False
    role: str = ""

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> TrackState:
        return cls(**value)


@dataclass(frozen=True, order=True)
class MidiNote:
    start_ppq: int
    duration_ppq: int
    channel: int
    pitch: int
    velocity: int

    def __post_init__(self) -> None:
        if self.start_ppq < 0 or self.duration_ppq < 1:
            raise ValueError("MIDI note timing is invalid")
        if not 0 <= self.channel <= 15:
            raise ValueError("MIDI channel must be 0..15")
        if not 0 <= self.pitch <= 127 or not 0 <= self.velocity <= 127:
            raise ValueError("MIDI pitch and velocity must be 0..127")


@dataclass(frozen=True)
class MidiPhrase:
    source_ppqn: int
    length_ppq: int
    revision: str
    notes: tuple[MidiNote, ...]

    def __post_init__(self) -> None:
        if self.source_ppqn < 1 or self.length_ppq < 1:
            raise ValueError("phrase PPQN and length must be positive")
        if len(self.revision) != 64 or any(c not in "0123456789abcdef" for c in self.revision):
            raise ValueError("revision must be a lowercase SHA-256 hex digest")
        if any(note.start_ppq + note.duration_ppq > self.length_ppq for note in self.notes):
            raise ValueError("notes must fit within the phrase")

    def to_dict(self) -> dict[str, Any]:
        return {
            "source_ppqn": self.source_ppqn,
            "length_ppq": self.length_ppq,
            "revision": self.revision,
            "notes": [asdict(note) for note in self.notes],
        }

    @classmethod
    def create(cls, source_ppqn: int, length_ppq: int, notes: list[MidiNote]) -> MidiPhrase:
        ordered = tuple(sorted(notes))
        canonical = json.dumps(
            {
                "source_ppqn": source_ppqn,
                "length_ppq": length_ppq,
                "notes": [asdict(note) for note in ordered],
            },
            sort_keys=True,
            separators=(",", ":"),
        ).encode()
        return cls(source_ppqn, length_ppq, hashlib.sha256(canonical).hexdigest(), ordered)


@dataclass(frozen=True)
class PreviewOptions:
    count_in: bool = True
    repeat_guard: bool = True
    metronome_guard: bool = False
    start_ppq: int | None = None


@dataclass(frozen=True)
class PreviewState:
    resource_id: str
    active: bool
    active_revision: str
    pending_revision: str | None = None


@dataclass(frozen=True)
class ResourceState:
    resource_id: str
    kind: str
    app_id: str
    session_id: str | None = None
    metadata: dict[str, Any] = field(default_factory=dict)
