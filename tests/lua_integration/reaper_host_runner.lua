local root = assert(arg[1], "repository root is required")
local tcp_port = assert(tonumber(arg[2]), "TCP port is required")
local udp_port = assert(tonumber(arg[3]), "UDP port is required")
local ready_path = assert(arg[4], "ready path is required")
local stop_path = assert(arg[5], "stop path is required")
local midi_log_path = assert(arg[6], "MIDI log path is required")

root = root:gsub("\\", "/"):gsub("/$", "") .. "/"

-- Load the test runtime's socket module before the production host prepends its
-- optional Reaper-local module directory. This keeps an unrelated local build
-- (for example a Windows core.dll while tests run under Linux) from shadowing
-- the external LuaSocket selected by RPTK_LUA/LUA_CPATH.
local runtime_socket = assert(require("socket"))

local tracks = {
  { guid = "{RPTK-TRACK-1}", name = "RPTK Test Track", items = {}, depth = 0, ext = {} },
  { guid = "{RPTK-TRACK-2}", name = "RPTK Second Track", items = {}, depth = 0, ext = {} },
}
local selected = tracks[1]
local ext_state = {}
local cursor = 0
local play_position = 0
local playing = false
local repeat_enabled = 0
local metronome = 0
local next_track = 3
local last_clock = 0

local function clock()
  return runtime_socket.gettime()
end

local function update_transport()
  local now = clock()
  if last_clock == 0 then last_clock = now end
  if playing then play_position = play_position + math.max(0, now - last_clock) end
  last_clock = now
end

local function track_index(target)
  for index, track in ipairs(tracks) do
    if track == target then return index end
  end
  return nil
end

local function write_midi(status, data1, data2)
  local file = assert(io.open(midi_log_path, "a"))
  file:write(string.format("%d,%d,%d\n", status, data1, data2))
  file:close()
end

reaper = {}
function reaper.ShowConsoleMsg(message) io.stdout:write(message); io.stdout:flush() end
function reaper.GetAppVersion() return "headless-test" end
function reaper.GetOS() return "headless" end
function reaper.time_precise() return clock() end
function reaper.EnumProjects() return 1, "rptk-headless-project.rpp" end
function reaper.SNM_GetIntConfigVar(name, default)
  if name == "miditicksperbeat" then return 960 end
  if name == "projmetroen" then return metronome end
  return default
end
function reaper.SNM_SetIntConfigVar(name, value)
  if name == "projmetroen" then metronome = value end
end
function reaper.GetCursorPosition() return cursor end
function reaper.GetPlayPosition() update_transport(); return play_position end
function reaper.GetPlayState() return playing and 1 or 0 end
function reaper.TimeMap_GetDividedBpmAtTime() return 120 end
function reaper.TimeMap_GetTimeSigAtTime() return 4, 4 end
function reaper.TimeMap2_timeToQN(_, seconds) return seconds * 2 end
function reaper.TimeMap2_QNToTime(_, qn) return qn / 2 end
function reaper.TimeMap2_timeToBeats(_, seconds)
  return 0, math.floor(seconds / 2)
end
function reaper.TimeMap2_beatsToTime(_, _, measure) return measure * 2 end
function reaper.GetSetRepeat(value)
  if value and value >= 0 then repeat_enabled = value end
  return repeat_enabled
end
function reaper.OnPlayButton() update_transport(); playing = true end
function reaper.OnStopButton() update_transport(); playing = false end
function reaper.SetEditCurPos(value) cursor = value end
function reaper.GetProjExtState(_, section, key)
  local value = ext_state[section .. ":" .. key] or ""
  return value == "" and 0 or 1, value
end
function reaper.SetProjExtState(_, section, key, value)
  ext_state[section .. ":" .. key] = value
  return 1
end

function reaper.CountTracks() return #tracks end
function reaper.GetTrack(_, index) return tracks[index + 1] end
function reaper.GetTrackGUID(track) return track.guid end
function reaper.GetTrackName(track) return true, track.name end
function reaper.CountSelectedTracks() return selected and 1 or 0 end
function reaper.GetSelectedTrack() return selected end
function reaper.GetParentTrack() return nil end
function reaper.InsertTrackAtIndex(index)
  local track = {
    guid = string.format("{RPTK-TRACK-%d}", next_track),
    name = "", items = {}, depth = 0, ext = {},
  }
  next_track = next_track + 1
  table.insert(tracks, index + 1, track)
end
function reaper.GetSetMediaTrackInfo_String(track, key, value, set)
  if key == "P_NAME" then
    if set then track.name = value end
    return true, track.name
  end
  if set then track.ext[key] = value end
  return true, track.ext[key] or ""
end
function reaper.GetMediaTrackInfo_Value(track, key)
  if key == "IP_TRACKNUMBER" then return assert(track_index(track)) end
  if key == "I_FOLDERDEPTH" then return track.depth end
  return 0
end
function reaper.SetMediaTrackInfo_Value(track, key, value)
  if key == "I_FOLDERDEPTH" then track.depth = value end
  return true
end

function reaper.CountTrackMediaItems(track) return #track.items end
function reaper.GetTrackMediaItem(track, index) return track.items[index + 1] end
function reaper.CreateNewMIDIItemInProj(track, start_time, end_time)
  local item = {
    track = track, position = start_time, length = end_time - start_time,
    take = { notes = {} }, ext = {}, alive = true, values = {},
  }
  table.insert(track.items, item)
  return item
end
function reaper.GetActiveTake(item) return item.take end
function reaper.MIDI_InsertNote(take, _, _, start_ppq, end_ppq, channel, pitch, velocity)
  take.notes[#take.notes + 1] = {
    start_ppq = start_ppq, end_ppq = end_ppq, channel = channel,
    pitch = pitch, velocity = velocity,
  }
  return true
end
function reaper.MIDI_Sort() end
function reaper.GetSetMediaItemInfo_String(item, key, value, set)
  if set then item.ext[key] = value end
  return true, item.ext[key] or ""
end
function reaper.GetMediaItemInfo_Value(item, key)
  if key == "D_POSITION" then return item.position end
  if key == "D_LENGTH" then return item.length end
  return item.values[key] or 0
end
function reaper.SetMediaItemInfo_Value(item, key, value)
  if key == "D_POSITION" then item.position = value
  elseif key == "D_LENGTH" then item.length = value
  else item.values[key] = value end
  return true
end
function reaper.DeleteTrackMediaItem(track, item)
  for index, value in ipairs(track.items) do
    if value == item then
      item.alive = false
      table.remove(track.items, index)
      return true
    end
  end
  return false
end
function reaper.ValidatePtr(value) return value ~= nil and value.alive ~= false end
function reaper.UpdateArrange() end
function reaper.Undo_BeginBlock2() end
function reaper.Undo_EndBlock2() end
function reaper.StuffMIDIMessage(_, status, data1, data2)
  write_midi(status, data1, data2)
end

local host = dofile(root .. "reaper/rptk_host_core.lua")(root .. "reaper/")
assert(host.bootstrap(tcp_port, udp_port))

local ready = assert(io.open(ready_path, "w"))
ready:write("ready\n")
ready:close()

local socket = assert(host.socket)
local ok, err = xpcall(function()
  while true do
    local stop = io.open(stop_path, "r")
    if stop then stop:close(); break end
    host.tick(clock())
    socket.sleep(0.005)
  end
end, debug.traceback)
host.close()
if not ok then error(err) end
