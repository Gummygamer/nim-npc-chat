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

-- Text source from the proved policy (text_route.lua, generated from
-- Policy.bend): the on-device model first, hosted NIM with a key, else none.
local okLocal, LocalLlm = pcall(require, "mods.nim_npc_chat.local_llm")
local Route = require("mods.nim_npc_chat.text_route")
local route = Route.route(okLocal and LocalLlm.available() or false, Client.hasApiKey() and true or false)
local ran, body, err
if route == "local" then
  ran, body, err = pcall(LocalLlm.complete, requestBody, { seed = os.time() % 2147483647 })
elseif route == "hosted" then
  ran, body, err = pcall(Client.perform, requestBody, tag)
else
  ran, body, err = true, nil, "no text model: install the local model or set NVIDIA_API_KEY"
end
if not ran then
  channel:push(Client.encodeEnvelope(false, body))
elseif body then
  channel:push(Client.encodeEnvelope(true, body))
else
  channel:push(Client.encodeEnvelope(false, err))
end
