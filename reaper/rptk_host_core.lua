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
  local socket_io = dofile(root .. "rptk_socket.lua")({
    chunk_size = 512,
    max_writes = 64,
    log = function(message)
      reaper.ShowConsoleMsg("[RPTK][flush] " .. message .. "\n")
    end,
  })
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
    project_generation = "", tcp_port = 9901, udp_port = 9900,
  }

  local function console(message) reaper.ShowConsoleMsg("[RPTK] " .. message .. "\n") end
  local function send(client, value)
    client.outgoing = client.outgoing .. protocol.encode(value)
    if #client.outgoing > protocol.MAX_MESSAGE * 2 then client.close = true end
  end

  local function cleanup_session(session)
    preview.cleanup_session(session)
    items.cleanup_session(session)
    udp.cleanup_session(session)
    sessions.remove(session)
  end

  local function close_client(client, now)
    if client.session then
      udp.cleanup_session(client.session)
      sessions.detach(
        client.session,
        now or reaper.time_precise(),
        preview.public_state(client.session.id) ~= nil
      )
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
        session_id = session.id,
        lease_timeout_ms = sessions.lease_timeout_ms(session),
        heartbeat_interval_ms = 1000, udp_token = session.udp_token,
        udp_host = "127.0.0.1", udp_port = host.udp_port,
      },
      initial_state = state.build(
        items.public_state(session.client.app_id), preview.public_state(session.id)
      ),
    })
  end

  local function parse_error(err)
    local text = tostring(err)
    local first_line = text:match("^[^\n]+") or text
    local known_codes = {
      "invalid_request", "invalid_params", "resource_not_found", "resource_busy",
      "ownership_error", "reaper_operation_failed", "resource_limit",
      "operation_id_conflict",
    }
    local code, message
    for _, candidate in ipairs(known_codes) do
      message = first_line:match(candidate .. ":(.*)$")
      if message then code = candidate; break end
    end
    if not code then return protocol.error("reaper_operation_failed", text, false) end
    return protocol.error(code, message, code == "resource_busy")
  end

  local function command(session, request)
    local method, payload = request.method, request.payload or {}
    if method == "session.heartbeat" then
      sessions.touch(
        session,
        reaper.time_precise(),
        preview.public_state(session.id) ~= nil
      )
      return { lease_deadline = session.lease_deadline }
    elseif method == "session.close" then
      session.close_requested = true
      return {}
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
    sessions.touch(
      client.session,
      reaper.time_precise(),
      preview.public_state(client.session.id) ~= nil
    )
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
    if request.method == "session.close" and ok then
      client.close_session_after_write = true
    end
  end

  local function read_client(client, now)
    for _ = 1, 16 do
      local data, err, partial = client.socket:receive(65536)
      local received = data or partial
      if received and #received > 0 then
        if client.session then
          sessions.touch(
            client.session, now, preview.public_state(client.session.id) ~= nil
          )
        end
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
    host.tcp_port, host.udp_port = tcp_port or 9901, udp_port or 9900
    local server, err = host.socket.bind("127.0.0.1", host.tcp_port)
    if not server then return nil, "TCP bind failed: " .. tostring(err) end
    server:settimeout(0)
    host.server = server
    local ok, udp_err = udp.bind(host.socket, "127.0.0.1", host.udp_port)
    if not ok then server:close(); host.server = nil; return nil, "UDP bind failed: " .. tostring(udp_err) end
    console(string.format(
      "host %s listening on TCP %d and UDP %d",
      host.version, host.tcp_port, host.udp_port
    ))
    return true
  end

  function host.tick(now)
    for _ = 1, 8 do
      local connection = host.server:accept()
      if not connection then break end
      connection:settimeout(0)
      if connection.setoption then
        pcall(function() connection:setoption("tcp-nodelay", true) end)
      end
      host.clients[{
        socket = connection, buffer = "", outgoing = "", handshake = false,
        accepted_at = now, close = false,
      }] = true
    end
    -- Service reliable commands before preview/state maintenance. Reaper runs
    -- all of this on one defer thread, so MIDI item work must not delay a Stop
    -- request that is already waiting in the TCP socket.
    for client in pairs(host.clients) do
      if not client.handshake and now - client.accepted_at > 2 then client.close = true end
      read_client(client, now)
      socket_io.flush(client)
      if client.close_session_after_write and client.outgoing == "" then
        cleanup_session(client.session)
        client.session = nil
        pcall(function() client.socket:close() end)
        host.clients[client] = nil
      elseif client.close or (client.close_after_write and client.outgoing == "") then
        close_client(client, now)
      end
    end
    for _, session in ipairs(sessions.expired(now)) do
      for client in pairs(host.clients) do
        if client.session == session then
          pcall(function() client.socket:close() end)
          host.clients[client] = nil
        end
      end
      cleanup_session(session)
    end
    udp.poll(now)
    preview.tick(now)
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
    for client in pairs(host.clients) do
      pcall(function() client.socket:close() end)
      host.clients[client] = nil
    end
    for _, session in ipairs(sessions.all()) do cleanup_session(session) end
    udp.close()
    if host.server then host.server:close(); host.server = nil end
  end
  return host
end
