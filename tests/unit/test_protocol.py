import json
from pathlib import Path

import jsonschema
import pytest

from reaper_toolkit.midi import EVENT_STRUCT, RESET_STRUCT, encode_midi_event, encode_reset
from reaper_toolkit.protocol import LineCodec, ProtocolError, encode_message

ROOT = Path(__file__).parents[2]


@pytest.mark.parametrize("name,schema", [("hello", "hello"), ("hello_ack", "hello_ack")])
def test_fixture_matches_schema(name, schema):
    value = json.loads((ROOT / "tests/protocol_fixtures" / f"{name}.json").read_text())
    document = json.loads((ROOT / "schemas" / f"{schema}.schema.json").read_text())
    registry = jsonschema.validators.validator_for(document)
    registry.check_schema(document)
    store = {
        path.name: json.loads(path.read_text())
        for path in (ROOT / "schemas").glob("*.schema.json")
    }
    resolver = jsonschema.RefResolver.from_schema(document, store=store)
    jsonschema.validate(value, document, resolver=resolver)


def test_line_codec_handles_fragmentation_and_empty_lines():
    codec = LineCodec()
    assert codec.feed(b"\n{\"a\":") == []
    assert codec.feed(b"1}\n") == [{"a": 1}]


def test_line_codec_rejects_invalid_data():
    with pytest.raises(ProtocolError):
        LineCodec().feed(b"\xff\n")


def test_encode_message_is_compact():
    assert encode_message({"a": 1}) == b'{"a":1}\n'


def test_udp_binary_layouts():
    token = "00112233445566778899aabbccddeeff"
    assert len(encode_midi_event(token, 1, 2, 0.1, 0x90, 60, 100)) == EVENT_STRUCT.size
    assert len(encode_reset(token, 2)) == RESET_STRUCT.size
