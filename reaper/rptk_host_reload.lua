local info = debug.getinfo(1, "S")
local root = info.source:sub(2):match("^(.*[\\/])")
local NAMESPACE = "RPTK"
local RUNNING = "host_running"
local STOP = "host_stop_requested"
local HEARTBEAT = "host_heartbeat"
local started_at = reaper.time_precise()
local timeout_seconds = 10

local function start_host()
  local command_id = reaper.AddRemoveReaScript(
    true, 0, root .. "rptk_host.lua", true
  )
  if not command_id or command_id == 0 then
    reaper.ShowConsoleMsg("[RPTK] reload failed to register rptk_host.lua\n")
    return
  end
  reaper.ShowConsoleMsg("[RPTK] starting reloaded host\n")
  reaper.Main_OnCommand(command_id, 0)
end

local function host_is_live()
  local _, running = reaper.GetProjExtState(0, NAMESPACE, RUNNING)
  local _, heartbeat = reaper.GetProjExtState(0, NAMESPACE, HEARTBEAT)
  return running == "1"
    and reaper.time_precise() - (tonumber(heartbeat) or 0) < 2
end

local function wait_for_stop()
  local _, running = reaper.GetProjExtState(0, NAMESPACE, RUNNING)
  if running ~= "1" then
    start_host()
    return
  end
  if reaper.time_precise() - started_at >= timeout_seconds then
    reaper.ShowConsoleMsg(
      "[RPTK] reload timed out waiting for the old host to stop\n"
    )
    return
  end
  reaper.defer(wait_for_stop)
end

if host_is_live() then
  reaper.ShowConsoleMsg("[RPTK] reload requested\n")
  reaper.SetProjExtState(0, NAMESPACE, STOP, "1")
  reaper.defer(wait_for_stop)
else
  start_host()
end
