from __future__ import annotations

import asyncio
import concurrent.futures
import threading
from collections.abc import Coroutine
from typing import Any

from .async_client import AsyncReaperClient
from .models import ClientIdentity


class ReaperClient:
    """Blocking client backed by one persistent asyncio worker thread."""

    def __init__(
        self,
        identity: ClientIdentity,
        required_capabilities: set[str] | None = None,
        optional_capabilities: set[str] | None = None,
        **kwargs: Any,
    ) -> None:
        self._loop = asyncio.new_event_loop()
        self._thread = threading.Thread(target=self._run_loop, name="rptk-client", daemon=True)
        self._thread.start()
        self._client = AsyncReaperClient(
            identity, required_capabilities, optional_capabilities, **kwargs
        )

    def _run_loop(self) -> None:
        asyncio.set_event_loop(self._loop)
        self._loop.run_forever()

    def _run(self, coroutine: Coroutine[Any, Any, Any], timeout: float | None = None) -> Any:
        return asyncio.run_coroutine_threadsafe(coroutine, self._loop).result(timeout)

    def _call_on_loop(self, function, *args, **kwargs):
        future: concurrent.futures.Future[Any] = concurrent.futures.Future()

        def invoke() -> None:
            try:
                future.set_result(function(*args, **kwargs))
            except BaseException as exc:
                future.set_exception(exc)

        self._loop.call_soon_threadsafe(invoke)
        return future.result()

    @property
    def last_status(self):
        return self._client.last_status

    @property
    def last_state(self):
        return self._client.last_state

    def on_status(self, callback):
        self._client.on_status(callback)

    def on_state(self, callback):
        self._client.on_state(callback)

    def on_event(self, callback):
        self._client.on_event(callback)

    def has_capability(self, name: str) -> bool:
        return self._client.has_capability(name)

    def connect(self) -> None:
        self._run(self._client.connect())

    def start(self) -> None:
        self._run(self._client.start())

    def close(self) -> None:
        self._run(self._client.close())
        self._loop.call_soon_threadsafe(self._loop.stop)
        self._thread.join(timeout=2)

    def wait_until_ready(self, timeout: float | None = None) -> None:
        self._run(self._client.wait_until_ready(timeout), timeout)

    def refresh_state(self, *, timeout=None):
        return self._run(self._client.refresh_state(timeout=timeout), timeout)

    def set_transport(self, *, playing: bool, timeout=None):
        return self._run(self._client.set_transport(playing=playing, timeout=timeout), timeout)

    def set_edit_cursor(self, *, ppq: int, timeout=None):
        return self._run(self._client.set_edit_cursor(ppq=ppq, timeout=timeout), timeout)

    def capture_selected_track(self, *, role: str = "", bind=False, timeout=None):
        return self._run(
            self._client.capture_selected_track(role=role, bind=bind, timeout=timeout),
            timeout,
        )

    def resolve_track(self, track_ref, *, timeout=None):
        return self._run(self._client.resolve_track(track_ref, timeout=timeout), timeout)

    def resolve_bound_track(self, *, role, fallback, bind_fallback=False, timeout=None):
        return self._run(
            self._client.resolve_bound_track(
                role=role,
                fallback=fallback,
                bind_fallback=bind_fallback,
                timeout=timeout,
            ),
            timeout,
        )

    def clear_track_binding(self, *, role, timeout=None):
        return self._run(self._client.clear_track_binding(role=role, timeout=timeout), timeout)

    def list_resources(self, *, kind=None, target_guid=None, timeout=None):
        return self._run(
            self._client.list_resources(kind=kind, target_guid=target_guid, timeout=timeout),
            timeout,
        )

    def insert_midi_item(
        self,
        track_ref,
        midi_phrase,
        metadata=None,
        *,
        options,
        operation_id=None,
        timeout=None,
    ):
        return self._run(
            self._client.insert_midi_item(
                track_ref,
                midi_phrase,
                metadata,
                options=options,
                operation_id=operation_id,
                timeout=timeout,
            ),
            timeout,
        )

    def replace_midi_item(
        self,
        resource_id,
        midi_phrase,
        metadata=None,
        *,
        options=None,
        operation_id=None,
        timeout=None,
    ):
        return self._run(
            self._client.replace_midi_item(
                resource_id,
                midi_phrase,
                metadata,
                options=options,
                operation_id=operation_id,
                timeout=timeout,
            ),
            timeout,
        )

    def prepare_midi_preview(self, track_ref, midi_phrase, options=None, *, timeout=None):
        return self._run(
            self._client.prepare_midi_preview(track_ref, midi_phrase, options, timeout=timeout),
            timeout,
        )

    def update_midi_preview(self, resource_id, midi_phrase, *, revision=None, timeout=None):
        return self._run(
            self._client.update_midi_preview(
                resource_id, midi_phrase, revision=revision, timeout=timeout
            ),
            timeout,
        )

    def stop_midi_preview(self, resource_id, *, timeout=None):
        return self._run(self._client.stop_midi_preview(resource_id, timeout=timeout), timeout)

    def send_midi_event(self, status, data1, data2, *, delay_seconds=0.0):
        return self._call_on_loop(
            self._client.send_midi_event,
            status,
            data1,
            data2,
            delay_seconds=delay_seconds,
        )

    def reset_midi_generation(self):
        return self._call_on_loop(self._client.reset_midi_generation)
