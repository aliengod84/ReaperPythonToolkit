from __future__ import annotations

import asyncio
import functools
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

    def close(self) -> None:
        self._run(self._client.close())
        self._loop.call_soon_threadsafe(self._loop.stop)
        self._thread.join(timeout=2)

    def wait_until_ready(self, timeout: float | None = None) -> None:
        self._run(self._client.wait_until_ready(timeout), timeout)

    def refresh_state(self):
        return self._run(self._client.refresh_state())

    def set_transport(self, *, playing: bool):
        return self._run(self._client.set_transport(playing=playing))

    def set_edit_cursor(self, *, ppq: int):
        return self._run(self._client.set_edit_cursor(ppq=ppq))

    def capture_selected_track(self, *, role: str = ""):
        return self._run(self._client.capture_selected_track(role=role))

    def resolve_track(self, track_ref):
        return self._run(self._client.resolve_track(track_ref))

    def insert_midi_item(self, track_ref, midi_phrase, metadata=None, *, operation_id=None):
        return self._run(self._client.insert_midi_item(
            track_ref, midi_phrase, metadata, operation_id=operation_id
        ))

    def replace_midi_item(self, resource_id, midi_phrase, metadata=None, *, operation_id=None):
        return self._run(self._client.replace_midi_item(
            resource_id, midi_phrase, metadata, operation_id=operation_id
        ))

    def prepare_midi_preview(self, track_ref, midi_phrase, options=None):
        return self._run(self._client.prepare_midi_preview(track_ref, midi_phrase, options))

    def update_midi_preview(self, resource_id, midi_phrase, *, revision=None):
        return self._run(self._client.update_midi_preview(
            resource_id, midi_phrase, revision=revision
        ))

    def stop_midi_preview(self, resource_id):
        return self._run(self._client.stop_midi_preview(resource_id))

    def send_midi_event(self, status, data1, data2, *, delay_seconds=0.0):
        self._loop.call_soon_threadsafe(
            functools.partial(
                self._client.send_midi_event,
                status,
                data1,
                data2,
                delay_seconds=delay_seconds,
            )
        )

    def reset_midi_generation(self):
        self._loop.call_soon_threadsafe(self._client.reset_midi_generation)
