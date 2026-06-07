return function(json)
  local protocol = {}
  protocol.MAJOR = 1
  protocol.MINOR = 1
  protocol.MAX_MESSAGE = 1024 * 1024
  protocol.CAPABILITIES = {
    "project.state", "transport.read", "transport.control", "track.read",
    "track.resolve", "track.capture_selection", "midi.item", "midi.preview",
    "midi.udp_audition", "settings.repeat_guard", "settings.metronome_guard",
    "session.multi_client", "track.binding", "resource.read",
  }

  function protocol.error(code, message, retryable, details)
    return {
      code = code, message = message, retryable = retryable == true,
      details = details or {},
    }
  end

  function protocol.response(request, ok, value)
    local result = {
      protocol = "rptk", protocol_major = 1, type = "response",
      request_id = request.request_id, ok = ok,
    }
    if ok then result.result = value or {} else result.error = value end
    return result
  end

  function protocol.event(name, sequence, payload)
    return {
      protocol = "rptk", protocol_major = 1, type = "event",
      event = name, event_seq = sequence, payload = payload or {},
    }
  end

  function protocol.decode(line)
    if #line > protocol.MAX_MESSAGE then return nil, "message_too_large" end
    local ok, value = pcall(json.decode, line)
    if not ok or type(value) ~= "table" then return nil, "invalid_json" end
    return value
  end

  function protocol.encode(value)
    return json.encode(value) .. "\n"
  end

  return protocol
end
