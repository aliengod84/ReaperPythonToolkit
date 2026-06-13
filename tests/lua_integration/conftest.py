from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pytest

ROOT = Path(__file__).parents[2]
RUNNER = Path(__file__).with_name("reaper_host_runner.lua")


def unused_udp_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


def unused_tcp_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


def lua_command() -> str:
    configured = os.environ.get("RPTK_LUA")
    command = configured or shutil.which("lua") or ""
    if not command:
        pytest.skip("Lua integration requires Lua with LuaSocket; set RPTK_LUA")
    probe = subprocess.run(
        [command, "-e", "assert(require('socket')); assert(string.pack)"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    if probe.returncode:
        pytest.skip(
            "Lua integration requires Lua 5.3+ with LuaSocket; "
            f"set RPTK_LUA ({probe.stderr.strip()})"
        )
    return command


@dataclass
class LuaHost:
    command: str
    workdir: Path
    tcp_port: int
    udp_port: int
    process: subprocess.Popen[str] | None = None

    @property
    def ready_path(self) -> Path:
        return self.workdir / "ready"

    @property
    def stop_path(self) -> Path:
        return self.workdir / "stop"

    @property
    def midi_log_path(self) -> Path:
        return self.workdir / "midi.log"

    def start(self) -> None:
        self.stop_path.unlink(missing_ok=True)
        self.ready_path.unlink(missing_ok=True)
        self.process = subprocess.Popen(
            [
                self.command,
                str(RUNNER),
                str(ROOT),
                str(self.tcp_port),
                str(self.udp_port),
                str(self.ready_path),
                str(self.stop_path),
                str(self.midi_log_path),
            ],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if self.ready_path.exists():
                return
            if self.process.poll() is not None:
                stdout, stderr = self.process.communicate()
                pytest.fail(f"Lua host exited during startup:\n{stdout}\n{stderr}")
            time.sleep(0.02)
        self.kill()
        pytest.fail("Lua host did not become ready within 5 seconds")

    def stop(self) -> None:
        if not self.process or self.process.poll() is not None:
            return
        self.stop_path.touch()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.kill()

    def kill(self) -> None:
        if self.process and self.process.poll() is None:
            self.process.kill()
            self.process.wait(timeout=3)

    def restart(self) -> None:
        self.stop()
        self.start()

    def midi_messages(self) -> list[tuple[int, int, int]]:
        if not self.midi_log_path.exists():
            return []
        return [
            tuple(map(int, line.split(",")))
            for line in self.midi_log_path.read_text().splitlines()
            if line
        ]

    def diagnostics(self) -> str:
        if not self.process or self.process.poll() is None:
            return ""
        stdout, stderr = self.process.communicate()
        return f"stdout:\n{stdout}\nstderr:\n{stderr}"


@pytest.fixture
def lua_host(tmp_path: Path) -> LuaHost:
    host = LuaHost(lua_command(), tmp_path, unused_tcp_port(), unused_udp_port())
    host.start()
    try:
        yield host
    finally:
        host.stop()
        if host.process and host.process.returncode not in {0, None}:
            pytest.fail(host.diagnostics())


def hello(
    *,
    request_id: str = "hello-1",
    app_id: str = "com.example.raw",
    instance_id: str = "raw-1",
    required: list[str] | None = None,
    major: int = 1,
    min_minor: int = 1,
    max_minor: int = 1,
) -> dict[str, Any]:
    return {
        "protocol": "rptk",
        "type": "hello",
        "request_id": request_id,
        "protocol_range": {
            "major": major,
            "min_minor": min_minor,
            "max_minor": max_minor,
        },
        "client": {
            "app_id": app_id,
            "app_version": "1",
            "display_name": "Raw Test",
            "instance_id": instance_id,
            "sdk_version": "test",
        },
        "required_capabilities": required or [],
        "optional_capabilities": [],
    }


def send_json(stream, value: dict[str, Any]) -> None:
    stream.write(json.dumps(value, separators=(",", ":")).encode() + b"\n")
    stream.flush()


def read_json(stream) -> dict[str, Any]:
    line = stream.readline()
    assert line, "host closed before sending a response"
    return json.loads(line)


@pytest.fixture
def raw_connection(lua_host: LuaHost):
    connection = socket.create_connection(("127.0.0.1", lua_host.tcp_port), timeout=3)
    stream = connection.makefile("rwb")
    try:
        yield connection, stream
    finally:
        stream.close()
        connection.close()
