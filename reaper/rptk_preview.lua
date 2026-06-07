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
    if options.repeat_guard then
      preview.prior_repeat = reaper.GetSetRepeat(-1)
      reaper.SetProjExtState(0, "RPTK", preview.repeat_active_key, "1")
      reaper.SetProjExtState(0, "RPTK", preview.repeat_prior_key, tostring(preview.prior_repeat))
      reaper.GetSetRepeat(0)
    end
    if options.metronome_guard and reaper.SNM_GetIntConfigVar then
      preview.prior_metronome = reaper.SNM_GetIntConfigVar("projmetroen", 0)
      reaper.SetProjExtState(0, "RPTK", preview.metro_active_key, "1")
      reaper.SetProjExtState(
        0, "RPTK", preview.metro_prior_key, tostring(preview.prior_metronome)
      )
      reaper.SNM_SetIntConfigVar("projmetroen", preview.prior_metronome | 3)
    end
  end

  local function restore_settings()
    if preview.prior_repeat ~= nil then reaper.GetSetRepeat(preview.prior_repeat) end
    if preview.prior_metronome ~= nil and reaper.SNM_SetIntConfigVar then
      reaper.SNM_SetIntConfigVar("projmetroen", preview.prior_metronome)
    end
    preview.prior_repeat, preview.prior_metronome = nil, nil
    reaper.SetProjExtState(0, "RPTK", preview.repeat_active_key, "")
    reaper.SetProjExtState(0, "RPTK", preview.repeat_prior_key, "")
    reaper.SetProjExtState(0, "RPTK", preview.metro_active_key, "")
    reaper.SetProjExtState(0, "RPTK", preview.metro_prior_key, "")
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
    restore_settings()
  end

  local function measure_plan(seconds)
    local _, measure = reaper.TimeMap2_timeToBeats(0, seconds)
    local current = reaper.TimeMap2_beatsToTime(0, 0, measure)
    if seconds > current + 0.001 then measure = measure + 1 end
    local count_start = reaper.TimeMap2_beatsToTime(0, 0, measure)
    local origin = reaper.TimeMap2_beatsToTime(0, 0, measure + 1)
    return state.time_to_ppq(count_start), state.time_to_ppq(origin)
  end

  function preview.prepare(session, payload)
    if preview.owner and preview.owner ~= session.id then
      error("resource_busy:transport preview is owned by another session")
    end
    local authority = (reaper.GetPlayState() & 1 == 1) and
      reaper.GetPlayPosition() or reaper.GetCursorPosition()
    local count_start, origin = measure_plan(authority)
    payload.start_ppq = origin
    local resource = items.insert(session, payload, "midi_preview")
    preview.owner = session.id
    preview.active[resource.resource_id] = {
      resource = resource, active_revision = payload.midi_phrase.revision,
      pending_revision = nil, count_start = count_start, origin = origin,
      last_play = nil,
    }
    save_settings(payload.options)
    if reaper.GetPlayState() & 1 == 0 then
      reaper.SetEditCurPos(state.ppq_to_time(count_start), true, false)
      reaper.OnPlayButton()
    end
    return {
      resource_id = resource.resource_id, active = true,
      active_revision = payload.midi_phrase.revision,
    }
  end

  function preview.update(session, payload)
    local current = preview.active[payload.resource_id]
    if not current then error("resource_not_found:preview does not exist") end
    if current.resource.session_id ~= session.id then
      error("ownership_error:preview belongs to another session")
    end
    local play = state.time_to_ppq(reaper.GetPlayPosition())
    local _, measure = reaper.TimeMap2_timeToBeats(0, reaper.GetPlayPosition() + 0.250)
    local switch = state.time_to_ppq(reaper.TimeMap2_beatsToTime(0, 0, measure + 1))
    if play < current.origin then switch = current.origin end
    payload.start_ppq = switch
    payload.track_ref = { guid = reaper.GetTrackGUID(current.resource.track), create = "never" }
    local pending = items.insert(session, payload, "midi_preview")
    reaper.SetMediaItemInfo_Value(
      current.resource.item, "D_LENGTH",
      math.max(0, state.ppq_to_time(switch) -
        reaper.GetMediaItemInfo_Value(current.resource.item, "D_POSITION"))
    )
    current.pending = pending
    current.pending_switch = switch
    current.pending_revision = payload.revision or payload.midi_phrase.revision
    return {
      resource_id = payload.resource_id, active = true,
      active_revision = current.active_revision,
      pending_revision = current.pending_revision,
    }
  end

  function preview.stop(session, id)
    local current = preview.active[id]
    if not current then
      return { resource_id = id, active = false, active_revision = "" }
    end
    if current.resource.session_id ~= session.id then
      error("ownership_error:preview belongs to another session")
    end
    items.delete(current.resource)
    if current.pending then items.delete(current.pending) end
    preview.active[id] = nil
    preview.owner = nil
    restore_settings()
    return { resource_id = id, active = false, active_revision = current.active_revision }
  end

  function preview.cleanup_session(session)
    local remove = {}
    for id, current in pairs(preview.active) do
      if current.resource.session_id == session.id then remove[#remove + 1] = id end
    end
    for _, id in ipairs(remove) do preview.stop(session, id) end
  end

  function preview.tick()
    local changed = false
    local playing = reaper.GetPlayState() & 1 == 1
    for _, current in pairs(preview.active) do
      if not playing then
        items.delete(current.resource)
        if current.pending then items.delete(current.pending) end
        changed = true
      else
        local play = state.time_to_ppq(reaper.GetPlayPosition())
        if current.pending and play >= current.pending_switch then
          items.delete(current.resource)
          current.resource = current.pending
          current.active_revision = current.pending_revision
          current.pending, current.pending_revision, current.pending_switch = nil, nil, nil
          changed = true
        end
        if current.last_play and (play < current.last_play - state.ppq() / 8) then
          items.delete(current.resource)
          if current.pending then items.delete(current.pending) end
          changed = true
        end
        current.last_play = play
      end
    end
    if changed and not playing then
      preview.active, preview.owner = {}, nil
      restore_settings()
    end
    return changed
  end

  return preview
end
