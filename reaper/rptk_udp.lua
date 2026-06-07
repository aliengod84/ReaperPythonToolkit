return function(sessions)
  local udp = { socket = nil, max_queue = 4096 }

  local function bytes_to_hex(data)
    local result = {}
    for index = 1, #data do result[#result + 1] = string.format("%02x", data:byte(index)) end
    return table.concat(result)
  end

  function udp.bind(socket, host, port)
    local endpoint, err = socket.udp()
    if not endpoint then return nil, err end
    endpoint:settimeout(0)
    local ok, bind_err = endpoint:setsockname(host, port)
    if not ok then endpoint:close(); return nil, bind_err end
    udp.socket = endpoint
    return true
  end

  local function all_notes_off()
    for channel = 0, 15 do reaper.StuffMIDIMessage(0, 0xB0 | channel, 123, 0) end
  end

  function udp.poll(now)
    if not udp.socket then return end
    for _ = 1, 128 do
      local packet, ip = udp.socket:receivefrom()
      if not packet then break end
      if ip == "127.0.0.1" and #packet >= 26 and packet:sub(1, 4) == "RPTK" then
        local major, packet_type = string.unpack(">I1I1", packet, 5)
        local token = bytes_to_hex(packet:sub(7, 22))
        local session = major == 1 and sessions.by_token(token) or nil
        if session then
          local generation, sequence, position = string.unpack(">I4I4", packet, 23)
          if packet_type == 2 and generation >= session.generation then
            session.generation, session.udp_queue = generation, {}
            all_notes_off()
          elseif packet_type == 1 and generation >= session.generation and #packet == 41 then
            local delay, status, data1, data2 = string.unpack(">dI1I1I1", packet, position)
            session.generation = generation
            if #session.udp_queue < udp.max_queue then
              session.udp_queue[#session.udp_queue + 1] = {
                at = now + math.max(0, delay), sequence = sequence,
                status = status, data1 = data1, data2 = data2,
              }
            end
          end
        end
      end
    end
    for _, session in pairs(sessions.active) do
      table.sort(session.udp_queue, function(a, b)
        return a.at == b.at and a.sequence < b.sequence or a.at < b.at
      end)
      while session.udp_queue[1] and session.udp_queue[1].at <= now do
        local event = table.remove(session.udp_queue, 1)
        reaper.StuffMIDIMessage(0, event.status, event.data1, event.data2)
      end
    end
  end

  function udp.cleanup_session(session)
    session.udp_queue = {}
    all_notes_off()
  end

  function udp.close()
    if udp.socket then udp.socket:close(); udp.socket = nil end
  end
  return udp
end
