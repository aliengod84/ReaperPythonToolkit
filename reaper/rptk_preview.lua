return function(state, items)
  local preview = {
    active = {}, owner = nil, prior_repeat = nil, prior_metronome = nil,
    repeat_active_key = "preview_repeat_active",
    repeat_prior_key = "preview_repeat_prior",
    metro_active_key = "preview_metronome_active",
    metro_prior_key = "preview_metronome_prior",
  }

  local function save_settings(options)
    options = options or {}
    local repeat_enabled = reaper.GetSetRepeat(-1)
    if repeat_enabled == 1 and not options.repeat_guard then
      error("resource_busy:Reaper Repeat is enabled")
    end
    if options.repeat_guard then
      preview.prior_repeat = repeat_enabled
      reaper.SetProjExtState(0, "RPTK", preview.repeat_active_key, "1")
      reaper.SetProjExtState(0, "RPTK", preview.repeat_prior_key, tostring(repeat_enabled))
      if repeat_enabled == 1 then reaper.GetSetRepeat(0) end
    end
    if options.metronome_guard and reaper.SNM_GetIntConfigVar then
      preview.prior_metronome = reaper.SNM_GetIntConfigVar("projmetroen", 0)
      reaper.SetProjExtState(0, "RPTK", preview.metro_active_key, "1")
      reaper.SetProjExtState(
        0, "RPTK", preview.metro_prior_key, tostring(preview.prior_metronome)
      )
    end
  end

  local function enable_metronome()
    if preview.prior_metronome ~= nil and reaper.SNM_SetIntConfigVar then
      reaper.SNM_SetIntConfigVar("projmetroen", preview.prior_metronome | 3)
    end
  end

  local function restore_metronome()
    if preview.prior_metronome ~= nil and reaper.SNM_SetIntConfigVar then
      reaper.SNM_SetIntConfigVar("projmetroen", preview.prior_metronome)
      preview.prior_metronome = nil
      reaper.SetProjExtState(0, "RPTK", preview.metro_active_key, "")
      reaper.SetProjExtState(0, "RPTK", preview.metro_prior_key, "")
    end
  end

  local function restore_settings()
    restore_metronome()
    if preview.prior_repeat ~= nil then reaper.GetSetRepeat(preview.prior_repeat) end
    preview.prior_repeat = nil
    reaper.SetProjExtState(0, "RPTK", preview.repeat_active_key, "")
    reaper.SetProjExtState(0, "RPTK", preview.repeat_prior_key, "")
  end

  function preview.restore_stale()
    local _, repeat_active = reaper.GetProjExtState(0, "RPTK", preview.repeat_active_key)
    local _, repeat_prior = reaper.GetProjExtState(0, "RPTK", preview.repeat_prior_key)
    if repeat_active == "1" then reaper.GetSetRepeat(tonumber(repeat_prior) or 0) end
    local _, metro_active = reaper.GetProjExtState(0, "RPTK", preview.metro_active_key)
    local _, metro_prior = reaper.GetProjExtState(0, "RPTK", preview.metro_prior_key)
    if metro_active == "1" and reaper.SNM_SetIntConfigVar then
      reaper.SNM_SetIntConfigVar("projmetroen", tonumber(metro_prior) or 0)
    end
    preview.prior_repeat, preview.prior_metronome = nil, nil
    reaper.SetProjExtState(0, "RPTK", preview.repeat_active_key, "")
    reaper.SetProjExtState(0, "RPTK", preview.repeat_prior_key, "")
    reaper.SetProjExtState(0, "RPTK", preview.metro_active_key, "")
    reaper.SetProjExtState(0, "RPTK", preview.metro_prior_key, "")
  end

  local function measure_plan(seconds, count_in)
    local _, measure = reaper.TimeMap2_timeToBeats(0, seconds)
    local current = reaper.TimeMap2_beatsToTime(0, 0, measure)
    if seconds > current + 0.001 then measure = measure + 1 end
    local count_start = reaper.TimeMap2_beatsToTime(0, 0, measure)
    local origin_measure = count_in == false and measure or measure + 1
    local origin = reaper.TimeMap2_beatsToTime(0, 0, origin_measure)
    return state.time_to_ppq(count_start), state.time_to_ppq(origin)
  end

  local function horizon_end(current, authority)
    local elapsed = math.max(0, authority - current.origin)
    local cycles = math.floor(elapsed / current.phrase_length) + 64
    return current.origin + math.max(64, cycles) * current.phrase_length
  end

  local function item_alive(resource)
    return resource and resource.item and
      reaper.ValidatePtr(resource.item, "MediaItem*")
  end

  local function set_item_end(resource, ending_ppq)
    if not item_alive(resource) then return end
    local start = reaper.GetMediaItemInfo_Value(resource.item, "D_POSITION")
    reaper.SetMediaItemInfo_Value(
      resource.item, "D_LENGTH", math.max(0, state.ppq_to_time(ending_ppq) - start)
    )
  end

  local function configure_loop(resource)
    if not item_alive(resource) then return end
    reaper.SetMediaItemInfo_Value(resource.item, "B_LOOPSRC", 1)
    reaper.SetMediaItemInfo_Value(resource.item, "C_BEATATTACHMODE", 1)
  end

  local function public(current)
    return {
      resource_id = current and current.id or "",
      active = current ~= nil,
      status = current and current.status or "idle",
      origin_ppq = current and current.origin or 0,
      phrase_length_ppq = current and current.phrase_length or 0,
      count_in = current and current.count_in or false,
      count_in_start_ppq = current and current.count_start or 0,
      pending_switch_ppq = current and current.pending_switch or nil,
      active_revision = current and current.active_revision or "",
      pending_revision = current and current.pending_revision or nil,
    }
  end

  local function create(session, payload, start, phase)
    local copy = {}
    for key, value in pairs(payload) do copy[key] = value end
    copy.options = { start_ppq = start, collision_policy = "allow", advance_cursor = "none" }
    copy.phase_ppq = phase or 0
    local resource = items.insert(session, copy, "midi_preview")
    configure_loop(resource)
    return resource
  end

  function preview.prepare(session, payload)
    if preview.owner and preview.owner ~= session.id then
      error("resource_busy:transport preview is owned by another session")
    end
    local options = payload.options or {}
    save_settings(options)
    local ok, value = xpcall(function()
      local playing = reaper.GetPlayState() & 1 == 1
      local authority = playing and reaper.GetPlayPosition() or reaper.GetCursorPosition()
      local count_start, origin = measure_plan(authority, options.count_in)
      local resource = create(session, payload, origin, 0)
      return {
        playing = playing, count_start = count_start, origin = origin, resource = resource,
      }
    end, debug.traceback)
    if not ok then restore_settings(); error(value) end
    local playing, count_start, origin, resource =
      value.playing, value.count_start, value.origin, value.resource
    local current = {
      id = resource.resource_id, resource = resource,
      active_revision = payload.midi_phrase.revision, pending_revision = nil,
      count_start = count_start, origin = origin,
      phrase_length = resource.length_ppq, count_in = options.count_in ~= false,
      status = options.count_in == false and "playing" or (playing and "queued" or "count_in"),
      last_play = nil, last_wall = nil, prepared_at = reaper.time_precise(),
    }
    set_item_end(resource, horizon_end(current, origin))
    preview.owner = session.id
    preview.active[current.id] = current
    if not playing then
      reaper.SetEditCurPos(state.ppq_to_time(count_start), true, false)
      if current.count_in then enable_metronome() end
      reaper.OnPlayButton()
    end
    return public(current)
  end

  local function promote(current)
    if not current.pending then return end
    items.delete(current.resource)
    current.resource = items.adopt_id(current.pending, current.id)
    current.pending = nil
    current.active_revision = current.pending_revision
    current.pending_revision, current.pending_switch = nil, nil
    current.status = "playing"
  end

  function preview.update(session, payload)
    local current = preview.active[payload.resource_id]
    if not current then error("resource_not_found:preview does not exist") end
    if current.resource.session_id ~= session.id then
      error("ownership_error:preview belongs to another session")
    end
    local play = state.time_to_ppq(reaper.GetPlayPosition())
    if current.pending and play >= current.pending_switch then promote(current) end
    if play < current.origin then
      if current.pending then items.delete(current.pending) end
      items.delete(current.resource)
      local replacement = create(session, payload, current.origin, 0)
      current.resource = items.adopt_id(replacement, current.id)
      current.phrase_length = replacement.length_ppq
      current.active_revision = payload.midi_phrase.revision
      current.pending, current.pending_revision, current.pending_switch = nil, nil, nil
      set_item_end(current.resource, horizon_end(current, current.origin))
      return public(current)
    end
    local safe_seconds = reaper.GetPlayPosition() + 0.250
    local _, measure = reaper.TimeMap2_timeToBeats(0, safe_seconds)
    local boundary = reaper.TimeMap2_beatsToTime(0, 0, measure)
    if boundary < safe_seconds - 0.001 then
      boundary = reaper.TimeMap2_beatsToTime(0, 0, measure + 1)
    end
    local switch = state.time_to_ppq(boundary)
    if current.pending then items.delete(current.pending) end
    local phrase_length = math.max(
      1, math.floor(payload.midi_phrase.length_ppq * state.ppq() /
        payload.midi_phrase.source_ppqn + 0.5)
    )
    current.pending = create(
      session, payload, switch, (switch - current.origin) % phrase_length
    )
    set_item_end(current.resource, switch)
    current.pending_switch = switch
    current.pending_revision = payload.midi_phrase.revision
    current.phrase_length = phrase_length
    current.status = "switch_pending"
    return public(current)
  end

  function preview.stop(session, id)
    local current = preview.active[id]
    if not current then return public(nil) end
    if current.resource.session_id ~= session.id then
      error("ownership_error:preview belongs to another session")
    end
    items.delete(current.resource)
    if current.pending then items.delete(current.pending) end
    preview.active[id], preview.owner = nil, nil
    restore_settings()
    local result = public(nil)
    result.resource_id = id
    result.active_revision = current.active_revision
    return result
  end

  function preview.cleanup_session(session)
    local remove = {}
    for id, current in pairs(preview.active) do
      if current.resource.session_id == session.id then remove[#remove + 1] = id end
    end
    for _, id in ipairs(remove) do preview.stop(session, id) end
  end

  function preview.cleanup_all()
    for _, current in pairs(preview.active) do
      items.delete(current.resource)
      if current.pending then items.delete(current.pending) end
    end
    preview.active, preview.owner = {}, nil
    restore_settings()
  end

  function preview.tick(now)
    local changed = false
    local playing = reaper.GetPlayState() & 1 == 1
    local remove = {}
    for id, current in pairs(preview.active) do
      if not item_alive(current.resource) then
        -- The preview item was deleted out from under us (e.g. the user changed
        -- the riff or removed the item). Drop the stale preview instead of
        -- crashing on its dead handle every tick.
        remove[#remove + 1] = id
      elseif not playing then
        if now - current.prepared_at > 0.5 then remove[#remove + 1] = id end
      else
        local play_seconds = reaper.GetPlayPosition()
        local play = state.time_to_ppq(play_seconds)
        if current.last_play then
          local elapsed = math.max(0, now - (current.last_wall or now))
          local delta = play_seconds - current.last_play
          if delta < -0.05 or delta > elapsed * 2.5 + 0.25 then
            remove[#remove + 1] = id
          end
        end
        current.last_play, current.last_wall = play_seconds, now
        if play < current.origin then
          current.count_in = true
          current.status = "count_in"
          enable_metronome()
        else
          current.count_in = false
          restore_metronome()
          if current.pending and play >= current.pending_switch then promote(current) end
          current.status = current.pending and "switch_pending" or "playing"
          if not current.pending then set_item_end(current.resource, horizon_end(current, play)) end
        end
      end
    end
    for _, id in ipairs(remove) do
      local current = preview.active[id]
      items.delete(current.resource)
      if current.pending then items.delete(current.pending) end
      preview.active[id] = nil
      changed = true
    end
    if next(preview.active) == nil and changed then
      preview.owner = nil
      restore_settings()
    end
    return changed
  end

  function preview.public_state(session_id)
    for _, current in pairs(preview.active) do
      if not session_id or current.resource.session_id == session_id then return public(current) end
    end
    return nil
  end

  preview.measure_plan = measure_plan
  return preview
end
