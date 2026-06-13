from __future__ import annotations

import asyncio
import socket
import time

import pytest

from reaper_toolkit import (
    AsyncReaperClient,
    ClientIdentity,
    InsertOptions,
    MidiNote,
    MidiPhrase,
    PreviewOptions,
    ReplaceOptions,
    TrackCreate,
    TrackRef,
)
from reaper_toolkit.errors import OwnershipError, ResourceBusyError
from reaper_toolkit.midi import encode_midi_event

from .conftest import LuaHost

pytestmark = pytest.mark.lua_integration


def phrase(pitch: int = 36) -> MidiPhrase:
    return MidiPhrase.create(
        960,
        1920,
        [MidiNote(start_ppq=0, duration_ppq=240, channel=9, pitch=pitch, velocity=100)],
    )


def client(host: LuaHost, app: str, instance: str) -> AsyncReaperClient:
    return AsyncReaperClient(
        ClientIdentity(app, "1", instance, instance),
        {
            "project.state",
            "transport.control",
            "track.read",
            "track.binding",
            "midi.item",
            "midi.preview",
            "midi.udp_audition",
            "resource.read",
        },
        port=host.tcp_port,
        auto_reconnect=False,
    )


@pytest.mark.asyncio
async def test_transport_cursor_track_binding_and_state_events(lua_host: LuaHost):
    subject = client(lua_host, "com.example.workflow", "commands")
    states = []
    subject.on_state(states.append)
    await subject.connect()
    try:
        assert (await subject.set_transport(playing=True))["playing"] is True
        assert (await subject.set_edit_cursor(ppq=3840))["ppq"] == 3840
        captured = await subject.capture_selected_track(role="drums", bind=True)
        assert captured.binding == "explicit"
        resolved = await subject.resolve_bound_track(
            role="drums", fallback=TrackRef(name="missing")
        )
        assert resolved.guid == captured.guid
        await subject.clear_track_binding(role="drums")
        created = await subject.resolve_track(
            TrackRef(name="Created Track", create=TrackCreate.IF_MISSING)
        )
        assert created.created is True
        await asyncio.sleep(0.25)
        assert states
        assert states[-1].project.edit_cursor.ppq == 3840
        await subject.set_transport(playing=False)
    finally:
        await subject.close()


@pytest.mark.asyncio
async def test_durable_midi_insert_replace_idempotency_and_app_isolation(lua_host: LuaHost):
    one = client(lua_host, "com.example.one", "items-one")
    two = client(lua_host, "com.example.two", "items-two")
    await one.connect()
    await two.connect()
    try:
        inserted = await one.insert_midi_item(
            TrackRef(name="RPTK Test Track"),
            phrase(),
            {"test": "insert"},
            options=InsertOptions(start_ppq=960),
            operation_id="insert-1",
        )
        repeated = await one.insert_midi_item(
            TrackRef(name="RPTK Test Track"),
            phrase(),
            {"test": "insert"},
            options=InsertOptions(start_ppq=960),
            operation_id="insert-1",
        )
        assert repeated["resource_id"] == inserted["resource_id"]
        resources = await one.list_resources(kind="midi_item")
        assert [resource.resource_id for resource in resources] == [inserted["resource_id"]]
        assert await two.list_resources(kind="midi_item") == ()

        replaced = await one.replace_midi_item(
            inserted["resource_id"],
            phrase(38),
            {"test": "replace"},
            options=ReplaceOptions(advance_cursor="end"),
            operation_id="replace-1",
        )
        assert replaced["resource_id"] == inserted["resource_id"]
        with pytest.raises(OwnershipError):
            await two.replace_midi_item(inserted["resource_id"], phrase(40))
    finally:
        await two.close()
        await one.close()


