"""Heartbeat / freshness resilience under a busy single-threaded host.

These cover the regression where the client dropped and auto-reconnected every
~6-8s under normal command load: the heartbeat loop used to die permanently on a
single command timeout, after which the lease expired. See async_client
_heartbeat_loop / _freshness_loop.
"""
from __future__ import annotations

import asyncio

from reaper_toolkit import AsyncReaperClient, ClientIdentity, ConnectionState, TrackRef
from reaper_toolkit.errors import CommandTimeoutError

from .fake_host import FakeHost

IDENTITY = ClientIdentity("com.example.resilience", "1", "Resilience")


async def _connected_client(host: FakeHost) -> AsyncReaperClient:
    client = AsyncReaperClient(
        IDENTITY, {"project.state"}, port=host.port, auto_reconnect=True
    )
    await client.connect()
    return client


async def test_heartbeat_survives_transient_command_timeout():
    # Host answers every command, but slowly enough that a session.heartbeat probe
    # (and an app command) can exceed the bare heartbeat interval. The heartbeat
    # loop must keep probing rather than die, and the connection must not drop.
    async with FakeHost(
        command_delay=0.25,
        heartbeat_interval_ms=100,
        lease_timeout_ms=1000,
    ) as host:
        client = await _connected_client(host)
        try:
            # Span several heartbeat intervals and a probe timeout window.
            await asyncio.sleep(1.5)
            assert client.last_status.state == ConnectionState.READY
            assert host.clients == 1  # never reconnected
            assert client._heartbeat_task is not None
            assert not client._heartbeat_task.done()
        finally:
            await client.close()


async def test_connection_survives_burst_of_slow_commands():
    # The host emits its own bridge.heartbeat events and answers commands slowly.
    # A burst of concurrent slow commands spanning longer than the lease must not
    # cause a reconnect: inbound heartbeats + surviving probes keep freshness.
    async with FakeHost(
        command_delay=0.2,
        slow_methods={"track.resolve"},
        emit_host_heartbeats=True,
        heartbeat_interval_ms=100,
        lease_timeout_ms=1000,
    ) as host:
        client = await _connected_client(host)
        try:
            ref = TrackRef(name="MMG Drums", role="drums")
            # Individual commands may time out under serialized host load; that is
            # fine. What must NOT happen is a connection drop / reconnect. Swallow
            # per-command results and assert only on connection liveness.
            await asyncio.gather(
                *(client.resolve_track(ref, timeout=2.0) for _ in range(10)),
                return_exceptions=True,
            )
            await asyncio.sleep(0.3)
            assert client.last_status.state == ConnectionState.READY
            assert host.clients == 1
        finally:
            await client.close()


async def test_freshness_maintained_by_inbound_host_heartbeats():
    # The host never answers session.heartbeat, but emits bridge.heartbeat events.
    # With no app traffic, the inbound events alone must keep the connection fresh
    # past the lease window (no false "host heartbeat timed out").
    async with FakeHost(
        emit_host_heartbeats=True,
        heartbeat_interval_ms=100,
        lease_timeout_ms=800,
        answer_session_heartbeat=False,
    ) as host:
        client = await _connected_client(host)
        try:
            await asyncio.sleep(1.5)  # ~2x the lease
            assert client.last_status.state == ConnectionState.READY
            assert host.clients == 1
        finally:
            await client.close()


async def test_heartbeat_loop_does_not_exit_on_single_timeout():
    # Unit-level: drive _heartbeat_loop directly against a request() that raises a
    # CommandTimeoutError once, then succeeds. The loop must not return early.
    client = AsyncReaperClient(IDENTITY, {"project.state"})
    client._heartbeat_interval = 0.01
    client._lease_timeout = 0.1
    client._writer = object()  # non-None so the loop proceeds to request()

    calls = 0

    async def fake_request(method, *args, **kwargs):
        nonlocal calls
        calls += 1
        if calls == 1:
            raise CommandTimeoutError("transient")
        return {}

    client.request = fake_request  # type: ignore[assignment]

    task = asyncio.create_task(client._heartbeat_loop())
    await asyncio.sleep(0.1)
    client._closing = True
    await asyncio.wait_for(task, 1.0)
    assert calls >= 2  # survived the first timeout and probed again
