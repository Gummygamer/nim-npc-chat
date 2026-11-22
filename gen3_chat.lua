-- FireRed / LeafGreen arm of NVIDIA NIM NPC Chat.
--
-- Gen 3 has no screen registry and no TextBox: NPC dialogue is bytecode run by
-- the script VM, and the field UI is src/ui/game3.  So this arm
--   * claims the A press on an object through the `world.talk` hook,
--   * decides from the NPC's own script whether it is harmless small talk,
--   * owns a small typing overlay through `input.key`, `input.gamepad` and
--     `render.hud` while the player is asking, and
--   * shows the reply in the engine's own field message box.
-- Anything that is not plain small talk (trainers, shops, items, gifts, story
-- branches, Pokemon Centers) falls through to the original script untouched.

local Client = require("mods.nim_npc_chat.nim_client")

local Gen3Chat = {}

local LOCK_TAG = "nim_npc_chat"
local SCREEN_W, SCREEN_H = 240, 160

local GRID = {
  { "A", "B", "C", "D", "E", "F", "G", "H", "I", "J" },
  { "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T" },
  { "U", "V", "W", "X", "Y", "Z", ".", ",", "?", "!" },
  { "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" },
  { "SPC", "DEL", "SEND", "EXIT" },
}
local GRID_X = 16
local GRID_STEP = 20
local GRID_Y = 56
local LAST_ROW_X = { 16, 64, 112, 168 }

-- Script ops that cannot change the game.  A script made only of these (plus
-- one or more message boxes) is an ambient NPC; a branch, a battle, a shop or
-- a flag write anywhere in it leaves the NPC to the original script.
local HARMLESS_OPS = {
  lock = true, lockall = true, faceplayer = true, release = true,
  releaseall = true, loadword = true, callstd = true, message = true,
  waitmessage = true, waitbuttonpress = true, closemessage = true,
  textcolor = true, ["end"] = true, nop = true,
}
-- pokefirered/include/constants/script_menu.h: MSGBOX_NPC, MSGBOX_DEFAULT.
local HARMLESS_STD = { [2] = true, [4] = true }

local function modules()
  local ok, Space = pcall(require, "src.core.game3.scripting.space")
  local okO, Opcodes = pcall(require, "src.core.game3.scripting.opcodes")
  local okT, TextIR = pcall(require, "src.core.game3.scripting.text_ir")
  return ok and Space or nil, okO and Opcodes or nil, okT and TextIR or nil
end

local function flatten(text)
  return (tostring(text or ""):gsub("[%c]+", " "):gsub("%s+", " "))
end

-- Reads one NPC's script and reports whether it is plain dialogue, and what
-- the original line said.  Returns nil for anything else.
function Gen3Chat.classify(object)
  local def = object and object.def
  local key = def and def.scriptKey
  if not key then return nil end
  local Space, Opcodes, TextIR = modules()
  local vm = Space and Space.vm
  local rows = vm and vm.scripts and vm.scripts[key]
  if type(rows) ~= "table" or #rows == 0 then return nil end

  local textPtr, messages = nil, 0
  for _, row in ipairs(rows) do
    local op = row.op
    if not HARMLESS_OPS[op] then return nil end
    if op == "callstd" then
      if not HARMLESS_STD[tonumber(row.std or row[1])] then return nil end
      messages = messages + 1
    elseif op == "message" then
      messages = messages + 1
      textPtr = textPtr or row.ptr or row[1]
    elseif op == "loadword" and (row.dest or row[1] or 0) == 0 then
      textPtr = textPtr or row.value or row[2]
    end
  end
  if messages == 0 then return nil end

  local vanilla
  if textPtr ~= nil and TextIR and vm.getText then
    local textKey = type(textPtr) == "string" and textPtr
      or (Opcodes and Opcodes.key and Opcodes.key(textPtr))
    local ir = (textKey and vm:getText(textKey)) or vm:getText(textPtr)
    if type(ir) == "table" then
      local okText, plain = pcall(TextIR.toTextBox, ir, { maxWidth = 4096 })
      if okText then vanilla = flatten(plain) end
    end
  end
  return { kind = "dialogue", vanillaText = vanilla }