@pytest.mark.asyncio
async def test_large_resource_response_drains_across_partial_writes(lua_host: LuaHost):
    subject = client(lua_host, "com.example.large", "large-response")
    await subject.connect()
    try:
        for index in range(12):
            await subject.insert_midi_item(
                TrackRef(name="RPTK Test Track"),
                phrase(36 + index),
                {"label": f"resource-{index}-" + ("x" * 120)},
                options=InsertOptions(start_ppq=index * 1920),
                operation_id=f"large-{index}",
            )
        resources = await subject.list_resources(kind="midi_item")
        assert len(resources) == 12
        assert sum(len(resource.metadata["label"]) for resource in resources) > 1500
    finally:
        await subject.close()


@pytest.mark.asyncio
async def test_preview_ownership_update_stop_and_disconnect_cleanup(lua_host: LuaHost):
    one = client(lua_host, "com.example.preview.one", "preview-one")
    two = client(lua_host, "com.example.preview.two", "preview-two")
    await one.connect()
    await two.connect()
    try:
        preview = await one.prepare_midi_preview(
            TrackRef(name="RPTK Test Track"),
            phrase(),
            PreviewOptions(count_in=False),
        )
        assert preview.active
        with pytest.raises(ResourceBusyError):
            await two.prepare_midi_preview(
                TrackRef(name="RPTK Second Track"),
                phrase(38),
                PreviewOptions(count_in=False),
            )
        updated = await one.update_midi_preview(preview.resource_id, phrase(42))
        assert updated.pending_revision == phrase(42).revision
        assert updated.status == "switch_pending"
        stopped = await one.stop_midi_preview(preview.resource_id)
        assert stopped.active is False

        preview = await one.prepare_midi_preview(
            TrackRef(name="RPTK Test Track"),
            phrase(),
            PreviewOptions(count_in=False),
        )
        await one.close()
        await asyncio.sleep(0.1)
        replacement = await two.prepare_midi_preview(
            TrackRef(name="RPTK Second Track"),
            phrase(38),
            PreviewOptions(count_in=False),
        )
        assert replacement.resource_id != preview.resource_id
        await two.stop_midi_preview(replacement.resource_id)
    finally:
        await two.close()
        await one.close()


async def wait_for_midi(
    host: LuaHost, count: int, timeout: float = 2
) -> list[tuple[int, int, int]]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        messages = host.midi_messages()
        if len(messages) >= count:
            return messages
        await asyncio.sleep(0.02)
    return host.midi_messages()


async def wait_for_midi_message(
    host: LuaHost, expected: tuple[int, int, int], timeout: float = 2
) -> list[tuple[int, int, int]]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        messages = host.midi_messages()
        if expected in messages:
            return messages
        await asyncio.sleep(0.02)
    return host.midi_messages()


@pytest.mark.asyncio
async def test_udp_delivery_order_reset_invalid_token_and_session_cleanup(lua_host: LuaHost):
    one = client(lua_host, "com.example.udp.one", "udp-one")
    two = client(lua_host, "com.example.udp.two", "udp-two")
    await one.connect()
    await two.connect()
    try:
        one.send_midi_event(0x99, 36, 100, delay_seconds=0.08)
        two.send_midi_event(0x99, 38, 100)
        one.send_midi_event(0x89, 36, 0, delay_seconds=0.1)
        messages = await wait_for_midi(lua_host, 3)
        assert messages[:3] == [(0x99, 38, 100), (0x99, 36, 100), (0x89, 36, 0)]

        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
            udp.sendto(
                encode_midi_event("00" * 16, 0, 1, 0, 0x99, 40, 100),
                ("127.0.0.1", lua_host.udp_port),
            )
        await asyncio.sleep(0.1)
        assert (0x99, 40, 100) not in lua_host.midi_messages()

        one.send_midi_event(0x99, 41, 100)
        await wait_for_midi(lua_host, 4)
        one.reset_midi_generation()
        messages = await wait_for_midi(lua_host, 5)
        assert (0x89, 41, 0) in messages

        two.send_midi_event(0x99, 43, 100)
        await wait_for_midi(lua_host, 6)
        await two.close()
        messages = await wait_for_midi_message(lua_host, (0x89, 43, 0))
        assert (0x89, 43, 0) in messages
    finally:
        await two.close()
        await one.close()
