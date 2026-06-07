local info = debug.getinfo(1, "S")
local root = info.source:sub(2):match("^(.*[\\/])")
local host = dofile(root .. "rptk_host_core.lua")(root)
local _, _, section_id, command_id = reaper.get_action_context()
local NAMESPACE = "RPTK"
local RUNNING = "host_running"
local STOP = "host_stop_requested"
local HEARTBEAT = "host_heartbeat"

local function toggle(value)
  if section_id and command_id and command_id ~= 0 then
    reaper.SetToggleCommandState(section_id, command_id, value)
    reaper.RefreshToolbar2(section_id, command_id)
  end
end

local _, running = reaper.GetProjExtState(0, NAMESPACE, RUNNING)
if running == "1" then
  local _, heartbeat = reaper.GetProjExtState(0, NAMESPACE, HEARTBEAT)
  if reaper.time_precise() - (tonumber(heartbeat) or 0) < 2 then
    reaper.SetProjExtState(0, NAMESPACE, STOP, "1")
    reaper.ShowConsoleMsg("[RPTK] stop requested\n")
    return
  end
end
reaper.SetProjExtState(0, NAMESPACE, RUNNING, "")
reaper.SetProjExtState(0, NAMESPACE, STOP, "")
reaper.SetProjExtState(0, NAMESPACE, HEARTBEAT, "")

local ok, err = host.bootstrap(9901, 9900)
if not ok then reaper.ShowConsoleMsg("[RPTK] " .. err .. "\n"); return end
reaper.SetProjExtState(0, NAMESPACE, RUNNING, "1")
toggle(1)

local function cleanup()
  host.close()
  reaper.SetProjExtState(0, NAMESPACE, RUNNING, "")
  reaper.SetProjExtState(0, NAMESPACE, STOP, "")
  reaper.SetProjExtState(0, NAMESPACE, HEARTBEAT, "")
  toggle(0)
end

local function main()
  local _, stop = reaper.GetProjExtState(0, NAMESPACE, STOP)
  if stop == "1" then cleanup(); reaper.ShowConsoleMsg("[RPTK] host stopped\n"); return end
  local now = reaper.time_precise()
  local tick_ok, tick_err = pcall(host.tick, now)
  if not tick_ok then reaper.ShowConsoleMsg("[RPTK] tick error: " .. tostring(tick_err) .. "\n") end
  reaper.SetProjExtState(0, NAMESPACE, HEARTBEAT, tostring(now))
  reaper.defer(main)
end

reaper.atexit(cleanup)
main()