end

local function mapLabel()
  local Collision = package.loaded["src.core.game3.collision"]
  local id = Collision and Collision._mapId
  if type(id) ~= "string" then return "KANTO" end
  local label = id:gsub("^[A-Z][A-Z]_", ""):gsub("_", " ")
  return label
end

local SHIFTED = { ["1"] = "!", ["/"] = "?", ["'"] = '"', ["-"] = "_" }
local PUNCT = { space = " ", ["."] = ".", [","] = ",", ["-"] = "-", ["'"] = "'",
  ["/"] = "/" }

local function shiftDown()
  return love.keyboard and love.keyboard.isDown
    and (love.keyboard.isDown("lshift") or love.keyboard.isDown("rshift")) or false
end

local function keyToText(key)
  if #key == 1 and key:match("%l") then
    return shiftDown() and key:upper() or key
  end
  if #key == 1 and key:match("%d") then
    return shiftDown() and SHIFTED[key] or key
  end
  if shiftDown() and SHIFTED[key] then return SHIFTED[key] end
  return PUNCT[key]
end

function Gen3Chat.install(mod)
  local histories = {}
  local requestSerial = 0
  local chat = nil
  local warnedDraw = false

  local function modules3()
    local okF, Field = pcall(require, "src.core.game3.field")
    local okO, Objects = pcall(require, "src.core.game3.objects")
    local okM, Message = pcall(require, "src.ui.game3.message")
    return okF and Field or nil, okO and Objects or nil, okM and Message or nil
  end

  local function release()
    if not chat then return end
    local Field, Objects = modules3()
    if Objects and chat.localId then pcall(Objects.unfreeze, chat.localId) end
    if Field and Field.unlock then pcall(Field.unlock, LOCK_TAG) end
    if chat.textInput and love.keyboard and love.keyboard.setTextInput then
      pcall(love.keyboard.setTextInput, false)
    end
    chat = nil
  end

  local function say(text)
    local _, _, Message = modules3()
    if not Message then release(); return end
    -- The box takes over input; the overlay stops drawing and swallowing.
    chat.mode = "reply"
    local ok, err = pcall(Message.show, text, { done = release })
    if not ok then
      mod.log:warn("could not show the NPC reply: " .. tostring(err))
      release()
    end
  end

  local function submit()
    if not chat or chat.mode ~= "input" then return end
    local question = Client.sanitizeInput(chat.text)
    if question == "" then return end
    chat.route = require("mods.nim_npc_chat.text_route").route(
      require("mods.nim_npc_chat.local_llm").available(), Client.hasApiKey() and true or false)
    if chat.route == "refuse" then
      return say("No text model: add\nthe local model or\nset NVIDIA_API_KEY.")
    end
    if not (love.thread and love.thread.newThread and love.thread.getChannel) then
      return say("NPC chat needs a\nLOVE build with\nthread support.")
    end
    local history = histories[chat.npcKey] or {}
    local request = Client.buildRequest(chat.ctx, question, history)
    requestSerial = requestSerial + 1
    local tag = "nim_npc_" .. tostring(requestSerial)
    local channelName = tag .. "_result"
    local okChannel, channel = pcall(love.thread.getChannel, channelName)
    local okThread, thread = pcall(love.thread.newThread,
      mod.path .. "/nim_worker.lua")
    if not okChannel or not channel or not okThread or not thread then
      return say("Could not start the\nNPC chat worker.")
    end
    local started, startErr = pcall(thread.start, thread, channelName, request, tag)
    if not started then
      mod.log:error("NPC chat worker did not start: " .. tostring(startErr)
        .. " -- verify this LOVE build has thread support")
      return say("Could not start the\nNPC chat worker.")
    end
    chat.mode, chat.question = "waiting", question
    chat.channel, chat.thread = channel, thread
  end

  local function acceptResult(envelope)
    local body, workerErr = Client.decodeEnvelope(envelope)
    if not body then
      mod.log:warn("NPC chat request failed (route " .. tostring(chat.route) .. "): " .. tostring(workerErr)
        .. " -- check NVIDIA_API_KEY, model access, and network connectivity")
      if chat.route == "local" then return say("The local model\ncould not answer.") end
      return say("NIM could not answer.\nCheck the key, model,\nand network.")
    end
    local reply, parseErr = Client.parseCompletion(body)
    if not reply then
      mod.log:warn("NPC chat response was unusable (route " .. tostring(chat.route) .. "): " .. tostring(parseErr)
        .. " -- try another NVIDIA_NIM_MODEL")
      if chat.route == "local" then return say("The local model\nreturned no dialogue.") end
      return say("NIM returned no\ndialogue. Try another\nmodel.")
    end
    reply = reply:gsub("\\", "")
    local history = histories[chat.npcKey] or {}
    history[#history + 1] = { role = "user", content = chat.question }
    history[#history + 1] = { role = "assistant", content = reply }
    while #history > 6 do table.remove(history, 1) end
    histories[chat.npcKey] = history
    say(reply)
  end

  local function append(value)
    if chat and chat.mode == "input" then
      chat.text = Client.sanitizeDraft(chat.text .. tostring(value or ""))
    end
  end

  local function backspace()
    if not chat or chat.mode ~= "input" or chat.text == "" then return end
    chat.text = chat.text:sub(1, #chat.text - 1)
  end

  local function chooseGrid()
    local value = GRID[chat.row][chat.col]
    if value == "SPC" then append(" ")
    elseif value == "DEL" then backspace()
    elseif value == "SEND" then submit()
    elseif value == "EXIT" then release()
    else append(value) end
  end

  local function moveCursor(dRow, dCol)
    chat.row = math.max(1, math.min(#GRID, chat.row + dRow))
    chat.col = math.max(1, math.min(#GRID[chat.row], chat.col + dCol))
  end

  local function onKey(key)
    if chat.mode ~= "input" then return end
    if key == "escape" then release()
    elseif key == "backspace" then backspace()
    elseif key == "return" or key == "kpenter" then submit()
    elseif key == "up" then moveCursor(-1, 0)
    elseif key == "down" then moveCursor(1, 0)
    elseif key == "left" then moveCursor(0, -1)
    elseif key == "right" then moveCursor(0, 1)
    elseif key == "v" and love.system and love.system.getClipboardText
        and love.keyboard and love.keyboard.isDown
        and (love.keyboard.isDown("lctrl") or love.keyboard.isDown("rctrl")) then
      append(love.system.getClipboardText())
    else
      local text = keyToText(key)
      if text then append(text) end
    end
  end

  local function onPad(button)
    if chat.mode ~= "input" then return end
    if button == "dpup" then moveCursor(-1, 0)
    elseif button == "dpdown" then moveCursor(1, 0)
    elseif button == "dpleft" then moveCursor(0, -1)
    elseif button == "dpright" then moveCursor(0, 1)
    elseif button == "b" then backspace()
    elseif button == "start" then submit()
    elseif button == "a" then chooseGrid() end
  end

  local function begin(game, object, info)
    local Field, Objects = modules3()
    if not (Field and Field.lock) then return false end
    local def = object.def or {}
    local localId = object.localId or def.localId or def.index
    Field.lock(LOCK_TAG)
    if Objects and localId then
      pcall(Objects.freeze, localId)
      pcall(Objects.facePlayer, localId, game)
    end
    local label = mapLabel()
    chat = {
      localId = localId, text = "", row = 1, col = 1, mode = "input", blink = 0,
      npcKey = label .. ":" .. tostring(localId or def.scriptKey),
      ctx = {
        mapId = label, vanillaText = info.vanillaText,
        gameName = "Pokemon FireRed and LeafGreen", region = "Kanto",
      },
    }
    if love.keyboard and love.keyboard.setTextInput then
      pcall(love.keyboard.setTextInput, true)
      chat.textInput = true
    end
    return true
  end

  mod.hooks:wrap("world.talk", function(next, game, object)
    if chat then return end
    if not mod.options:get("enabled") then return next(game, object) end
    local info = Gen3Chat.classify(object)
    if not info or not begin(game, object, info) then return next(game, object) end
  end)

  -- Swallow only presses: a release must always reach the engine so a key
  -- that was held when the chat opened cannot stay stuck down afterwards.
  mod.hooks:wrap("input.key", function(next, game, ev)
    if not chat or chat.mode == "reply" or ev.phase ~= "pressed" then
      return next(game, ev)
    end
    onKey(ev.key)
    return true
  end)

  mod.hooks:wrap("input.gamepad", function(next, game, ev)
    if not chat or chat.mode == "reply" or ev.phase ~= "pressed" then
      return next(game, ev)
    end
    onPad(ev.button)
    return true
  end)

  mod.hooks:wrap("input.step", function(next, game, dt)
    next(game, dt)
    if not chat then return end
    if game and game.phase ~= nil and game.phase ~= "field" then return release() end
    chat.blink = (chat.blink + 1) % 60
    if chat.mode == "waiting" then
      local envelope = chat.channel and chat.channel:pop()
      if envelope then acceptResult(envelope) end
    end
  end)

  local function frame(tx, ty, tw, th)
    local ok, Chrome = pcall(require, "src.ui.game3.chrome")
    if ok and Chrome and Chrome.stdFrame then
      local drawn = pcall(Chrome.stdFrame, tx, ty, tw, th)
      if drawn then return end
    end
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.rectangle("fill", tx * 8, ty * 8, tw * 8, th * 8)
    love.graphics.setColor(0, 0, 0, 1)
    love.graphics.rectangle("line", tx * 8, ty * 8, tw * 8, th * 8)
  end

  local function text(value, x, y)
    local ok, Font = pcall(require, "src.ui.game3.frlg_font")
    if ok and Font and Font.draw then
      love.graphics.setColor(1, 1, 1, 1)
      if pcall(Font.draw, value, x, y, {}) then return end
    end
    love.graphics.setColor(0, 0, 0, 1)
    love.graphics.print(value, x, y)
  end

  local function drawChat()
    if chat.mode == "waiting" then
      frame(2, 7, 26, 4)
      local who = chat.route == "local" and "ASKING DORY" or "ASKING NVIDIA NIM"
      text(who .. ((chat.blink < 30) and "..." or ""), 24, 64)
      text("PLEASE WAIT", 24, 80)
      return
    end
    frame(1, 1, 28, 3)
    local lines = {}
    local okFont, Font = pcall(require, "src.ui.game3.frlg_font")
    local shown = chat.text .. ((chat.blink < 30) and "_" or " ")
    if okFont and Font and Font.wrap then
      local okWrap, wrapped = pcall(Font.wrap, shown, 208)
      if okWrap and type(wrapped) == "string" then
        for line in (wrapped .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
      end
    end
    if #lines == 0 then lines[1] = shown end
    while #lines > 2 do table.remove(lines, 1) end
    for index, line in ipairs(lines) do text(line, 16, 8 + (index - 1) * 16) end

    frame(1, 6, 28, 11)
    for r = 1, 4 do
      for c, value in ipairs(GRID[r]) do
        text(value, GRID_X + (c - 1) * GRID_STEP, GRID_Y + (r - 1) * 16)
      end
    end
    for c, value in ipairs(GRID[5]) do text(value, LAST_ROW_X[c], GRID_Y + 64) end
    local cx = chat.row == 5 and LAST_ROW_X[chat.col] or GRID_X + (chat.col - 1) * GRID_STEP
    text(">", cx - 8, GRID_Y + (chat.row - 1) * 16)
  end

  mod.hooks:wrap("render.hud", function(next, game, viewport)
    next(game, viewport)
    if not chat or chat.mode == "reply" then return end
    love.graphics.push("all")
    love.graphics.translate(viewport.gameX or 0, viewport.gameY or 0)
    love.graphics.scale((viewport.gameWidth or SCREEN_W) / SCREEN_W,
      (viewport.gameHeight or SCREEN_H) / SCREEN_H)
    local ok, err = pcall(drawChat)
    love.graphics.pop()
    if not ok and not warnedDraw then
      warnedDraw = true
      mod.log:warn("NPC chat overlay failed to draw: " .. tostring(err))
    end
  end)

  mod.exports.classify = Gen3Chat.classify
  mod.exports.keyToText = keyToText
end

return Gen3Chat
