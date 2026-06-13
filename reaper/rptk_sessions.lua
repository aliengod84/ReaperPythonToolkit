return function(protocol)
  local sessions = { active = {}, instances = {} }
  local DEFAULT_LEASE = 5
  local PREVIEW_LEASE = 30

  local function random_hex(bytes)
    local output = {}
    for _ = 1, bytes do output[#output + 1] = string.format("%02x", math.random(0, 255)) end
    return table.concat(output)
  end

  function sessions.create(client, socket, now)
    local instance = client.instance_id
    local existing_id = sessions.instances[instance]
    local existing = existing_id and sessions.active[existing_id] or nil
    if existing then
      if existing.attached then return nil, "duplicate_instance" end
      if existing.client.app_id ~= client.app_id then
        return nil, "duplicate_instance"
      end
      existing.client = client
      existing.socket = socket
      existing.attached = true
      existing.lease_deadline = now + (
        existing.preview_active and PREVIEW_LEASE or DEFAULT_LEASE
      )
      return existing, nil, true
    end
    local session = {
      id = random_hex(16), udp_token = random_hex(16), client = client,
      socket = socket, attached = true, preview_active = false,
      lease_deadline = now + DEFAULT_LEASE, event_seq = 0,
      resources = {}, response_cache = {}, generation = 0, udp_queue = {},
      active_notes = {},
    }
    sessions.active[session.id] = session
    sessions.instances[instance] = session.id
    return session
  end

  function sessions.touch(session, now, preview_active)
    session.preview_active = preview_active == true
    session.lease_deadline = now + (
      session.preview_active and PREVIEW_LEASE or DEFAULT_LEASE
    )
  end

  function sessions.detach(session, now, preview_active)
    session.socket = nil
    session.attached = false
    sessions.touch(session, now, preview_active)
  end

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

  function sessions.lease_timeout_ms(session)
    return (session.preview_active and PREVIEW_LEASE or DEFAULT_LEASE) * 1000
  end

  function sessions.all()
    local result = {}
    for _, session in pairs(sessions.active) do result[#result + 1] = session end
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
