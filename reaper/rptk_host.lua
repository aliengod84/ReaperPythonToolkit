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

-- Determine "is a host already running?" by the authoritative source -- whether
-- the TCP port is actually bound -- not by the heartbeat ProjExtState. A crashed
-- or orphaned defer loop can keep the heartbeat fresh while its socket is dead
-- (a zombie), which used to wedge this action into only ever printing
-- "stop requested". If bootstrap binds the port, no real host is running and we
-- take over (clearing any stale flags); if the port is in use, a live host owns
-- it, so toggle a stop request instead.
local ok, err = host.bootstrap(9901, 9900)
if not ok then
  local _, heartbeat = reaper.GetProjExtState(0, NAMESPACE, HEARTBEAT)
  if reaper.time_precise() - (tonumber(heartbeat) or 0) < 2 then
    -- Port in use AND a live host is heartbeating: this is the toggle-off path.
    reaper.SetProjExtState(0, NAMESPACE, STOP, "1")
    reaper.ShowConsoleMsg("[RPTK] stop requested\n")
    return
  end
  -- Port in use but no fresh heartbeat: a stuck process holds the port. Surface
  -- the bind error so the user can act, rather than silently looping.
  reaper.ShowConsoleMsg("[RPTK] " .. err .. "\n")
  return
end
reaper.SetProjExtState(0, NAMESPACE, RUNNING, "1")
reaper.SetProjExtState(0, NAMESPACE, STOP, "")
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
