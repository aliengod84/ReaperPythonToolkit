-- Turn RPTK synchronized-preview diagnostics OFF.
-- Run this action, then run rptk_host_reload.lua. The host will print
-- "[RPTK] synclog diagnostics: OFF" and stop emitting [RPTK][...] sync lines.
-- See SYNC_DIAGNOSTICS.md in the MMG v3 project.
reaper.SetExtState("RPTK", "synclog", "0", true)
reaper.ShowConsoleMsg("[RPTK] synclog OFF (run rptk_host_reload.lua to apply)\n")
