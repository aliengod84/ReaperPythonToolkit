from __future__ import annotations

import asyncio
import socket
import time

import pytest

from reaper_toolkit import AsyncReaperClient, ClientIdentity, ConnectionState
from reaper_toolkit.errors import HandshakeError, MissingCapabilityError

from .conftest import LuaHost

pytestmark = pytest.mark.lua_integration


def client(host: LuaHost, instance: str, *, reconnect: bool = False) -> AsyncReaperClient:
    return AsyncReaperClient(
        ClientIdentity("com.example.lifecycle", "1", "Lifecycle", instance),
        {"project.state"},
        port=host.tcp_port,
        auto_reconnect=reconnect,
    )


@pytest.mark.asyncio
async def test_connect_initial_state_heartbeat_and_graceful_close(lua_host: LuaHost):
    events: list[str] = []
    subject = client(lua_host, "graceful")
    subject.on_event(lambda event: events.append(str(event["event"])))

    await subject.connect()
    assert subject.last_status.state == ConnectionState.READY
    assert subject.last_status.session_id
    assert subject.last_state is not None
    assert subject.last_state.project.guid == "rptk-headless-project.rpp"
    await asyncio.sleep(1.2)
    assert "bridge.heartbeat" in events

    await subject.close()
    assert subject.last_status.state == ConnectionState.DISCONNECTED


@pytest.mark.asyncio
async def test_missing_capability_is_rejected(lua_host: LuaHost):
    subject = AsyncReaperClient(
        ClientIdentity("com.example.lifecycle", "1", "Missing", "missing"),
        {"not.supported"},
        port=lua_host.tcp_port,
        auto_reconnect=False,
    )
    with pytest.raises(MissingCapabilityError):
        await subject.connect()
    assert subject.last_status.state == ConnectionState.INCOMPATIBLE


@pytest.mark.asyncio
async def test_two_clients_have_distinct_sessions_and_duplicate_instance_is_rejected(
    lua_host: LuaHost,
):
    one = client(lua_host, "one")
    two = client(lua_host, "two")
    duplicate = client(lua_host, "one")
    try:
        await one.connect()
        await two.connect()
        assert one.last_status.session_id != two.last_status.session_id
        state = await one.refresh_state()
        assert {session["session_id"] for session in state.sessions} == {
            one.last_status.session_id,
            two.last_status.session_id,
        }
        with pytest.raises(HandshakeError, match="already connected"):
            await duplicate.connect()
    finally:
        await duplicate.close()
        await two.close()
        await one.close()


@pytest.mark.asyncio
async def test_abrupt_host_loss_reconnects_without_replaying_commands(lua_host: LuaHost):
    subject = client(lua_host, "reconnect", reconnect=True)
    await subject.connect()
    first_session = subject.last_status.session_id

    lua_host.kill()
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline and subject.last_status.state == ConnectionState.READY:
        await asyncio.sleep(0.05)
    assert subject.last_status.state in {
        ConnectionState.ERROR,
        ConnectionState.RECONNECTING,
    }

    lua_host.start()
    await subject.wait_until_ready(4)
    assert subject.last_status.session_id != first_session
    assert (await subject.refresh_state()).project.ppq == 960
    await subject.close()


def test_handshake_timeout_closes_idle_client(lua_host: LuaHost):
    connection = socket.create_connection(("127.0.0.1", lua_host.tcp_port), timeout=4)
    try:
        connection.settimeout(4)
        assert connection.recv(1) == b""
    finally:
        connection.close()


def test_session_lease_expires_without_heartbeats(raw_connection):
    connection, stream = raw_connection
    from .conftest import hello, read_json, send_json

    send_json(stream, hello(instance_id="lease"))
    assert read_json(stream)["ok"] is True
    connection.settimeout(7)
    deadline = time.monotonic() + 7
    while time.monotonic() < deadline:
        if stream.readline() == b"":
            break
    else:
        pytest.fail("host did not close the expired session")
