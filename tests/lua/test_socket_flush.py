from __future__ import annotations

from .test_host_modules import run_lua


def test_flush_uses_small_indexed_chunks_for_reaper_luasocket():
    run_lua(
        """
local sent_data = {}
local socket = {}
function socket:send(data, first, last)
  assert(first == 1 and last == #data)
  if #data > 512 then return 0 end
  sent_data[#sent_data + 1] = data
  return #data
end
local io = dofile(root .. "rptk_socket.lua")({ chunk_size = 512 })
local payload = string.rep("a", 5092)
local client = { socket = socket, outgoing = payload, close = false }
io.flush(client)
assert(client.outgoing == "")
assert(client.close == false)
assert(#sent_data == 10)
assert(table.concat(sent_data) == payload)
"""
    )


def test_flush_preserves_unsent_tail_after_partial_timeout():
    run_lua(
        """
local calls = 0
local socket = {}
function socket:send(data, first, last)
  calls = calls + 1
  if calls == 1 then return nil, "timeout", 123 end
  return #data
end
local io = dofile(root .. "rptk_socket.lua")({ chunk_size = 512 })
local payload = string.rep("b", 700)
local client = { socket = socket, outgoing = payload, close = false }
io.flush(client)
assert(client.outgoing == payload:sub(124))
assert(client.close == false)
io.flush(client)
assert(client.outgoing == "")
"""
    )


def test_flush_marks_closed_peer_without_logging_normal_disconnect():
    run_lua(
        """
local logs = {}
local socket = {}
function socket:send() return nil, "closed", 0 end
local io = dofile(root .. "rptk_socket.lua")({
  log = function(message) logs[#logs + 1] = message end,
})
local client = { socket = socket, outgoing = "payload", close = false }
io.flush(client)
assert(client.close == true)
assert(client.outgoing == "payload")
assert(#logs == 0)
"""
    )
