-- Shared on-disk diagnostics logger for the RPTK Reaper host.
--
-- Writes timestamped lines to a dated file in a well-known directory that other
-- tools (and AI agents) can read directly:
--
--     <home>/.sync_logs/rptk_<YYYYMMDD>.log
--
-- where <home> is %USERPROFILE% on Windows or $HOME elsewhere. The matching
-- MMG-side logger (metalmidigenerator3/synclog.py) writes mmg_<YYYYMMDD>.log to
-- the same directory, so the two streams interleave by wall-clock timestamp.
--
-- Gated by the "RPTK"/"synclog" ExtState ("1" = on). Toggle with the
-- rptk_synclog_on.lua / rptk_synclog_off.lua actions. Always also mirrors to the
-- ReaScript console when on, so nothing is lost if the file can't be opened.
--
-- This module is intentionally generic: call synclog.line(category, message)
-- from anywhere in the host for any future logging session.

local synclog = { _dir = nil, _path = nil, _day = nil }

local function home_dir()
  return os.getenv("USERPROFILE") or os.getenv("HOME") or "."
end

function synclog.dir()
  if not synclog._dir then
    synclog._dir = home_dir():gsub("\\", "/") .. "/.sync_logs"
  end
  return synclog._dir
end

local function ensure_dir(dir)
  -- Best-effort create; ignore failure (open will then fall back to console).
  if reaper and reaper.RecursiveCreateDirectory then
    reaper.RecursiveCreateDirectory(dir, 0)
  end
end

local function path_for_today()
  local day = os.date("%Y%m%d")
  if synclog._day ~= day then
    synclog._day = day
    synclog._path = synclog.dir() .. "/rptk_" .. day .. ".log"
    ensure_dir(synclog.dir())
  end
  return synclog._path
end

function synclog.enabled()
  return reaper and reaper.GetExtState and reaper.GetExtState("RPTK", "synclog") == "1"
end

-- Emit one diagnostic line. Always-on callers (errors) can pass force=true to
-- write even when the gate is off.
function synclog.line(category, message, force)
  if not force and not synclog.enabled() then return end
  -- Millisecond wall-clock stamp so it interleaves with the MMG file.
  local stamp = os.date("%Y-%m-%dT%H:%M:%S")
  local frac = ""
  if reaper and reaper.time_precise then
    frac = string.format(".%03d", math.floor((reaper.time_precise() % 1) * 1000))
  end
  local text = string.format("[%s%s][RPTK][%s] %s", stamp, frac, category, message)
  local path = path_for_today()
  local file = io.open(path, "a")
  if file then
    -- One-time, low-noise console pointer per session: where the logs are going.
    if not synclog._announced and reaper and reaper.ShowConsoleMsg then
      synclog._announced = true
      reaper.ShowConsoleMsg("[RPTK] synclog -> " .. path .. " (console mirror off)\n")
    end
    file:write(text .. "\n")
    file:close()
  elseif reaper and reaper.ShowConsoleMsg then
    -- File unavailable: fall back to console so nothing is lost, and say why once.
    if not synclog._fallback_announced then
      synclog._fallback_announced = true
      reaper.ShowConsoleMsg("[RPTK] synclog file unavailable, mirroring to console\n")
    end
    reaper.ShowConsoleMsg(text .. "\n")
  end
end

return synclog
