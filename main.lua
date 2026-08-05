local Client = require("mods.nim_npc_chat.nim_client")

local SCREEN = "NimNpcChat"
local histories = {}
local requestSerial = 0

local GRID = {
  { "A", "B", "C", "D", "E", "F", "G", "H", "I", "J" },
  { "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T" },
  { "U", "V", "W", "X", "Y", "Z", ".", ",", "?", "!" },
  { "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" },
  { "SPC", "DEL", "SEND", "EXIT" },
}
local LAST_X = { 8, 40, 72, 112 }

return function(mod)
  Client.cleanupStagedFiles()
  mod.options:define({
    { key = "enabled", label = "AI NPC CHAT", type = "toggle", default = true },
  })

  local Chat = {}
  Chat.__index = Chat

  function Chat.new(game, ctx)
    return setmetatable({
      game = game, ctx = ctx, text = "", row = 1, col = 1,
      mode = "input", blink = 0,
    }, Chat)
  end

  function Chat:enter()
    if love.keyboard and love.keyboard.setTextInput then
      pcall(love.keyboard.setTextInput, true)
    end
  end

  function Chat:exit()
    if love.keyboard and love.keyboard.setTextInput then
      pcall(love.keyboard.setTextInput, false)
    end
  end

  function Chat:append(value)
    if self.mode ~= "input" then return end
    self.text = Client.sanitizeDraft(self.text .. tostring(value or ""))
  end

  function Chat:backspace()
    if self.mode ~= "input" or self.text == "" then return end
    local last = #self.text
    while last > 1 and self.text:byte(last) >= 0x80 and self.text:byte(last) <= 0xBF do
      last = last - 1
    end
    self.text = self.text:sub(1, last - 1)
  end

  function Chat:cancel()
    if self.mode == "waiting" then return end
    self.game.stack:pop()
    self.ctx.finish()
  end

  function Chat:finishWith(text)
    self.game.stack:pop()
    self.game.stack:push(mod.ui.TextBox.new(self.game, text, self.ctx.finish))
  end

  function Chat:submit()
    if self.mode ~= "input" then return end
    local question = Client.sanitizeInput(self.text)
    if question == "" then return end
    if not Client.hasApiKey() then
      self:finishWith("NIM needs the\nNVIDIA_API_KEY\nenvironment variable.")
      return
    end
    if not (love.thread and love.thread.newThread and love.thread.getChannel) then
      self:finishWith("NIM chat needs a\nLÖVE build with\nthread support.")
      return
    end

    local npcKey = tostring(self.ctx.npcId or (self.ctx.mapId .. ":" .. self.ctx.textId))
    local history = histories[npcKey] or {}
    local request = Client.buildRequest(self.ctx, question, history)
    requestSerial = requestSerial + 1
    local tag = "nim_npc_" .. tostring(requestSerial)
    local channelName = tag .. "_result"
    local okChannel, channel = pcall(love.thread.getChannel, channelName)
    local okThread, thread = pcall(love.thread.newThread,
      mod.path .. "/nim_worker.lua")
    if not okChannel or not channel or not okThread or not thread then
      self:finishWith("Could not start the\nNIM network worker.")
      return
    end
    local started, startErr = pcall(thread.start, thread, channelName, request, tag)
    if not started then
      mod.log:error("NIM worker did not start: " .. tostring(startErr)
        .. " -- verify this LÖVE build has thread support")
      self:finishWith("Could not start the\nNIM network worker.")
      return
    end
    self.mode = "waiting"
    self.question = question
    self.channel = channel
    self.thread = thread
  end

  function Chat:onTextInput(text)
    self:append(text)
  end

  function Chat:onKeyPressed(key)
    if self.mode ~= "input" then return end
    if key == "escape" then self:cancel()
    elseif key == "backspace" then self:backspace()
    elseif key == "return" or key == "kpenter" then self:submit()
    elseif key == "left" then self.col = math.max(1, self.col - 1)
    elseif key == "right" then self.col = math.min(#GRID[self.row], self.col + 1)
    elseif key == "up" then
      self.row = math.max(1, self.row - 1); self.col = math.min(self.col, #GRID[self.row])
    elseif key == "down" then
      self.row = math.min(#GRID, self.row + 1); self.col = math.min(self.col, #GRID[self.row])
    elseif key == "v" and love.keyboard and love.keyboard.isDown
        and (love.keyboard.isDown("lctrl") or love.keyboard.isDown("rctrl"))
        and love.system and love.system.getClipboardText then
      self:append(love.system.getClipboardText())
    end
  end

  function Chat:chooseGrid()
    local value = GRID[self.row][self.col]
    if value == "SPC" then self:append(" ")
    elseif value == "DEL" then self:backspace()
    elseif value == "SEND" then self:submit()
    elseif value == "EXIT" then self:cancel()
    else self:append(value) end
  end

  function Chat:acceptWorkerResult(envelope)
    local body, workerErr = Client.decodeEnvelope(envelope)
    if not body then
      mod.log:warn("NIM request failed: " .. tostring(workerErr)
        .. " -- check NVIDIA_API_KEY, model access, and network connectivity")
      self:finishWith("NIM could not answer.\nCheck the key, model,\nand network.")
      return
    end
    local reply, parseErr = Client.parseCompletion(body)
    if not reply then
      mod.log:warn("NIM response was unusable: " .. tostring(parseErr)
        .. " -- try another NVIDIA_NIM_MODEL")
      self:finishWith("NIM returned no\ndialogue. Try another\nmodel.")
      return
    end
    local key = tostring(self.ctx.npcId or (self.ctx.mapId .. ":" .. self.ctx.textId))
    local history = histories[key] or {}
    history[#history + 1] = { role = "user", content = self.question }
    history[#history + 1] = { role = "assistant", content = reply }
    while #history > 6 do table.remove(history, 1) end
    histories[key] = history
    self:finishWith(reply)
  end

  function Chat:update()
    self.blink = (self.blink + 1) % 60
    if self.mode == "waiting" then
      local envelope = self.channel and self.channel:pop()
      if envelope then self:acceptWorkerResult(envelope) end
      return
    end
    local input = self.game.input
    if not input then return end
    if input:wasPressed("up") then
      self.row = math.max(1, self.row - 1); self.col = math.min(self.col, #GRID[self.row])
    elseif input:wasPressed("down") then
      self.row = math.min(#GRID, self.row + 1); self.col = math.min(self.col, #GRID[self.row])
    elseif input:wasPressed("left") then self.col = math.max(1, self.col - 1)
    elseif input:wasPressed("right") then self.col = math.min(#GRID[self.row], self.col + 1)
    elseif input:wasPressed("b") then self:backspace()
    elseif input:wasPressed("start") then self:submit()
    elseif input:wasPressed("a") then self:chooseGrid() end
  end

  local function inputLines(text)
    local lines, pos = {}, 1
    while pos <= #text do
      lines[#lines + 1] = text:sub(pos, pos + 17)
      pos = pos + 18
    end
    if #lines == 0 then lines[1] = "" end
    while #lines > 3 do table.remove(lines, 1) end
    return lines
  end

  function Chat:draw()
    local Font, Theme = mod.ui.Font, mod.ui.Theme
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.rectangle("fill", 0, 0, 160, 144)
    love.graphics.setColor(0, 0, 0, 1)
    Font.draw("NIM NPC CHAT", 8, 0)
    if self.mode == "waiting" then
      Font.drawBox(1, 3, 18, 7)
      love.graphics.setColor(0, 0, 0, 1)
      Font.draw("ASKING NVIDIA NIM", 16, 40)
      Font.draw("PLEASE WAIT" .. ((self.blink < 30) and "..." or ""), 32, 64)
      Font.draw("THE GAME IS STILL", 16, 88)
      Font.draw("RESPONSIVE.", 40, 104)
      return
    end
    Font.drawBox(1, 1, 18, 6)
    love.graphics.setColor(0, 0, 0, 1)
    local lines = inputLines(self.text)
    for i, line in ipairs(lines) do Font.draw(line, 16, 16 + (i - 1) * 16) end
    if self.blink < 30 and #lines[#lines] < 18 then
      Font.drawCode(Theme.cursorHollow,
        16 + #lines[#lines] * 8, 16 + (#lines - 1) * 16)
    end
    for r = 1, 4 do
      for c, value in ipairs(GRID[r]) do Font.draw(value, 8 + (c - 1) * 15, 56 + (r - 1) * 16) end
    end
    for c, value in ipairs(GRID[5]) do Font.draw(value, LAST_X[c], 120) end
    local cx = self.row == 5 and LAST_X[self.col] - 8 or (self.col - 1) * 15
    Font.drawCode(Theme.cursor, cx, 56 + (self.row - 1) * 16)
    love.graphics.setColor(1, 1, 1, 1)
  end

  mod.content.screens:register(SCREEN, { new = Chat.new })

  mod.hooks:wrap("world.npc.talk", function(next, game, ctx)
    if not mod.options:get("enabled") or type(ctx) ~= "table"
        or ctx.kind ~= "dialogue" then
      return next(game, ctx)
    end
    mod.ui.push(game, SCREEN, ctx)
    return true
  end)

  mod.exports.sanitizeReply = Client.sanitizeReply
  mod.exports.buildRequest = Client.buildRequest
end
