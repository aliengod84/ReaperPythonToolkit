# Local LuaSocket Directory

This directory is intentionally source-only in Git. Copy a LuaSocket build
compatible with Reaper into this layout:

```text
lua/
  socket.lua
  ltn12.lua
  mime.lua
  socket/core.dll
  socket/ftp.lua
  socket/headers.lua
  socket/http.lua
  socket/smtp.lua
  socket/tp.lua
  socket/url.lua
  mime/core.dll
```

On non-Windows platforms, use the equivalent compatible `core.so` modules.
The host prepends this directory to Lua's module search paths.
