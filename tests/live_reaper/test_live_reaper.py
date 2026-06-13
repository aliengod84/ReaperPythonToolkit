from __future__ import annotations

import asyncio

import pytest

from reaper_toolkit import (
    AsyncReaperClient,
    ClientIdentity,
    ConnectionState,
    InsertOptions,
    MidiNote,
    MidiPhrase,
    PreviewOptions,
    TrackCreate,
    TrackRef,
)

pytestmark = pytest.mark.live_reaper


def phrase(pitch: int) -> MidiPhrase:
    return MidiPhrase.create(
        960,
        1920,
        [MidiNote(start_ppq=0, duration_ppq=240, channel=9, pitch=pitch, velocity=96)],
    )


@pytest.mark.asyncio
async def test_live_lifecycle_heartbeat_and_two_client_isolation(live_client, live_endpoint):
    host, port = live_endpoint
    second = AsyncReaperClient(
        ClientIdentity(
            "com.rptk.live_validation",
            "0.2.0",
            "RPTK Live Validation 2",
        ),
        {"project.state"},
        host=host,
        port=port,
        auto_reconnect=False,
    )
    events = []
    live_client.on_event(events.append)
    await second.connect()
    try:
        assert live_client.last_status.state == ConnectionState.READY
        assert second.last_status.session_id != live_client.last_status.session_id
        first_second_session = second.last_status.session_id
        await asyncio.sleep(1.2)
        assert any(event.get("event") == "bridge.heartbeat" for event in events)
        state = await live_client.refresh_state()
        assert len(state.sessions) >= 2
        await second.close()
        await second.connect()
        assert second.last_status.session_id != first_second_session
    finally:
        await second.close()


@pytest.mark.asyncio
async def test_live_transport_track_midi_preview_and_udp(live_client):
    initial = live_client.last_state
    assert initial is not None
    track = await live_client.resolve_track(
        TrackRef(name="RPTK Integration Test", create=TrackCreate.IF_MISSING)
    )
    assert track.exists

    await live_client.set_edit_cursor(ppq=initial.project.edit_cursor.ppq)
    await live_client.set_transport(playing=False)
    inserted = await live_client.insert_midi_item(
        TrackRef(guid=track.guid),
        phrase(36),
        {"purpose": "rptk-live-validation"},
        options=InsertOptions(start_ppq=initial.project.edit_cursor.ppq),
        operation_id="rptk-live-insert-v1",
    )
    replaced = await live_client.replace_midi_item(
        inserted["resource_id"],
        phrase(38),
        {"purpose": "rptk-live-validation-replaced"},
        operation_id="rptk-live-replace-v1",
    )
    assert replaced["resource_id"] == inserted["resource_id"]

    preview = await live_client.prepare_midi_preview(
        TrackRef(guid=track.guid),
        phrase(42),
        PreviewOptions(count_in=False, repeat_guard=True, metronome_guard=True),
    )
    try:
        assert preview.active
        live_client.send_midi_event(0x99, 42, 90)
        await asyncio.sleep(0.1)
        live_client.reset_midi_generation()
    finally:
        stopped = await live_client.stop_midi_preview(preview.resource_id)
        assert stopped.active is False

    restored = await live_client.refresh_state()
    assert restored.project.repeat_enabled == initial.project.repeat_enabled
