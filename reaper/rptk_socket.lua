return function(options)
  local chunk_size = options.chunk_size or 512
  local max_writes = options.max_writes or 64
  local log = options.log or function() end

  local function flush(client)
    if client.outgoing == "" then return end
    local consumed = 0
    for _ = 1, max_writes do
      if consumed >= #client.outgoing then break end
      local chunk = client.outgoing:sub(consumed + 1, consumed + chunk_size)
      -- Reaper's bundled LuaSocket can return 0 for send(large_data, i, j)
      -- even when j-i is small. Pass a genuinely small string while retaining
      -- indexed-send semantics, where sent/last_byte are positions in `chunk`.
      local sent, err, last_byte = client.socket:send(chunk, 1, #chunk)
      local progress = math.floor(tonumber(sent or last_byte) or 0)
      if progress > #chunk then
        log(string.format(
          "out-of-range send progress=%s chunk=%d", tostring(progress), #chunk
        ))
        client.close = true
        return
      end
      if progress > 0 then consumed = consumed + progress end
      if not sent and err ~= "timeout" then
        if err ~= "closed" then
          log(string.format(
            "send error err=%s last_byte=%s", tostring(err), tostring(last_byte)
          ))
        end
        client.close = true
        break
      end
      if progress < #chunk then break end
    end
    if consumed > 0 then client.outgoing = client.outgoing:sub(consumed + 1) end
  end

  return { flush = flush }
end
