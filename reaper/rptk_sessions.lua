return function(protocol)
  local sessions = { active = {}, instances = {} }

  local function random_hex(bytes)
    local output = {}
    for _ = 1, bytes do output[#output + 1] = string.format("%02x", math.random(0, 255)) end
    return table.concat(output)
  end

  function sessions.create(client, socket, now)
    local instance = client.instance_id
    if sessions.instances[instance] then return nil, "duplicate_instance" end
    local session = {
      id = random_hex(16), udp_token = random_hex(16), client = client,
      socket = socket, lease_deadline = now + 5, event_seq = 0,
      resources = {}, response_cache = {}, generation = 0, udp_queue = {},
      active_notes = {},
    }
    sessions.active[session.id] = session
    sessions.instances[instance] = session.id
    return session
  end

  function sessions.touch(session, now) session.lease_deadline = now + 5 end

  function sessions.remove(session)
    sessions.active[session.id] = nil
    sessions.instances[session.client.instance_id] = nil
  end

  function sessions.expired(now)
    local result = {}
    for _, session in pairs(sessions.active) do
      if now >= session.lease_deadline then result[#result + 1] = session end
    end
    return result
  end

  function sessions.by_token(token)
    for _, session in pairs(sessions.active) do
      if session.udp_token == token then return session end
    end
    return nil
  end

  function sessions.public_state()
    local result = {}
    for _, session in pairs(sessions.active) do
      result[#result + 1] = {
        session_id = session.id,
        display_name = session.client.display_name,
        app_id = session.client.app_id,
      }
    end
    return result
  end

  return sessions
end
