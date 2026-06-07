return function(root)
  local path_separator = package.config:sub(3, 3)
  local directory_separator = package.config:sub(1, 1)
  local lua_directory = root .. "lua" .. directory_separator
  package.path = table.concat({
    lua_directory .. "?.lua",
    lua_directory .. "?" .. directory_separator .. "init.lua",
    lua_directory .. "socket" .. directory_separator .. "?.lua",
    root .. "?.lua",
    root .. "?" .. directory_separator .. "init.lua",
    root .. "socket" .. directory_separator .. "?.lua",
    package.path,
  }, path_separator)
  package.cpath = table.concat({
    lua_directory .. "?.dll",
    lua_directory .. "?" .. directory_separator .. "core.dll",
    lua_directory .. "clibs" .. directory_separator .. "?.dll",
    lua_directory .. "?.so",
    lua_directory .. "?" .. directory_separator .. "core.so",
    root .. "?.dll",
    root .. "?.so",
    package.cpath,
  }, path_separator)
  local json = dofile(root .. "json.lua")
  local protocol = dofile(root .. "rptk_protocol.lua")(json)
  local sessions = dofile(root .. "rptk_sessions.lua")(protocol)
  local state = dofile(root .. "rptk_state.lua")(sessions)
  local tracks = dofile(root .. "rptk_tracks.lua")(json)
  local items = dofile(root .. "rptk_midi_items.lua")(json, state, tracks)
  local preview = dofile(root .. "rptk_preview.lua")(state, items)
  local udp = dofile(root .. "rptk_udp.lua")(sessions)
  local ok_socket, socket = pcall(require, "socket")
  if not ok_socket then ok_socket, socket = pcall(require, "socket.core") end

  local host = {
    version = "0.2.0", socket = ok_socket and socket or nil,
    server = nil, clients = {}, last_state_at = 0, last_heartbeat_at = 0,
    project_generation = "",
  }

  local function console(message) reaper.ShowConsoleMsg("[RPTK] " .. message .. "\n") end
  local function send(client, value)
    client.outgoing = client.outgoing .. protocol.encode(value)
    if #client.outgoing > protocol.MAX_MESSAGE * 2 then client.close = true end
  end

  -- LuaSocket send(data, i, j) returns the absolute 1-based index of the last
  -- byte written within `data` (not a length), and on a non-blocking timeout
  -- returns nil, "timeout", <last_index>. Pass the whole buffer with explicit
  -- indices and advance a cursor by that index; never slice the buffer into a
  -- fresh substring and treat the return as a length, or partial writes desync
  -- and re-emit overlapping/stale memory. Chunk small to avoid large frames.
  local SEND_CHUNK = 512
  local function flush(client)
    if client.outgoing == "" then return end
    local cursor = 1
    local total = #client.outgoing
    for _ = 1, 64 do
      if cursor > total then break end
      local chunk_end = math.min(cursor + SEND_CHUNK - 1, total)
      local sent, err, last_byte = client.socket:send(client.outgoing, cursor, chunk_end)
      local before = cursor
      if sent then
        cursor = math.floor(sent) + 1
      elseif err == "timeout" then
        cursor = math.floor(tonumber(last_byte) or (cursor - 1)) + 1
        if cursor <= before then break end
        break
      else
        client.close = true
        return
      end
      if cursor <= before then break end
    end
    if cursor > 1 then client.outgoing = client.outgoing:sub(cursor) end
  end

  local function close_client(client)
    if client.session then
      preview.cleanup_session(client.session)
      items.cleanup_session(client.session)
      udp.cleanup_session(client.session)
      sessions.remove(client.session)
    end
    pcall(function() client.socket:close() end)
    host.clients[client] = nil
  end

  local function capabilities_set()
    local result = {}
    for _, capability in ipairs(protocol.CAPABILITIES) do result[capability] = true end
    return result
  end

  local function handshake_failure(client, request, code, message)
    send(client, {
      protocol = "rptk", type = "hello_ack", request_id = request.request_id,
      ok = false, error = protocol.error(code, message, false),
    })
    client.close_after_write = true
  end

  local function handle_hello(client, request, now)
    if request.protocol ~= "rptk" or request.type ~= "hello" then
      handshake_failure(client, request, "not_rptk_host", "First message must be an RPTK hello.")
      return
    end
    local range = request.protocol_range or {}
    if range.major ~= 1 then
      handshake_failure(client, request, "protocol_major_mismatch", "Host supports protocol major 1.")
      return
    end
    if (range.min_minor or 0) > 1 or (range.max_minor or -1) < 1 then
      handshake_failure(client, request, "protocol_minor_unsupported", "Host supports protocol 1.1.")
      return
    end
    local identity = request.client or {}
    if type(identity.app_id) ~= "string" or not identity.app_id:find("%.") or
      type(identity.instance_id) ~= "string" or identity.instance_id == "" or
      type(identity.display_name) ~= "string" or identity.display_name == "" then
      handshake_failure(client, request, "invalid_client_identity", "Client identity is invalid.")
      return
    end
    local available = capabilities_set()
    for _, capability in ipairs(request.required_capabilities or {}) do
      if not available[capability] then
        handshake_failure(
          client, request, "missing_capability", "Host does not support " .. capability .. "."
        )
        return
      end
    end
    local session, err = sessions.create(identity, client.socket, now)
    if not session then
      handshake_failure(client, request, err, "The instance ID is already connected.")
      return
    end
    client.session, client.handshake = session, true
    send(client, {
      protocol = "rptk", type = "hello_ack", request_id = request.request_id, ok = true,
      negotiated_protocol = { major = 1, minor = 1 },
      host = {
        host_version = host.version, reaper_version = reaper.GetAppVersion(),
        platform = reaper.GetOS(), capabilities = protocol.CAPABILITIES,
      },
      session = {
        session_id = session.id, lease_timeout_ms = 5000,
        heartbeat_interval_ms = 1000, udp_token = session.udp_token,
        udp_host = "127.0.0.1", udp_port = 9900,
      },
      initial_state = state.build(
        items.public_state(session.client.app_id), preview.public_state(session.id)
      ),
    })
  end

  local function parse_error(err)
    local text = tostring(err)
    local code, message = text:match("([a-z_]+):(.*)")
    if not code then return protocol.error("reaper_operation_failed", text, false) end
    return protocol.error(code, message, code == "resource_busy")
  end

  local function command(session, request)
    local method, payload = request.method, request.payload or {}
    if method == "session.heartbeat" then
      sessions.touch(session, reaper.time_precise())
      return { lease_deadline = session.lease_deadline }
    elseif method == "state.get" then
      return state.build(
        items.public_state(session.client.app_id), preview.public_state(session.id)
      )
    elseif method == "transport.set" then
      local playing = reaper.GetPlayState() & 1 == 1
      if payload.playing and not playing then reaper.OnPlayButton() end
      if not payload.playing and playing then reaper.OnStopButton() end
      return { playing = payload.playing == true }
    elseif method == "cursor.set" then
      if type(payload.ppq) ~= "number" then error("invalid_params:ppq is required") end
      reaper.SetEditCurPos(state.ppq_to_time(math.floor(payload.ppq)), true, false)
      return { ppq = math.floor(payload.ppq) }
    elseif method == "track.capture_selection" then
      local _, result = tracks.capture(
        session.client.app_id, payload.role or "", payload.bind == true
      )
      return result
    elseif method == "track.resolve" then
      local _, result = tracks.resolve(payload.track_ref)
      return result
    elseif method == "track.resolve_bound" then
      local _, result = tracks.resolve_bound(
        session.client.app_id, payload.role or "", payload.fallback,
        payload.bind_fallback == true
      )
      return result
    elseif method == "track.binding.clear" then
      tracks.clear_binding(session.client.app_id, payload.role or "")
      return {}
    elseif method == "resource.list" then
      return {
        resources = items.public_state(
          session.client.app_id, payload.kind, payload.target_guid
        )
      }
    elseif method == "midi.item.insert" then
      payload.operation_id = payload.operation_id or request.operation_id
      local resource = items.insert(session, payload, "midi_item")
      return items.public(resource)
    elseif method == "midi.item.replace" then
      payload.operation_id = payload.operation_id or request.operation_id
      local resource = items.replace(session, payload)
      return items.public(resource)
    elseif method == "midi.preview.prepare" then
      return preview.prepare(session, payload)
    elseif method == "midi.preview.update" then
      return preview.update(session, payload)
    elseif method == "midi.preview.stop" then
      return preview.stop(session, payload.resource_id)
    end
    error("invalid_request:unknown method " .. tostring(method))
  end

  local function handle_request(client, request)
    if request.protocol ~= "rptk" or request.protocol_major ~= 1 or
      request.type ~= "request" or type(request.request_id) ~= "string" or
      type(request.method) ~= "string" or type(request.payload) ~= "table" then
      client.close = true
      return
    end
    local fingerprint = json.encode(request)
    local cached = client.session.response_cache[request.request_id]
    if cached then
      if cached.fingerprint == fingerprint then send(client, cached.response)
      else
        send(client, protocol.response(
          request, false, protocol.error(
            "request_id_conflict", "Request ID was reused with different content.", false
          )
        ))
      end
      return
    end
    local ok, result = pcall(command, client.session, request)
    local response = protocol.response(request, ok, ok and result or parse_error(result))
    client.session.response_cache[request.request_id] = {
      fingerprint = fingerprint, response = response, at = reaper.time_precise(),
    }
    send(client, response)
  end

  local function read_client(client, now)
    for _ = 1, 16 do
      local data, err, partial = client.socket:receive(65536)
      local received = data or partial
      if received and #received > 0 then
        client.buffer = client.buffer .. received
        if #client.buffer > protocol.MAX_MESSAGE then client.close = true; return end
      end
      if err and err ~= "timeout" then client.close = true; return end
      if not data then break end
    end
    for _ = 1, 32 do
      local newline = client.buffer:find("\n", 1, true)
      if not newline then break end
      local line = client.buffer:sub(1, newline - 1)
      client.buffer = client.buffer:sub(newline + 1)
      if line ~= "" then
        local value, err = protocol.decode(line)
        if not value then
          console("client protocol error: " .. err)
          client.close = true
          return
        end
        if not client.handshake then handle_hello(client, value, now)
        else handle_request(client, value) end
      end
    end
  end

  function host.bootstrap(tcp_port, udp_port)
    if not host.socket then
      return nil, "LuaSocket is missing. Install LuaSocket for Reaper Lua, then restart the action."
    end
    math.randomseed(math.floor(reaper.time_precise() * 1000000))
    preview.restore_stale()
    items.scan()
    host.project_generation = state.build({}).project_generation
    local server, err = host.socket.bind("127.0.0.1", tcp_port or 9901)
    if not server then return nil, "TCP bind failed: " .. tostring(err) end
    server:settimeout(0)
    host.server = server
    local ok, udp_err = udp.bind(host.socket, "127.0.0.1", udp_port or 9900)
    if not ok then server:close(); host.server = nil; return nil, "UDP bind failed: " .. tostring(udp_err) end
    console("host " .. host.version .. " listening on TCP 9901 and UDP 9900")
    return true
  end

  function host.tick(now)
    for _ = 1, 8 do
      local connection = host.server:accept()
      if not connection then break end
      connection:settimeout(0)
      host.clients[{
        socket = connection, buffer = "", outgoing = "", handshake = false,
        accepted_at = now, close = false,
      }] = true
    end
    udp.poll(now)
    preview.tick()
    for client in pairs(host.clients) do
      if not client.handshake and now - client.accepted_at > 2 then client.close = true end
      read_client(client, now)
      flush(client)
      if client.close or (client.close_after_write and client.outgoing == "") then close_client(client) end
    end
    for _, session in ipairs(sessions.expired(now)) do
      for client in pairs(host.clients) do
        if client.session == session then close_client(client) end
      end
    end
    if now - host.last_state_at >= 0.1 then
      host.last_state_at = now
      local generation = state.build({}).project_generation
      if generation ~= host.project_generation then
        preview.cleanup_all()
        items.scan()
        host.project_generation = generation
      end
      local snapshot = state.build(items.public_state())
      local snapshot_sequence = snapshot.state_seq
      snapshot.state_seq = 0
      local encoded = json.encode(snapshot)
      snapshot.state_seq = snapshot_sequence
      if state.changed(encoded) then
        snapshot.state_seq = state.sequence_value()
        for client in pairs(host.clients) do
          if client.session then
            client.session.event_seq = client.session.event_seq + 1
            local client_snapshot = state.build(
              items.public_state(client.session.client.app_id),
              preview.public_state(client.session.id)
            )
            client_snapshot.state_seq = snapshot.state_seq
            send(client, protocol.event(
              "state.changed", client.session.event_seq, client_snapshot
            ))
          end
        end
      end
      if now - host.last_heartbeat_at >= 1 then
        host.last_heartbeat_at = now
        for client in pairs(host.clients) do
          if client.session then
            client.session.event_seq = client.session.event_seq + 1
            send(client, protocol.event("bridge.heartbeat", client.session.event_seq, {
              state_seq = snapshot.state_seq,
              host_monotonic_time = now,
              project_generation = snapshot.project_generation,
            }))
          end
        end
      end
    end
  end

  function host.close()
    for client in pairs(host.clients) do close_client(client) end
    udp.close()
    if host.server then host.server:close(); host.server = nil end
  end
  return host
end
