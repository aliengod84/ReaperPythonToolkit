return function(json, state, tracks)
  local items = { resources = {}, operations = {}, generation = "" }

  local TAG = {
    id = "RPTK_RESOURCE_ID",
    app = "RPTK_APP_ID",
    session = "RPTK_SESSION_ID",
    kind = "RPTK_KIND",
    metadata = "RPTK_METADATA",
    target = "RPTK_TARGET_GUID",
    track = "RPTK_TRACK_GUID",
    revision = "RPTK_REVISION",
    layer_target = "RPTK_LAYER_TARGET_GUID",
    group_target = "RPTK_GROUP_TARGET_GUID",
  }

  local function set_item_tag(item, key, value)
    reaper.GetSetMediaItemInfo_String(item, "P_EXT:" .. key, value or "", true)
  end

  local function get_item_tag(item, key)
    local _, value = reaper.GetSetMediaItemInfo_String(item, "P_EXT:" .. key, "", false)
    return value
  end

  local function set_track_tag(track, key, value)
    reaper.GetSetMediaTrackInfo_String(track, "P_EXT:" .. key, value or "", true)
  end

  local function get_track_tag(track, key)
    local _, value = reaper.GetSetMediaTrackInfo_String(track, "P_EXT:" .. key, "", false)
    return value
  end

  local function resource_id()
    local output = {}
    for _ = 1, 16 do output[#output + 1] = string.format("%02x", math.random(0, 255)) end
    return table.concat(output)
  end

  local function track_index(track)
    return math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")) - 1
  end

  local function track_name(track)
    local _, value = reaper.GetTrackName(track)
    return value ~= "" and value or "Track"
  end

  local function item_bounds(item)
    local start = state.time_to_ppq(reaper.GetMediaItemInfo_Value(item, "D_POSITION"))
    local seconds = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local ending = state.time_to_ppq(
      reaper.GetMediaItemInfo_Value(item, "D_POSITION") + seconds
    )
    return start, math.max(1, ending - start)
  end

  local function has_overlap(track, start_ppq, length_ppq)
    local ending = start_ppq + length_ppq
    for index = 0, reaper.CountTrackMediaItems(track) - 1 do
      local item = reaper.GetTrackMediaItem(track, index)
      local item_start, item_length = item_bounds(item)
      if item_start < ending and item_start + item_length > start_ppq then return true end
    end
    return false
  end

  local function direct_children(folder)
    local result, depth = {}, 1
    for index = track_index(folder) + 1, reaper.CountTracks(0) - 1 do
      if depth <= 0 then break end
      local track = reaper.GetTrack(0, index)
      if depth == 1 then result[#result + 1] = track end
      depth = depth + math.tointeger(reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH"))
    end
    return result
  end

  local function subtree_end_index(track)
    local depth = math.max(
      0, math.tointeger(reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH"))
    )
    local index = track_index(track)
    if depth == 0 then return index end
    for current = index + 1, reaper.CountTracks(0) - 1 do
      depth = depth + math.tointeger(
        reaper.GetMediaTrackInfo_Value(reaper.GetTrack(0, current), "I_FOLDERDEPTH")
      )
      if depth <= 0 then return current end
    end
    return reaper.CountTracks(0) - 1
  end

  local function owned_group(target)
    if get_track_tag(target, TAG.group_target) == reaper.GetTrackGUID(target) then
      return target
    end
    local parent = reaper.GetParentTrack(target)
    if parent and get_track_tag(parent, TAG.group_target) == reaper.GetTrackGUID(target) then
      return parent
    end
    return nil
  end

  local function wrap_target(target)
    local target_guid = reaper.GetTrackGUID(target)
    local existing = owned_group(target)
    if existing then return existing end
    local index = track_index(target)
    local old_depth = math.tointeger(reaper.GetMediaTrackInfo_Value(target, "I_FOLDERDEPTH"))
    reaper.InsertTrackAtIndex(index, true)
    local folder = reaper.GetTrack(0, index)
    reaper.SetMediaTrackInfo_Value(folder, "I_FOLDERDEPTH", 1)
    reaper.SetMediaTrackInfo_Value(target, "I_FOLDERDEPTH", old_depth - 1)
    reaper.GetSetMediaTrackInfo_String(
      folder, "P_NAME", track_name(target) .. " Layers", true
    )
    set_track_tag(folder, TAG.group_target, target_guid)
    set_track_tag(target, TAG.layer_target, target_guid)
    return folder
  end

  local function create_layer(folder, target)
    local children = direct_children(folder)
    local last = children[#children]
    local insert_at = last and subtree_end_index(last) + 1 or track_index(folder) + 1
    if last then
      local terminator = reaper.GetTrack(0, insert_at - 1)
      local old_depth = math.tointeger(
        reaper.GetMediaTrackInfo_Value(terminator, "I_FOLDERDEPTH")
      )
      if old_depth >= 0 then old_depth = -1 end
      reaper.SetMediaTrackInfo_Value(terminator, "I_FOLDERDEPTH", old_depth + 1)
      reaper.InsertTrackAtIndex(insert_at, true)
      local layer = reaper.GetTrack(0, insert_at)
      reaper.SetMediaTrackInfo_Value(layer, "I_FOLDERDEPTH", old_depth)
      reaper.GetSetMediaTrackInfo_String(
        layer, "P_NAME", track_name(target) .. " Layer " .. tostring(#children + 1), true
      )
      set_track_tag(layer, TAG.layer_target, reaper.GetTrackGUID(target))
      return layer
    end
    reaper.InsertTrackAtIndex(insert_at, true)
    local layer = reaper.GetTrack(0, insert_at)
    reaper.SetMediaTrackInfo_Value(layer, "I_FOLDERDEPTH", -1)
    set_track_tag(layer, TAG.layer_target, reaper.GetTrackGUID(target))
    return layer
  end

  local function choose_track(target, start_ppq, length_ppq, policy)
    if not has_overlap(target, start_ppq, length_ppq) then return target, false end
    if policy == "reject" then error("resource_busy:target contains overlapping material") end
    if policy ~= "layer" then return target, false end
    local folder = wrap_target(target)
    local target_guid = reaper.GetTrackGUID(target)
    for _, child in ipairs(direct_children(folder)) do
      if get_track_tag(child, TAG.layer_target) == target_guid and
        not has_overlap(child, start_ppq, length_ppq) then
        return child, true
      end
    end
    return create_layer(folder, target), true
  end

  local function write_phrase(track, phrase, start_ppq, phase_ppq)
    local project_length = math.max(
      1, math.floor(phrase.length_ppq * state.ppq() / phrase.source_ppqn + 0.5)
    )
    local ending = start_ppq + project_length
    local item = reaper.CreateNewMIDIItemInProj(
      track, state.ppq_to_time(start_ppq), state.ppq_to_time(ending), false
    )
    if not item then error("reaper_operation_failed:failed to create MIDI item") end
    local take = reaper.GetActiveTake(item)
    local scale = state.ppq() / phrase.source_ppqn
    local phase = math.floor(phase_ppq or 0)
    for _, note in ipairs(phrase.notes or {}) do
      local source_start = math.floor(note.start_ppq * scale + 0.5)
      local start = (source_start - phase) % project_length
      local finish = math.min(
        project_length,
        start + math.max(1, math.floor(note.duration_ppq * scale + 0.5))
      )
      reaper.MIDI_InsertNote(
        take, false, false, start, finish,
        note.channel, note.pitch, note.velocity, true
      )
    end
    reaper.MIDI_Sort(take)
    return item, project_length
  end

  local function describe(id, item, track)
    local metadata = {}
    local raw = get_item_tag(item, TAG.metadata)
    if raw ~= "" then
      local ok, value = pcall(json.decode, raw)
      if ok and type(value) == "table" then metadata = value end
    end
    local start, length = item_bounds(item)
    return {
      resource_id = id, item = item, track = track,
      app_id = get_item_tag(item, TAG.app),
      session_id = get_item_tag(item, TAG.session) ~= "" and
        get_item_tag(item, TAG.session) or nil,
      kind = get_item_tag(item, TAG.kind),
      target_guid = get_item_tag(item, TAG.target),
      track_guid = reaper.GetTrackGUID(track),
      start_ppq = start, length_ppq = length, metadata = metadata,
      revision = get_item_tag(item, TAG.revision),
    }
  end

  local function tag(resource, revision)
    local item = resource.item
    set_item_tag(item, TAG.id, resource.resource_id)
    set_item_tag(item, TAG.app, resource.app_id)
    set_item_tag(item, TAG.session, resource.session_id or "")
    set_item_tag(item, TAG.kind, resource.kind)
    set_item_tag(item, TAG.metadata, json.encode(resource.metadata or {}))
    set_item_tag(item, TAG.target, resource.target_guid)
    set_item_tag(item, TAG.track, resource.track_guid)
    set_item_tag(item, TAG.revision, revision or "")
  end

  function items.scan()
    items.resources = {}
    for track_index_value = 0, reaper.CountTracks(0) - 1 do
      local track = reaper.GetTrack(0, track_index_value)
      for item_index = reaper.CountTrackMediaItems(track) - 1, 0, -1 do
        local item = reaper.GetTrackMediaItem(track, item_index)
        local id = get_item_tag(item, TAG.id)
        local kind = get_item_tag(item, TAG.kind)
        if id ~= "" and kind == "midi_item" then
          items.resources[id] = describe(id, item, track)
        elseif id ~= "" and kind == "midi_preview" then
          reaper.DeleteTrackMediaItem(track, item)
        end
      end
    end
    reaper.UpdateArrange()
  end

  local function resolved_target(session, reference)
    if reference and reference.role and reference.role ~= "" then
      return tracks.resolve_bound(
        session.client.app_id, reference.role, reference, true
      )
    end
    return tracks.resolve(reference)
  end

  function items.insert(session, payload, kind)
    kind = kind or "midi_item"
    local operation_key = payload.operation_id and
      (session.client.app_id .. ":" .. payload.operation_id) or nil
    if operation_key and kind ~= "midi_preview" and items.operations[operation_key] then
      local existing = items.operations[operation_key]
      if existing.revision ~= payload.midi_phrase.revision then
        error("operation_id_conflict:operation ID was reused with different content")
      end
      local reconciled = items.resources[existing.resource_id]
      if not reconciled then
        error("resource_not_found:reconciled item no longer exists")
      end
      return reconciled
    end
    local options = payload.options or {}
    local start = math.floor(options.start_ppq or payload.start_ppq or
      state.time_to_ppq(reaper.GetCursorPosition()))
    local item, actual_track
    local label = options.undo_label or "RPTK: Insert MIDI item"
    if reaper.Undo_BeginBlock2 then reaper.Undo_BeginBlock2(0) end
    local ok, result = xpcall(function()
      local target = resolved_target(session, payload.track_ref)
      local target_guid = reaper.GetTrackGUID(target)
      local length = math.max(
        1, math.floor(payload.midi_phrase.length_ppq * state.ppq() /
          payload.midi_phrase.source_ppqn + 0.5)
      )
      local collision
      actual_track, collision = choose_track(
        target, start, length, options.collision_policy or "allow"
      )
      local created, actual_length = write_phrase(
        actual_track, payload.midi_phrase, start, payload.phase_ppq
      )
      item = created
      local resource = {
        resource_id = resource_id(), item = created, track = actual_track,
        app_id = session.client.app_id,
        session_id = kind == "midi_preview" and session.id or nil,
        kind = kind, metadata = payload.metadata or {},
        target_guid = target_guid, track_guid = reaper.GetTrackGUID(actual_track),
        start_ppq = start, length_ppq = actual_length, collision = collision,
      }
      tag(resource, payload.midi_phrase.revision)
      items.resources[resource.resource_id] = resource
      if options.advance_cursor == "start" then
        reaper.SetEditCurPos(state.ppq_to_time(start), true, false)
      elseif options.advance_cursor == "end" then
        reaper.SetEditCurPos(state.ppq_to_time(start + actual_length), true, false)
      end
      return resource
    end, debug.traceback)
    if not ok and item and actual_track and reaper.ValidatePtr(item, "MediaItem*") then
      reaper.DeleteTrackMediaItem(actual_track, item)
    end
    if reaper.Undo_EndBlock2 then reaper.Undo_EndBlock2(0, label, -1) end
    if not ok then error(result) end
    if operation_key and kind ~= "midi_preview" then
      items.operations[operation_key] = {
        resource_id = result.resource_id, revision = payload.midi_phrase.revision,
      }
    end
    reaper.UpdateArrange()
    return result
  end

  function items.find(id)
    local known = items.resources[id]
    if known and reaper.ValidatePtr(known.item, "MediaItem*") then return known end
    items.scan()
    return items.resources[id]
  end

  function items.replace(session, payload)
    local operation_key = payload.operation_id and
      (session.client.app_id .. ":" .. payload.operation_id) or nil
    if operation_key and items.operations[operation_key] then
      local existing = items.operations[operation_key]
      if existing.revision ~= payload.midi_phrase.revision then
        error("operation_id_conflict:operation ID was reused with different content")
      end
      return items.find(existing.resource_id)
    end
    local old = items.find(payload.resource_id)
    if not old then error("resource_not_found:item does not exist") end
    if old.app_id ~= session.client.app_id then error("ownership_error:item belongs to another app") end
    if old.kind ~= "midi_item" then error("invalid_params:resource is not a durable MIDI item") end
    local options = payload.options or {}
    local replacement
    local label = options.undo_label or "RPTK: Replace MIDI item"
    if reaper.Undo_BeginBlock2 then reaper.Undo_BeginBlock2(0) end
    local ok, result = xpcall(function()
      local item, length = write_phrase(old.track, payload.midi_phrase, old.start_ppq)
      replacement = {
        resource_id = old.resource_id, item = item, track = old.track,
        app_id = old.app_id, session_id = nil, kind = "midi_item",
        metadata = payload.metadata or {}, target_guid = old.target_guid,
        track_guid = old.track_guid, start_ppq = old.start_ppq, length_ppq = length,
      }
      tag(replacement, payload.midi_phrase.revision)
      reaper.DeleteTrackMediaItem(old.track, old.item)
      items.resources[old.resource_id] = replacement
      if options.advance_cursor == "start" then
        reaper.SetEditCurPos(state.ppq_to_time(old.start_ppq), true, false)
      elseif options.advance_cursor == "end" then
        reaper.SetEditCurPos(state.ppq_to_time(old.start_ppq + length), true, false)
      end
      return replacement
    end, debug.traceback)
    if not ok and replacement and reaper.ValidatePtr(replacement.item, "MediaItem*") then
      reaper.DeleteTrackMediaItem(old.track, replacement.item)
    end
    if reaper.Undo_EndBlock2 then reaper.Undo_EndBlock2(0, label, -1) end
    if not ok then error(result) end
    if operation_key then
      items.operations[operation_key] = {
        resource_id = result.resource_id, revision = payload.midi_phrase.revision,
      }
    end
    reaper.UpdateArrange()
    return result
  end

  function items.delete(resource)
    if resource and reaper.ValidatePtr(resource.item, "MediaItem*") then
      reaper.DeleteTrackMediaItem(resource.track, resource.item)
    end
    if resource then items.resources[resource.resource_id] = nil end
    reaper.UpdateArrange()
  end

  function items.adopt_id(resource, id)
    items.resources[resource.resource_id] = nil
    resource.resource_id = id
    set_item_tag(resource.item, TAG.id, id)
    items.resources[id] = resource
    return resource
  end

  function items.cleanup_session(session)
    local remove = {}
    for id, resource in pairs(items.resources) do
      if resource.session_id == session.id then remove[#remove + 1] = id end
    end
    for _, id in ipairs(remove) do items.delete(items.resources[id]) end
  end

  local function public(resource)
    return {
      resource_id = resource.resource_id, kind = resource.kind,
      app_id = resource.app_id, session_id = resource.session_id,
      target_guid = resource.target_guid, track_guid = resource.track_guid,
      start_ppq = resource.start_ppq, length_ppq = resource.length_ppq,
      metadata = resource.metadata or {},
    }
  end

  function items.public_state(app_id, kind, target_guid)
    local result = {}
    for _, value in pairs(items.resources) do
      if (not app_id or value.app_id == app_id) and
        (not kind or value.kind == kind) and
        (not target_guid or value.target_guid == target_guid) then
        result[#result + 1] = public(value)
      end
    end
    table.sort(result, function(a, b) return a.resource_id < b.resource_id end)
    return result
  end

  items.public = public
  return items
end
