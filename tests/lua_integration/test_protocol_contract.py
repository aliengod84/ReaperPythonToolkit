from __future__ import annotations

import json
import socket

import pytest

from .conftest import hello, read_json, send_json

pytestmark = pytest.mark.lua_integration


def request(request_id: str, method: str, payload: dict | None = None) -> dict:
    return {
        "protocol": "rptk",
        "protocol_major": 1,
        "type": "request",
        "request_id": request_id,
        "method": method,
        "payload": payload or {},
    }


def read_responses(stream, expected: set[str]) -> dict[str, dict]:
    responses = {}
    while set(responses) != expected:
        value = read_json(stream)
        if value.get("type") == "response":
            responses[value["request_id"]] = value
    return responses


@pytest.mark.parametrize(
    ("message", "code"),
    [
        (hello(major=2), "protocol_major_mismatch"),
        (hello(min_minor=2, max_minor=3), "protocol_minor_unsupported"),
        (hello(app_id="invalid"), "invalid_client_identity"),
        (hello(required=["missing.feature"]), "missing_capability"),
    ],
)
def test_handshake_rejections(raw_connection, message, code):
    _, stream = raw_connection
    send_json(stream, message)
    response = read_json(stream)
    assert response["ok"] is False
    assert response["error"]["code"] == code


def test_fragmented_hello_and_multiple_requests_in_one_write(raw_connection):
    _, stream = raw_connection
    encoded = json.dumps(hello(instance_id="fragmented")).encode() + b"\n"
    for chunk in (encoded[:7], encoded[7:31], encoded[31:]):
        stream.write(chunk)
        stream.flush()
    assert read_json(stream)["ok"] is True

    frames = (
        json.dumps(request("state", "state.get"), separators=(",", ":"))
        + "\n"
        + json.dumps(request("heartbeat", "session.heartbeat"), separators=(",", ":"))
        + "\n"
    )
    stream.write(frames.encode())
    stream.flush()
    responses = read_responses(stream, {"state", "heartbeat"})
    assert responses["state"]["result"]["project"]["ppq"] == 960
    assert "lease_deadline" in responses["heartbeat"]["result"]


def test_request_cache_and_conflicting_request_id(raw_connection):
    _, stream = raw_connection
    send_json(stream, hello(instance_id="cache"))
    assert read_json(stream)["ok"] is True
    original = request("same-id", "state.get")
    send_json(stream, original)
    first = read_responses(stream, {"same-id"})["same-id"]
    send_json(stream, original)
    second = read_responses(stream, {"same-id"})["same-id"]
    assert second == first

    send_json(stream, request("same-id", "transport.set", {"playing": True}))
    conflict = read_responses(stream, {"same-id"})["same-id"]
    assert conflict["ok"] is False
    assert conflict["error"]["code"] == "request_id_conflict"


def test_unknown_method_returns_structured_error(raw_connection):
    _, stream = raw_connection
    send_json(stream, hello(instance_id="unknown"))
    assert read_json(stream)["ok"] is True
    send_json(stream, request("unknown", "does.not.exist"))
    response = read_responses(stream, {"unknown"})["unknown"]
    assert response["ok"] is False
    assert response["error"]["code"] == "invalid_request"


def test_malformed_json_frame_is_closed(lua_host):
    connection = socket.create_connection(("127.0.0.1", lua_host.tcp_port), timeout=3)
    try:
        connection.sendall(b"not json\n")
        connection.settimeout(3)
        assert connection.recv(1) == b""
    finally:
        connection.close()


def test_non_hello_first_envelope_is_rejected(raw_connection):
    _, stream = raw_connection
    send_json(stream, {"protocol": "rptk", "type": "request", "request_id": "bad"})
    response = read_json(stream)
    assert response["ok"] is False
    assert response["error"]["code"] == "not_rptk_host"


def test_oversized_frame_is_closed(lua_host):
    connection = socket.create_connection(("127.0.0.1", lua_host.tcp_port), timeout=3)
    try:
        try:
            connection.sendall(b"{" + b"x" * (1024 * 1024 + 1))
        except ConnectionError:
            return
        connection.settimeout(3)
        assert connection.recv(1) == b""
    finally:
        connection.close()
