return function(json)
  local tracks = {}
  local BINDING_SECTION = "RPTK"
  local BINDING_KEY = "track_bindings_v1"

  local function name(track)
    local _, value = reaper.GetTrackName(track)
    return value ~= "" and value or "Track"
  end

  local function load_bindings()
    local _, raw = reaper.GetProjExtState(0, BINDING_SECTION, BINDING_KEY)
    if raw == "" then return {} end
    local ok, value = pcall(json.decode, raw)
    return ok and type(value) == "table" and value or {}
  end

  local function save_bindings(value)
    local encoded = json.encode(value)
    if #encoded > 65536 then error("resource_limit:track bindings exceed 64 KiB") end
    reaper.SetProjExtState(0, BINDING_SECTION, BINDING_KEY, encoded)
  end

  local function binding_for(app_id, role)
    local app = load_bindings()[app_id]
    return type(app) == "table" and app[role] or nil
  end

  local function set_binding(app_id, role, guid, source)
    if role == "" then error("invalid_params:role is required for track binding") end
    local bindings = load_bindings()
    bindings[app_id] = bindings[app_id] or {}
    bindings[app_id][role] = { guid = guid, source = source }
    save_bindings(bindings)
  end

  function tracks.clear_binding(app_id, role)
    local bindings = load_bindings()
    if bindings[app_id] then
      bindings[app_id][role] = nil
      if next(bindings[app_id]) == nil then bindings[app_id] = nil end
      save_bindings(bindings)
    end
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

  function tracks.describe(track, role, created, binding)
    return {
      guid = reaper.GetTrackGUID(track), name = name(track), exists = true,
      created = created == true, role = role or "", binding = binding or "none",
    }
  end

  function tracks.resolve(reference, binding)
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
    return track, tracks.describe(track, reference.role, created, binding)
  end

  function tracks.capture(app_id, role, bind)
    if reaper.CountSelectedTracks(0) == 0 then
      error("resource_not_found:no selected track")
    end
    local track = reaper.GetSelectedTrack(0, 0)
    if bind then set_binding(app_id, role, reaper.GetTrackGUID(track), "explicit") end
    return track, tracks.describe(track, role, false, bind and "explicit" or "none")
  end

  function tracks.resolve_bound(app_id, role, fallback, bind_fallback)
    local binding = binding_for(app_id, role)
    if binding then
      local track = tracks.by_guid(binding.guid)
      if track then
        return track, tracks.describe(track, role, false, binding.source or "explicit")
      end
      tracks.clear_binding(app_id, role)
    end
    fallback = fallback or {}
    fallback.role = role
    local track, result = tracks.resolve(fallback, bind_fallback and "fallback" or "none")
    if bind_fallback then
      set_binding(app_id, role, reaper.GetTrackGUID(track), "fallback")
      result.binding = "fallback"
    end
    return track, result
  end

  return tracks
end
