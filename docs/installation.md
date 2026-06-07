# Installation And Upgrade

1. Install Python 3.11+ and install this checkout with
   `python -m pip install -e C:\Github\ReaperPythonToolkit`.
2. Install LuaSocket for the Lua runtime and architecture used by Reaper.
3. Copy `reaper/` intact to a stable directory under the Reaper resource path.
4. Load `rptk_host.lua` from Reaper's Action List and run it.
5. Confirm `[RPTK] host 0.1.0 listening on TCP 9901 and UDP 9900`.

For upgrades, run the action once to stop the old host, replace all RPTK Lua
files together, and run the action again. Do not mix host module versions.

The simplest Windows setup is to create `reaper/lua/` beside `rptk_host.lua`
and copy the same LuaSocket layout used by Metal MIDI Generator v3:

```text
reaper/lua/
  socket.lua
  ltn12.lua
  mime.lua
  socket/
    core.dll
    ftp.lua
    headers.lua
    http.lua
    smtp.lua
    tp.lua
    url.lua
  mime/
    core.dll
```

The host prepends this local directory to `package.path` and `package.cpath`,
then falls back to the normal Lua search paths. The DLL must match Reaper's
architecture. If LuaSocket is missing, the host prints an actionable startup
error. RPTK does not distribute unverified DLLs or shared libraries.
