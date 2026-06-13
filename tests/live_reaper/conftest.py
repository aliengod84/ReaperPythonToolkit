from __future__ import annotations

import os

import pytest

from reaper_toolkit import AsyncReaperClient, ClientIdentity


def pytest_collection_modifyitems(items):
    if os.environ.get("RPTK_LIVE_REAPER") == "1":
        return
    skip = pytest.mark.skip(
        reason="live Reaper tests require RPTK_LIVE_REAPER=1 and a running host"
    )
    for item in items:
        if "live_reaper" in item.keywords:
            item.add_marker(skip)


@pytest.fixture
def live_endpoint() -> tuple[str, int]:
    return (
        os.environ.get("RPTK_LIVE_HOST", "127.0.0.1"),
        int(os.environ.get("RPTK_LIVE_TCP_PORT", "9901")),
    )


@pytest.fixture
async def live_client(live_endpoint):
    host, port = live_endpoint
    client = AsyncReaperClient(
        ClientIdentity("com.rptk.live_validation", "0.2.0", "RPTK Live Validation"),
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
        host=host,
        port=port,
        auto_reconnect=False,
    )
    await client.connect()
    initial = client.last_state
    try:
        yield client
    finally:
        if initial is not None and client.last_status.ready:
            await client.set_transport(playing=False)
            await client.set_edit_cursor(ppq=initial.project.edit_cursor.ppq)
            if initial.project.playing:
                await client.set_transport(playing=True)
        await client.close()
