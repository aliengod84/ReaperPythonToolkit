return function(json, state, tracks)
  local items = { resources = {}, operations = {} }

  local function set_tag(item, key, value)
    reaper.GetSetMediaItemInfo_String(item, "P_EXT:" .. key, value or "", true)
  end

  local function get_tag(item, key)
    local _, value = reaper.GetSetMediaItemInfo_String(item, "P_EXT:" .. key, "", false)
    return value
  end

  local function resource_id()
    local output = {}
    for _ = 1, 16 do output[#output + 1] = string.format("%02x", math.random(0, 255)) end
    return table.concat(output)
  end

  local function write_phrase(track, phrase, start_ppq)
    local project_length = math.max(
      1, math.floor(phrase.length_ppq * state.ppq() / phrase.source_ppqn + 0.5)
    )
    local ending = start_ppq + project_length
    local item = reaper.CreateNewMIDIItemInProj(
      track, state.ppq_to_time(start_ppq), state.ppq_to_time(ending), false
    )
    local take = reaper.GetActiveTake(item)
    local scale = state.ppq() / phrase.source_ppqn
    for _, note in ipairs(phrase.notes or {}) do
      local start = math.floor(note.start_ppq * scale + 0.5)
      local finish = start + math.max(1, math.floor(note.duration_ppq * scale + 0.5))
      reaper.MIDI_InsertNote(
        take, false, false, start, finish,
        note.channel, note.pitch, note.velocity, true
      )
    end
    reaper.MIDI_Sort(take)
    return item
  end

  function items.insert(session, payload, kind)
    if payload.operation_id and kind ~= "midi_preview" then
      local operation_key = session.client.app_id .. ":" .. payload.operation_id
      local existing = items.operations[operation_key]
      if existing then
        local phrase = payload.midi_phrase or {}
        if existing.revision ~= phrase.revision then
          error("operation_id_conflict:operation ID was reused with different content")
        end
        return items.resources[existing.resource_id]
      end
    end
    local track = tracks.resolve(payload.track_ref)
    local start = payload.start_ppq or state.time_to_ppq(reaper.GetCursorPosition())
    local item = write_phrase(track, payload.midi_phrase, start)
    local id = resource_id()
    set_tag(item, "RPTK_RESOURCE_ID", id)
    set_tag(item, "RPTK_APP_ID", session.client.app_id)
    set_tag(item, "RPTK_KIND", kind or "midi_item")
    if kind == "midi_preview" then set_tag(item, "RPTK_SESSION_ID", session.id) end
    set_tag(item, "RPTK_METADATA", json.encode(payload.metadata or {}))
    items.resources[id] = {
      resource_id = id, item = item, track = track, app_id = session.client.app_id,
      session_id = kind == "midi_preview" and session.id or nil,
      kind = kind or "midi_item", metadata = payload.metadata or {},
    }
    if payload.operation_id and kind ~= "midi_preview" then
      items.operations[session.client.app_id .. ":" .. payload.operation_id] = {
        resource_id = id, revision = payload.midi_phrase.revision,
      }
    end
    reaper.UpdateArrange()
    return items.resources[id]
  end

  function items.find(id)
    local known = items.resources[id]
    if known and reaper.ValidatePtr(known.item, "MediaItem*") then return known end
    for track_index = 0, reaper.CountTracks(0) - 1 do
      local track = reaper.GetTrack(0, track_index)
      for item_index = 0, reaper.CountTrackMediaItems(track) - 1 do
        local item = reaper.GetTrackMediaItem(track, item_index)
        if get_tag(item, "RPTK_RESOURCE_ID") == id then
          return { resource_id = id, item = item, track = track,
            app_id = get_tag(item, "RPTK_APP_ID"),
            session_id = get_tag(item, "RPTK_SESSION_ID"),
            kind = get_tag(item, "RPTK_KIND") }
        end
      end
    end
    return nil
  end

  function items.replace(session, payload)
    local operation_key = payload.operation_id and
      (session.client.app_id .. ":" .. payload.operation_id) or nil
    if operation_key and items.operations[operation_key] then
      local existing = items.operations[operation_key]
      if existing.revision ~= payload.midi_phrase.revision then
        error("operation_id_conflict:operation ID was reused with different content")
      end
      local resource = items.resources[existing.resource_id]
      if not resource then error("resource_not_found:reconciled item no longer exists") end
      return resource
    end
    local old = items.find(payload.resource_id)
    if not old then error("resource_not_found:item does not exist") end
    if old.app_id ~= session.client.app_id then error("ownership_error:item belongs to another app") end
    local start = state.time_to_ppq(reaper.GetMediaItemInfo_Value(old.item, "D_POSITION"))
    reaper.DeleteTrackMediaItem(old.track, old.item)
    payload.track_ref = { guid = reaper.GetTrackGUID(old.track), create = "never" }
    payload.start_ppq = start
    local operation_id = payload.operation_id
    payload.operation_id = nil
    local replacement = items.insert(session, payload, old.kind)
    payload.operation_id = operation_id
    local generated_id = replacement.resource_id
    replacement.resource_id = payload.resource_id
    set_tag(replacement.item, "RPTK_RESOURCE_ID", payload.resource_id)
    items.resources[generated_id] = nil
    items.resources[payload.resource_id] = replacement
    if operation_key then
      items.operations[operation_key] = {
        resource_id = payload.resource_id, revision = payload.midi_phrase.revision,
      }
    end
    return replacement
  end

  function items.delete(resource)
    if resource and reaper.ValidatePtr(resource.item, "MediaItem*") then
      reaper.DeleteTrackMediaItem(resource.track, resource.item)
    end
    if resource then items.resources[resource.resource_id] = nil end
    reaper.UpdateArrange()
  end

  function items.cleanup_session(session)
    local remove = {}
    for id, resource in pairs(items.resources) do
      if resource.session_id == session.id then remove[#remove + 1] = id end
    end
    for _, id in ipairs(remove) do items.delete(items.resources[id]) end
  end

  function items.public_state()
    local result = {}
    for _, value in pairs(items.resources) do
      result[#result + 1] = {
        resource_id = value.resource_id, kind = value.kind, app_id = value.app_id,
        session_id = value.session_id, metadata = value.metadata or {},
      }
    end
    return result
  end

  return items
end
