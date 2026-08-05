-- One request per thread: no idle worker can keep LÖVE alive after the game
-- closes, and NIM latency never blocks the render/update thread.
require("love.thread")
-- Worker Lua states load modules independently.  HostShell uses love.system
-- to choose cmd.exe vs POSIX quoting and love.filesystem for the private
-- staging directory, so make both explicit before it is required.
require("love.system")
require("love.filesystem")

local channelName, requestBody, tag = ...
local channel = love.thread.getChannel(channelName)
local ok, Client = pcall(require, "mods.nim_npc_chat.nim_client")
if not ok then
  channel:push('{"ok":false,"error":"could not load NIM client"}')
  return
end

local ran, body, err = pcall(Client.perform, requestBody, tag)
if not ran then
  channel:push(Client.encodeEnvelope(false, body))
elseif body then
  channel:push(Client.encodeEnvelope(true, body))
else
  channel:push(Client.encodeEnvelope(false, err))
end
