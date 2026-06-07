import pytest

from reaper_toolkit import (
    AsyncReaperClient,
    ClientIdentity,
    ConnectionState,
    MissingCapabilityError,
    TrackRef,
)

from .fake_host import FakeHost


@pytest.mark.asyncio
async def test_two_clients_reach_ready_and_issue_commands():
    async with FakeHost() as host:
        clients = [
            AsyncReaperClient(
                ClientIdentity(f"com.example.client{i}", "1", f"Client {i}"),
                {"project.state", "transport.control"},
                port=host.port,
                auto_reconnect=False,
            )
            for i in range(2)
        ]
        for client in clients:
            await client.connect()
            assert client.last_status.state == ConnectionState.READY
            assert (await client.refresh_state()).state_seq == 2
            assert await client.set_transport(playing=True) == {"playing": True}
            assert (await client.resolve_track(TrackRef(name="Track"))).guid == "track-1"
        for client in clients:
            await client.close()


@pytest.mark.asyncio
async def test_missing_required_capability_is_incompatible():
    async with FakeHost() as host:
        client = AsyncReaperClient(
            ClientIdentity("com.example.bad", "1", "Bad Client"),
            {"not.supported"},
            port=host.port,
            auto_reconnect=False,
        )
        with pytest.raises(MissingCapabilityError):
            await client.connect()
        assert client.last_status.state == ConnectionState.INCOMPATIBLE

