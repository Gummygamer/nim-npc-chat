package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Json = require("src.link.Json")
local Runtime = require("src.mods.Runtime")
local Client = require("mods.nim_npc_chat.nim_client")

local clean = Client.sanitizeReply("  Hello {PLAYER}!\r\nI can help.  ")
T.eq(clean, "Hello PLAYER!\nI can help.", "reply text is safe for TextBox tokens")

local request = Client.buildRequest({
  mapId = "PALLET_TOWN",
  vanillaText = "Technology is incredible!",
}, "What is new?", {})
local payload = Json.decode(request)
T.check(type(payload) == "table", "request is valid JSON")
T.eq(payload.messages[1].role, "system", "request starts with persona context")
T.check(payload.messages[1].content:find("Technology is incredible!", 1, true) ~= nil,
  "original dialogue grounds the persona")
T.check(payload.messages[1].content:find("only as background context", 1, true) ~= nil,
  "original dialogue is context rather than a scripted opening line")
T.eq(payload.messages[#payload.messages].content, "What is new?", "player text is last")
T.eq(payload.stream, false, "worker requests one non-streamed JSON response")

local reply, err = Client.parseCompletion(
  '{"choices":[{"message":{"role":"assistant","content":"Welcome home, trainer!"}}]}')
T.eq(err, nil, "valid completion has no error")
T.eq(reply, "Welcome home, trainer!", "assistant content is extracted")
local missing, apiErr = Client.parseCompletion('{"error":{"message":"bad key"}}')
T.eq(missing, nil, "API error is not dialogue")
T.eq(apiErr, "bad key", "API error message is preserved without credentials")

local liveGame = rawget(_G, "NIM_NPC_TEST_GAME")
local Data, run, game, pushed
if liveGame then
  Data, game = liveGame.data, liveGame
  for _, loaded in ipairs((liveGame.modStatus and liveGame.modStatus.loaded) or {}) do
    if loaded.id == "nim_npc_chat" then run = { release = function() end } break end
  end
  T.check(run ~= nil, "mod loads clean in LÖVE")
else
  Data = T.fixtures.fresh()
  run = T.sdk.loadMod("mods/nim_npc_chat", { data = Data })
  T.eq(#run.errors, 0, "mod loads clean")
  game = {
    data = Data,
    stack = { push = function(_, state) pushed = state end },
  }
end
T.check(Data.screens.NimNpcChat ~= nil, "chat screen is registered")
local finished = false
local ctx = {
  kind = "dialogue", npcId = "PALLET_TOWN_obj_1", mapId = "PALLET_TOWN",
  textId = "TEXT_PALLETTOWN_TECHNOLOGY_GUY", vanillaText = "Technology!",
  finish = function() finished = true end,
}
local handled = Runtime.call("world.npc.talk", function() return false end, game, ctx)
T.eq(handled, true, "public NPC talk hook is claimed for ambient dialogue")
if liveGame then
  pushed = game.stack:top()
  game:textinput("HI")
  T.eq(pushed.text, "HI", "Game text input reaches the active chat screen")
  pushed:onKeyPressed("backspace")
  T.eq(pushed.text, "H", "raw keyboard backspace edits the prompt")
  local drawOk, drawErr = pcall(pushed.draw, pushed)
  T.check(drawOk, "chat screen draws in LÖVE (" .. tostring(drawErr) .. ")")
  game.stack:pop()
else
  pushed = pushed
end
T.check(pushed ~= nil and pushed.mode == "input", "claim opens the chat screen")
T.eq(finished, false, "NPC remains frozen while the prompt is open")
pushed.text = ""
pushed:onTextInput("HELLO")
pushed:onTextInput(" ")
pushed:onTextInput("WORLD")
T.eq(pushed.text, "HELLO WORLD", "keyboard spaces survive between separately typed words")
T.eq(Client.sanitizeInput(pushed.text .. "  "), "HELLO WORLD",
  "submitted text still trims trailing draft spaces")

if not liveGame then pushed = nil end
local vanilla = Runtime.call("world.npc.talk", function() return false end, game, {
  kind = "script", finish = function() end,
})
T.eq(vanilla, false, "story scripts fall through to vanilla")
if liveGame then
  T.check(game.stack:top() ~= pushed, "story fallthrough opens no chat UI")
else
  T.eq(pushed, nil, "story fallthrough opens no chat UI")
end

run.release()
T.finish("nim_npc_chat")
