from __future__ import annotations

import asyncio
import contextlib
import os
import sys
import time
import uuid
from collections.abc import Callable
from dataclasses import asdict
from typing import Any

from .commands import (
    CURSOR_SET,
    MIDI_ITEM_INSERT,
    MIDI_ITEM_REPLACE,
    MIDI_PREVIEW_PREPARE,
    MIDI_PREVIEW_STOP,
    MIDI_PREVIEW_UPDATE,
    RESOURCE_LIST,
    STATE_GET,
    TRACK_BINDING_CLEAR,
    TRACK_CAPTURE_SELECTION,
    TRACK_RESOLVE,
    TRACK_RESOLVE_BOUND,
    TRANSPORT_SET,
)
from .errors import (
    CommandTimeoutError,
    ConnectionLostError,
    HandshakeError,
    IncompatibleHostError,
    MissingCapabilityError,
    command_error,
)
from .midi import MidiAuditionSender
from .models import (
    BridgeStatus,
    ClientIdentity,
    ConnectionState,
    InsertOptions,
    MidiPhrase,
    PreviewOptions,
    PreviewState,
    ProjectState,
    ReplaceOptions,
    ResourceState,
    Severity,
    TrackRef,
    TrackState,
)
from .protocol import LineCodec, ProtocolError, encode_message, request_envelope
from .transport import DEFAULT_HOST, DEFAULT_TCP_PORT
from .version import PACKAGE_VERSION, PROTOCOL_MAJOR, PROTOCOL_MINOR

# Lightweight, opt-in protocol tracing (RPTK_TRACE=1) for diagnosing dropped or
# mismatched responses. Off by default; writes to stderr.
_TRACE = os.getenv("RPTK_TRACE", "").lower() in {"1", "true", "yes", "on"}


def _trace(message: str) -> None:
    if _TRACE:
        print(f"[RPTK-TRACE] {message}", file=sys.stderr, flush=True)


StatusCallback = Callable[[BridgeStatus], None]
StateCallback = Callable[[ProjectState], None]
EventCallback = Callable[[dict[str, Any]], None]


