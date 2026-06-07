from __future__ import annotations

import asyncio
import socket

import pytest

from reaper_toolkit import AsyncReaperClient, ClientIdentity, ConnectionState

from .fake_host import FakeHost


@pytest.mark.asyncio
async def test_start_returns_immediately_and_reconnects_when_host_appears():
    probe = socket.socket()
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    probe.close()
    client = AsyncReaperClient(
        ClientIdentity("com.example.reconnect", "1", "Reconnect"),
        {"project.state"},
        port=port,
        auto_reconnect=True,
    )
    await asyncio.wait_for(client.start(), 0.1)
    await asyncio.sleep(0.1)
    assert client.last_status.state in {
        ConnectionState.ERROR,
        ConnectionState.RECONNECTING,
    }
    host = FakeHost()
    host.server = await asyncio.start_server(host._client, "127.0.0.1", port)
    host.port = port
    try:
        await client.wait_until_ready(3.0)
        assert client.last_status.state == ConnectionState.READY
    finally:
        await client.close()
        host.server.close()
        await host.server.wait_closed()
