# Installation And Upgrade

1. Install Python 3.11+ and `pip install reaper-python-toolkit`.
2. Install LuaSocket for the Lua runtime and architecture used by Reaper.
3. Copy `reaper/` intact to a stable directory under the Reaper resource path.
4. Load `rptk_host.lua` from Reaper's Action List and run it.
5. Confirm `[RPTK] host 0.1.0 listening on TCP 9901 and UDP 9900`.

For upgrades, run the action once to stop the old host, replace all RPTK Lua
files together, and run the action again. Do not mix host module versions.

The host searches normal Lua `package.path`/`package.cpath`. If LuaSocket is
missing it prints an actionable startup error. RPTK does not distribute
unverified DLLs or shared libraries.