class AsyncReaperClient:
    def __init__(
        self,
        identity: ClientIdentity,
        required_capabilities: set[str] | None = None,
        optional_capabilities: set[str] | None = None,
        *,
        host: str = DEFAULT_HOST,
        port: int = DEFAULT_TCP_PORT,
        command_timeout: float = 5.0,
        auto_reconnect: bool = True,
    ) -> None:
        self.identity = identity
        self.required_capabilities = frozenset(required_capabilities or ())
        self.optional_capabilities = frozenset(optional_capabilities or ())
        self.host, self.port = host, port
        self.command_timeout = command_timeout
        self.auto_reconnect = auto_reconnect
        self.last_status = self._status(ConnectionState.DISCONNECTED)
        self.last_state: ProjectState | None = None
        self._capabilities: frozenset[str] = frozenset()
        self._reader: asyncio.StreamReader | None = None
        self._writer: asyncio.StreamWriter | None = None
        self._reader_task: asyncio.Task[None] | None = None
        self._heartbeat_task: asyncio.Task[None] | None = None
        self._monitor_task: asyncio.Task[None] | None = None
        self._connect_task: asyncio.Task[None] | None = None
        self._pending: dict[str, tuple[str, asyncio.Future[dict[str, Any]]]] = {}
        self._status_callbacks: list[StatusCallback] = []
        self._state_callbacks: list[StateCallback] = []
        self._event_callbacks: list[EventCallback] = []
        self._ready = asyncio.Event()
        self._closing = False
        self._last_traffic = 0.0
        self._heartbeat_interval = 1.0
        self._lease_timeout = 5.0
        self._udp: MidiAuditionSender | None = None
        self._connect_lock = asyncio.Lock()
        # Serialize writes so a heartbeat and a command write never interleave on
        # the shared stream. The response-wait stays outside this lock so a slow
        # reply cannot block other writers.
        self._write_lock = asyncio.Lock()

    def on_status(self, callback: StatusCallback) -> None:
        self._status_callbacks.append(callback)

    def on_state(self, callback: StateCallback) -> None:
        self._state_callbacks.append(callback)

    def on_event(self, callback: EventCallback) -> None:
        self._event_callbacks.append(callback)

    def has_capability(self, name: str) -> bool:
        return name in self._capabilities

    async def connect(self) -> None:
        self._closing = False
        async with self._connect_lock:
            if self.last_status.ready:
                return
            await self._connect_once(reconnecting=False)

    async def start(self) -> None:
        """Start connecting in the background and return immediately."""
        self._closing = False
        if self.last_status.ready or (self._connect_task and not self._connect_task.done()):
            return
        self._connect_task = asyncio.create_task(self._initial_connect_loop())

    async def _initial_connect_loop(self) -> None:
        try:
            await self._connect_once(reconnecting=False)
        except (IncompatibleHostError, MissingCapabilityError):
            return
        except Exception as exc:
            if self.auto_reconnect and not self._closing:
                await self._reconnect_loop()
            elif not self._closing:
                self._set_status(ConnectionState.ERROR, detail=str(exc), retryable=True)

    async def _connect_once(self, *, reconnecting: bool) -> None:
        next_state = ConnectionState.RECONNECTING if reconnecting else ConnectionState.CONNECTING
        self._set_status(next_state)
        try:
            self._reader, self._writer = await asyncio.wait_for(
                asyncio.open_connection(self.host, self.port), timeout=2.0
            )
            self._set_status(ConnectionState.HANDSHAKING, connected=True)
            hello_id = str(uuid.uuid4())
            hello = {
                "protocol": "rptk",
                "type": "hello",
                "request_id": hello_id,
                "protocol_range": {
                    "major": PROTOCOL_MAJOR,
                    "min_minor": PROTOCOL_MINOR,
                    "max_minor": PROTOCOL_MINOR,
                },
                "client": {
                    **asdict(self.identity),
                    "sdk_version": PACKAGE_VERSION,
                },
                "required_capabilities": sorted(self.required_capabilities),
                "optional_capabilities": sorted(self.optional_capabilities),
            }
            async with self._write_lock:
                self._writer.write(encode_message(hello))
                await self._writer.drain()
            line = await asyncio.wait_for(self._reader.readline(), timeout=2.0)
            if not line:
                raise HandshakeError("host closed during handshake")
            codec = LineCodec()
            messages = codec.feed(line)
            if len(messages) != 1:
                raise HandshakeError("invalid hello acknowledgement")
            ack = messages[0]
            self._set_status(ConnectionState.SYNCING_STATE, connected=True)
            self._accept_hello(ack, hello_id)
            self._last_traffic = time.monotonic()
            self._reader_task = asyncio.create_task(self._read_loop())
            self._heartbeat_task = asyncio.create_task(self._heartbeat_loop())
            self._monitor_task = asyncio.create_task(self._freshness_loop())
            self._set_status(ConnectionState.READY, connected=True, state_current=True)
            self._ready.set()
        except (IncompatibleHostError, MissingCapabilityError) as exc:
            await self._drop_connection(exc)
            self._set_status(
                ConnectionState.INCOMPATIBLE,
                detail=str(exc),
                action="Install and run a compatible rptk_host.lua",
            )
            raise
        except Exception as exc:
            await self._drop_connection(exc)
            self._set_status(ConnectionState.ERROR, detail=str(exc), retryable=True)
            raise

    def _accept_hello(self, ack: dict[str, Any], request_id: str) -> None:
        if ack.get("protocol") != "rptk" or ack.get("type") != "hello_ack":
            raise IncompatibleHostError("the port is not serving an RPTK host")
        if ack.get("request_id") != request_id:
            raise HandshakeError("hello request ID mismatch")
        if not ack.get("ok"):
            error = ack.get("error") or {}
            code = error.get("code")
            message = str(error.get("message", code or "handshake rejected"))
            if code in {"protocol_major_mismatch", "protocol_minor_unsupported", "not_rptk_host"}:
                raise IncompatibleHostError(message)
            if code == "missing_capability":
                raise MissingCapabilityError(message)
            raise HandshakeError(message)
        protocol = ack.get("negotiated_protocol") or {}
        if (protocol.get("major"), protocol.get("minor")) != (PROTOCOL_MAJOR, PROTOCOL_MINOR):
            raise IncompatibleHostError("host negotiated an unsupported protocol")
        host = ack.get("host") or {}
        capabilities = frozenset(host.get("capabilities") or ())
        missing = self.required_capabilities - capabilities
        if missing:
            names = ", ".join(sorted(missing))
            raise MissingCapabilityError(f"host is missing capabilities: {names}")
        session = ack.get("session") or {}
        required_session = {
            "session_id",
            "lease_timeout_ms",
            "heartbeat_interval_ms",
            "udp_token",
            "udp_host",
            "udp_port",
        }
        if not required_session.issubset(session):
            raise HandshakeError("hello acknowledgement has incomplete session data")
        state = ProjectState.from_dict(ack["initial_state"])
        self._accept_state(state)
        self._capabilities = capabilities
        self._heartbeat_interval = int(session["heartbeat_interval_ms"]) / 1000
        self._lease_timeout = int(session["lease_timeout_ms"]) / 1000
        self._udp = MidiAuditionSender(
            str(session["udp_host"]), int(session["udp_port"]), str(session["udp_token"])
        )
        self.last_status = BridgeStatus(
            state=ConnectionState.SYNCING_STATE,
            severity=Severity.INFO,
            summary="Reaper connecting",
            connected=True,
            host_version=str(host.get("host_version", "")),
            protocol_version=(PROTOCOL_MAJOR, PROTOCOL_MINOR),
            session_id=str(session["session_id"]),
        )

    async def close(self) -> None:
        self._closing = True
        self._set_status(ConnectionState.CLOSING, connected=self._writer is not None)
        if self._writer is not None and self.last_status.ready:
            with contextlib.suppress(Exception):
                await self.request("session.close", timeout=1.0)
        current = asyncio.current_task()
        if self._connect_task and self._connect_task is not current:
            self._connect_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._connect_task
        self._connect_task = None
        await self._drop_connection(ConnectionLostError("client closed"))
        self._set_status(ConnectionState.DISCONNECTED)

    async def wait_until_ready(self, timeout: float | None = None) -> None:
        await asyncio.wait_for(self._ready.wait(), timeout)

    async def request(
        self,
        method: str,
        payload: dict[str, Any] | None = None,
        *,
        operation_id: str | None = None,
        timeout: float | None = None,
    ) -> dict[str, Any]:
        if not self.last_status.ready or self._writer is None:
            raise ConnectionLostError("Reaper bridge is not ready")
        body = dict(payload or {})
        if operation_id is not None:
            body["operation_id"] = operation_id
        request_id = str(uuid.uuid4())
        future = asyncio.get_running_loop().create_future()
        self._pending[request_id] = (method, future)
        try:
            async with self._write_lock:
                self._writer.write(encode_message(request_envelope(request_id, method, body)))
                await self._writer.drain()
            _trace(f"sent request method={method} request_id={request_id}")
            return await asyncio.wait_for(future, timeout or self.command_timeout)
        except TimeoutError as exc:
            _trace(f"TIMEOUT waiting for method={method} request_id={request_id}")
            raise CommandTimeoutError(f"timed out waiting for {method}") from exc
        finally:
            self._pending.pop(request_id, None)

    async def refresh_state(self, *, timeout: float | None = None) -> ProjectState:
        result = await self.request(STATE_GET, timeout=timeout)
        state = ProjectState.from_dict(result)
        self._accept_state(state)
        return state

    async def set_transport(self, *, playing: bool, timeout: float | None = None) -> dict[str, Any]:
        return await self.request(TRANSPORT_SET, {"playing": playing}, timeout=timeout)

    async def set_edit_cursor(self, *, ppq: int, timeout: float | None = None) -> dict[str, Any]:
        return await self.request(CURSOR_SET, {"ppq": ppq}, timeout=timeout)

    async def capture_selected_track(
        self, *, role: str = "", bind: bool = False, timeout: float | None = None
    ) -> TrackState:
        return TrackState.from_dict(
            await self.request(
                TRACK_CAPTURE_SELECTION, {"role": role, "bind": bind}, timeout=timeout
            )
        )

    async def resolve_track(
        self, track_ref: TrackRef, *, timeout: float | None = None
    ) -> TrackState:
        result = await self.request(
            TRACK_RESOLVE, {"track_ref": track_ref.to_dict()}, timeout=timeout
        )
        return TrackState.from_dict(result)

    async def resolve_bound_track(
        self,
        *,
        role: str,
        fallback: TrackRef,
        bind_fallback: bool = False,
        timeout: float | None = None,
    ) -> TrackState:
        result = await self.request(
            TRACK_RESOLVE_BOUND,
            {
                "role": role,
                "fallback": fallback.to_dict(),
                "bind_fallback": bind_fallback,
            },
            timeout=timeout,
        )
        return TrackState.from_dict(result)

    async def clear_track_binding(self, *, role: str, timeout: float | None = None) -> None:
        await self.request(TRACK_BINDING_CLEAR, {"role": role}, timeout=timeout)

    async def list_resources(
        self,
        *,
        kind: str | None = None,
        target_guid: str | None = None,
        timeout: float | None = None,
    ) -> tuple[ResourceState, ...]:
        result = await self.request(
            RESOURCE_LIST,
            {"kind": kind, "target_guid": target_guid},
            timeout=timeout,
        )
        return tuple(ResourceState.from_dict(value) for value in result.get("resources", ()))

    async def insert_midi_item(
        self,
        track_ref: TrackRef,
        midi_phrase: MidiPhrase,
        metadata: dict[str, Any] | None = None,
        *,
        options: InsertOptions,
        operation_id: str | None = None,
        timeout: float | None = None,
    ) -> dict[str, Any]:
        return await self.request(
            MIDI_ITEM_INSERT,
            {
                "track_ref": track_ref.to_dict(),
                "midi_phrase": midi_phrase.to_dict(),
                "metadata": metadata or {},
                "options": asdict(options),
            },
            operation_id=operation_id,
            timeout=timeout,
        )

    async def replace_midi_item(
        self,
        resource_id: str,
        midi_phrase: MidiPhrase,
        metadata: dict[str, Any] | None = None,
        *,
        options: ReplaceOptions | None = None,
        operation_id: str | None = None,
        timeout: float | None = None,
    ) -> dict[str, Any]:
        return await self.request(
            MIDI_ITEM_REPLACE,
            {
                "resource_id": resource_id,
                "midi_phrase": midi_phrase.to_dict(),
                "metadata": metadata or {},
                "options": asdict(options or ReplaceOptions()),
            },
            operation_id=operation_id,
            timeout=timeout,
        )

    async def prepare_midi_preview(
        self,
        track_ref: TrackRef,
        midi_phrase: MidiPhrase,
        options: PreviewOptions | None = None,
        *,
        timeout: float | None = None,
    ) -> PreviewState:
        result = await self.request(
            MIDI_PREVIEW_PREPARE,
            {
                "track_ref": track_ref.to_dict(),
                "midi_phrase": midi_phrase.to_dict(),
                "options": asdict(options or PreviewOptions()),
            },
            timeout=timeout,
        )
        return PreviewState.from_dict(result)

    async def update_midi_preview(
        self,
        resource_id: str,
        midi_phrase: MidiPhrase,
        *,
        revision: str | None = None,
        timeout: float | None = None,
    ) -> PreviewState:
        result = await self.request(
            MIDI_PREVIEW_UPDATE,
            {
                "resource_id": resource_id,
                "midi_phrase": midi_phrase.to_dict(),
                "revision": revision or midi_phrase.revision,
            },
            timeout=timeout,
        )
        return PreviewState.from_dict(result)

    async def stop_midi_preview(
        self, resource_id: str, *, timeout: float | None = None
    ) -> PreviewState:
        return PreviewState.from_dict(
            await self.request(MIDI_PREVIEW_STOP, {"resource_id": resource_id}, timeout=timeout)
        )

    def send_midi_event(
        self, status: int, data1: int, data2: int, *, delay_seconds: float = 0.0
    ) -> None:
        if self._udp is None or not self.last_status.ready:
            raise ConnectionLostError("UDP audition is not ready")
        self._udp.send(status, data1, data2, delay_seconds=delay_seconds)

    def reset_midi_generation(self) -> None:
        if self._udp is None:
            raise ConnectionLostError("UDP audition is not ready")
        self._udp.reset()

    async def _read_loop(self) -> None:
        assert self._reader is not None
        codec = LineCodec()
        try:
            while data := await self._reader.read(65536):
                self._last_traffic = time.monotonic()
                for message in codec.feed(data):
                    if _TRACE:
                        _trace(
                            f"recv type={message.get('type')} "
                            f"request_id={message.get('request_id')} "
                            f"event={message.get('event')}"
                        )
                    self._handle_message(message)
            raise ConnectionLostError("host closed the connection")
        except (OSError, ProtocolError, ConnectionLostError) as exc:
            if not self._closing:
                await self._connection_lost(exc)

    def _handle_message(self, message: dict[str, Any]) -> None:
        if message.get("protocol") != "rptk" or message.get("protocol_major") != PROTOCOL_MAJOR:
            raise ProtocolError("invalid post-handshake envelope")
        if message.get("type") == "response":
            request_id = str(message.get("request_id", ""))
            pending = self._pending.get(request_id)
            if pending is None:
                _trace(
                    f"DROPPED response request_id={request_id!r} ok={message.get('ok')} "
                    f"(no pending match; pending={list(self._pending)})"
                )
                return
            method, future = pending
            _trace(
                f"matched response method={method} request_id={request_id} "
                f"ok={message.get('ok')}"
            )
            if future.done():
                _trace(f"response arrived but future already done method={method}")
                return
            if message.get("ok"):
                future.set_result(dict(message.get("result") or {}))
            else:
                future.set_exception(command_error(message.get("error") or {}, request_id, method))
            return
        if message.get("type") == "event":
            event = str(message.get("event", ""))
            payload = dict(message.get("payload") or {})
            if event == "state.changed":
                self._accept_state(ProjectState.from_dict(payload))
            for callback in tuple(self._event_callbacks):
                try:
                    callback(message)
                except Exception:
                    pass
            return
        raise ProtocolError("host sent an invalid message")

    def _accept_state(self, state: ProjectState) -> None:
        current = self.last_state
        if current and current.project_generation == state.project_generation:
            if state.state_seq <= current.state_seq:
                return
        self.last_state = state
        for callback in tuple(self._state_callbacks):
            try:
                callback(state)
            except Exception:
                pass

    async def _heartbeat_loop(self) -> None:
        # Tolerate a single slow response: a busy single-threaded host can defer a
        # reply past the bare interval. Keep cadence at the interval but allow the
        # probe itself more room than one interval. A transient command timeout
        # must never end heartbeating -- only a genuine connection loss should,
        # and that is driven by _read_loop -> _connection_lost (which cancels this
        # task). Suiciding on the first timeout was the cause of the reconnect
        # loop under normal command load.
        probe_timeout = max(self._heartbeat_interval, self._lease_timeout / 2)
        while not self._closing:
            await asyncio.sleep(self._heartbeat_interval)
            if self._closing or self._writer is None:
                return
            try:
                await self.request("session.heartbeat", timeout=probe_timeout)
            except CommandTimeoutError:
                continue  # host briefly busy; keep probing
            except (ConnectionLostError, OSError):
                return  # real loss; teardown handled by _read_loop/_drop_connection
            except Exception:
                continue  # never suicide on an unexpected transient

    async def _freshness_loop(self) -> None:
        while not self._closing:
            await asyncio.sleep(0.25)
            silence = time.monotonic() - self._last_traffic
            if silence >= self._lease_timeout:
                await self._connection_lost(ConnectionLostError("host heartbeat timed out"))
                return
            if silence >= 3.0 and self.last_status.state == ConnectionState.READY:
                self._set_status(ConnectionState.DEGRADED, connected=True, state_current=False)

    async def _connection_lost(self, exc: Exception) -> None:
        await self._drop_connection(exc)
        if not self.auto_reconnect or self._closing:
            self._set_status(ConnectionState.ERROR, detail=str(exc), retryable=True)
            return
        self._connect_task = asyncio.create_task(self._reconnect_loop())

    async def _reconnect_loop(self) -> None:
        for delay in (0.25, 0.5, 1.0, 2.0):
            if self._closing:
                return
            self._set_status(ConnectionState.RECONNECTING, detail=f"Retrying in {delay:g}s")
            await asyncio.sleep(delay)
            try:
                await self._connect_once(reconnecting=True)
                return
            except Exception:
                pass
        while not self._closing:
            self._set_status(ConnectionState.RECONNECTING, detail="Retrying in 5s")
            await asyncio.sleep(5.0)
            try:
                await self._connect_once(reconnecting=True)
                return
            except Exception:
                pass

    async def _drop_connection(self, exc: Exception) -> None:
        self._ready.clear()
        current = asyncio.current_task()
        for task in (self._reader_task, self._heartbeat_task, self._monitor_task):
            if task and task is not current:
                task.cancel()
        self._reader_task = self._heartbeat_task = self._monitor_task = None
        if self._writer:
            self._writer.close()
            with contextlib.suppress(Exception):
                await self._writer.wait_closed()
        self._reader = self._writer = None
        if self._udp:
            self._udp.close()
            self._udp = None
        for _, future in self._pending.values():
            if not future.done():
                future.set_exception(ConnectionLostError(str(exc)))
        self._pending.clear()

    def _status(
        self,
        state: ConnectionState,
        *,
        detail: str = "",
        action: str | None = None,
        retryable: bool = False,
        connected: bool = False,
        state_current: bool = False,
    ) -> BridgeStatus:
        summaries = {
            ConnectionState.DISCONNECTED: "Reaper disconnected",
            ConnectionState.CONNECTING: "Reaper connecting",
            ConnectionState.HANDSHAKING: "Reaper connecting",
            ConnectionState.SYNCING_STATE: "Reaper connecting",
            ConnectionState.READY: "Reaper connected",
            ConnectionState.DEGRADED: "Reaper connection degraded",
            ConnectionState.RECONNECTING: "Reconnecting to Reaper",
            ConnectionState.INCOMPATIBLE: "Incompatible Reaper host",
            ConnectionState.ERROR: "Reaper bridge error",
            ConnectionState.CLOSING: "Closing Reaper connection",
        }
        severity = (
            Severity.SUCCESS
            if state == ConnectionState.READY
            else Severity.WARNING
            if state in {ConnectionState.DEGRADED, ConnectionState.RECONNECTING}
            else Severity.ERROR
            if state in {ConnectionState.INCOMPATIBLE, ConnectionState.ERROR}
            else Severity.INFO
        )
        old = getattr(self, "last_status", None)
        return BridgeStatus(
            state=state,
            severity=severity,
            summary=summaries[state],
            detail=detail,
            action=action,
            retryable=retryable,
            connected=connected,
            ready=state == ConnectionState.READY,
            state_current=state_current,
            host_version=old.host_version if old else None,
            protocol_version=old.protocol_version if old else None,
            session_id=old.session_id if old else None,
        )

    def _set_status(self, state: ConnectionState, **kwargs: Any) -> None:
        status = self._status(state, **kwargs)
        self.last_status = status
        for callback in tuple(self._status_callbacks):
            try:
                callback(status)
            except Exception:
                pass
