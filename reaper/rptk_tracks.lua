return function()
  local tracks = {}

  local function name(track)
    local _, value = reaper.GetTrackName(track)
    return value ~= "" and value or "Track"
  end

  function tracks.by_guid(guid)
    if not guid or guid == "" then return nil end
    for index = 0, reaper.CountTracks(0) - 1 do
      local track = reaper.GetTrack(0, index)
      if reaper.GetTrackGUID(track) == guid then return track end
    end
    return nil
  end

  function tracks.by_name(value)
    if not value or value == "" then return nil end
    for index = 0, reaper.CountTracks(0) - 1 do
      local track = reaper.GetTrack(0, index)
      if name(track) == value then return track end
    end
    return nil
  end

  function tracks.describe(track, role, created)
    return {
      guid = reaper.GetTrackGUID(track), name = name(track), exists = true,
      created = created == true, role = role or "",
    }
  end

  function tracks.resolve(reference)
    reference = reference or {}
    local track = tracks.by_guid(reference.guid) or tracks.by_name(reference.name)
    if not track and reference.selection_fallback and reaper.CountSelectedTracks(0) > 0 then
      track = reaper.GetSelectedTrack(0, 0)
    end
    local created = false
    if reference.create == "always_new" or
      (not track and reference.create == "if_missing") then
      reaper.InsertTrackAtIndex(reaper.CountTracks(0), true)
      track = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
      reaper.GetSetMediaTrackInfo_String(
        track, "P_NAME", reference.name ~= "" and reference.name or "RPTK MIDI", true
      )
      created = true
    end
    if not track then error("resource_not_found:no matching track") end
    return track, tracks.describe(track, reference.role, created)
  end

  function tracks.capture(role)
    if reaper.CountSelectedTracks(0) == 0 then
      error("resource_not_found:no selected track")
    end
    local track = reaper.GetSelectedTrack(0, 0)
    return track, tracks.describe(track, role, false)
  end
  return tracks
end
