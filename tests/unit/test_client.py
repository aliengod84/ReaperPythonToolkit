from __future__ import annotations

import concurrent.futures

import pytest

from reaper_toolkit import CommandTimeoutError, ReaperClient


class _TimedOutFuture:
    def __init__(self) -> None:
        self.result_timeout = None
        self.cancelled = False

    def result(self, timeout=None):
        self.result_timeout = timeout
        raise concurrent.futures.TimeoutError

    def cancel(self) -> None:
        self.cancelled = True


async def _command() -> None:
    return None


def test_blocking_wrapper_allows_async_timeout_to_win(monkeypatch) -> None:
    pending = _TimedOutFuture()
    monkeypatch.setattr(
        "reaper_toolkit.client.asyncio.run_coroutine_threadsafe",
        lambda coroutine, loop: pending,
    )
    client = ReaperClient.__new__(ReaperClient)
    client._loop = object()
    coroutine = _command()

    with pytest.raises(
        CommandTimeoutError,
        match="timed out waiting for command completion after 10s",
    ):
        client._run(coroutine, timeout=10.0)

    coroutine.close()
    assert pending.result_timeout == 11.0
    assert pending.cancelled
