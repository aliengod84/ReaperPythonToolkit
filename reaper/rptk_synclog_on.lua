-- Turn RPTK synchronized-preview diagnostics ON.
-- Run this action, then reload rptk_host.lua. The host will print
-- "[RPTK] synclog diagnostics: ON" and emit [RPTK][transport|phase|preview|conn]
-- lines during Sync -> Play. See SYNC_DIAGNOSTICS.md in the MMG v3 project.
reaper.SetExtState("RPTK", "synclog", "1", true)
reaper.ShowConsoleMsg("[RPTK] synclog ON (reload rptk_host.lua to apply)\n")
