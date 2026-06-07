return function(sessions)
  local state = { sequence = 0, last_encoded = "", generation = "" }

  local function ppq()
    return reaper.SNM_GetIntConfigVar and
      reaper.SNM_GetIntConfigVar("miditicksperbeat", 960) or 960
  end

  local function project_identity()
    local project, path = reaper.EnumProjects(-1, "")
    return path ~= "" and path or tostring(project)
  end

  local function cursor(seconds)
    return {
      seconds = seconds,
      ppq = math.floor(reaper.TimeMap2_timeToQN(0, seconds) * ppq() + 0.5),
    }
  end

  function state.build(resources, preview_state)
    local identity = project_identity()
    if state.generation ~= identity then
      state.generation = identity
      state.sequence = state.sequence + 1
    end
    local edit = reaper.GetCursorPosition()
    local play = reaper.GetPlayPosition()
    local play_state = reaper.GetPlayState()
    local bpm = reaper.TimeMap_GetDividedBpmAtTime(0, play)
    local numerator, denominator = reaper.TimeMap_GetTimeSigAtTime(0, play)
    return {
      state_seq = math.max(1, state.sequence),
      project_generation = identity,
      project = {
        guid = identity, ppq = ppq(), bpm = bpm,
        meter = { numerator = numerator, denominator = denominator },
        playing = play_state & 1 == 1, recording = play_state & 4 == 4,
        repeat_enabled = reaper.GetSetRepeat(-1) == 1,
        edit_cursor = cursor(edit), play_cursor = cursor(play),
      },
      sessions = sessions.public_state(), resources = resources or {},
      preview = preview_state,
    }
  end

  function state.changed(encoded)
    if encoded == state.last_encoded then return false end
    state.last_encoded = encoded
    state.sequence = state.sequence + 1
    return true
  end

  function state.sequence_value() return math.max(1, state.sequence) end
  function state.ppq() return ppq() end
  function state.ppq_to_time(value) return reaper.TimeMap2_QNToTime(0, value / ppq()) end
  function state.time_to_ppq(value)
    return math.floor(reaper.TimeMap2_timeToQN(0, value) * ppq() + 0.5)
  end
  return state
end
