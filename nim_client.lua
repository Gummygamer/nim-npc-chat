local Json = require("src.link.Json")
local HostShell = require("src.core.HostShell")

local Client = {}

Client.DEFAULT_BASE_URL = "https://integrate.api.nvidia.com/v1"
-- meta/llama-3.1-8b-instruct reached end of life on the hosted NIM API on
-- 2026-08-26 and now answers 410 Gone. Its replacement,
-- mistralai/mistral-7b-instruct-v0.3, is still listed by /v1/models but its
-- backing function is gone, so it answers 404 Function ... Not found for
-- account. minimaxai/minimax-m3 is a non-reasoning instruct model the same
-- endpoint does serve: same request shape, plain content in
-- choices[1].message.content, and short NPC answers inside the 60s budget.
Client.DEFAULT_MODEL = "minimaxai/minimax-m3"

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function ascii(s, limit, keepEdgeSpaces)
  s = tostring(s or "")
  s = s:gsub("Pok\195\169mon", "POK\195\169MON")
       :gsub("\226\128\152", "'"):gsub("\226\128\153", "'")
       :gsub("\226\128\156", '"'):gsub("\226\128\157", '"')
       :gsub("\226\128\147", "-"):gsub("\226\128\148", "-")
  -- Keep the one Gen 1 accented glyph and make every other unsupported
  -- UTF-8 sequence visible rather than handing Font malformed bytes.
  s = s:gsub("\195\169", "\1")
  s = s:gsub("[\128-\255]", "?")
  s = s:gsub("\1", "\195\169")
  s = s:gsub("[\r\t\v\f]", " "):gsub("[{}]", "")
  s = s:gsub(" +", " "):gsub(" *\n *", "\n"):gsub("\n\n+", "\n")
  if not keepEdgeSpaces then s = trim(s) end
  if limit and #s > limit then
    s = s:sub(1, limit)
    if not keepEdgeSpaces then s = s:gsub("%s+%S*$", "") .. "..." end
  end
  return s
end

-- Draft text must retain a space typed after the current word.  The final
-- request still goes through sanitizeInput, which trims and normalizes it.
function Client.sanitizeDraft(s)
  return ascii(s, 120, true):gsub("\n", " ")
end

function Client.sanitizeInput(s)
  return ascii(s, 120):gsub("\n", " ")
end

function Client.sanitizeReply(s)
  return ascii(s, 320)
end

function Client.model()
  local configured = trim(os.getenv("NVIDIA_NIM_MODEL"))
  return configured ~= "" and configured or Client.DEFAULT_MODEL
end

function Client.endpoint()
  local base = trim(os.getenv("NVIDIA_NIM_BASE_URL"))
  if base == "" then base = Client.DEFAULT_BASE_URL end
  base = base:gsub("/+$", "")
  if not base:match("/chat/completions$") then base = base .. "/chat/completions" end
  if not base:match("^https?://") then return nil, "NVIDIA_NIM_BASE_URL must use http or https" end
  return base
end

function Client.hasApiKey()
  local key = os.getenv("NVIDIA_API_KEY")
  return type(key) == "string" and key ~= ""
end

-- A normal request deletes its staged body/header immediately.  If the
-- process is killed while curl is running, remove that interrupted request
-- on the next boot before any NPC can start another one.
function Client.cleanupStagedFiles()
  if not (love and love.filesystem and love.filesystem.getDirectoryItems) then return end
  local ok, items = pcall(love.filesystem.getDirectoryItems, "")
  if not ok or type(items) ~= "table" then return end
  for _, name in ipairs(items) do
    if name:match("^http_post_nim_npc_[%w_%-]*%.headers$")
        or name:match("^http_post_nim_npc_[%w_%-]*%.json$")
        or name == "http_post_nim_live_test.headers"
        or name == "http_post_nim_live_test.json" then
      pcall(love.filesystem.remove, name)
    end
  end
end

local function contextText(ctx)
  local original = ascii(ctx.vanillaText or "No original line was available.", 240)
  return table.concat({
    "You are a non-player character in the world of the original Pokemon Blue game.",
    "Stay in character as a resident of " .. tostring(ctx.mapId or "KANTO") .. ".",
    "Your original game dialogue was: " .. original,
    "Use that original dialogue only as background context. Do not quote it, repeat it, or open your answer with it.",
    "Reply to the player naturally in one or two short sentences, at most 240 characters.",
    "Use plain ASCII except that POKEMON is allowed. Do not use markdown, stage directions, menus, or code.",
    "Do not claim you changed game state, gave an item, healed Pokemon, started a battle, or completed a quest.",
  }, " ")
end

function Client.buildRequest(ctx, userText, history)
  local messages = { { role = "system", content = contextText(ctx or {}) } }
  for _, message in ipairs(history or {}) do
    if (message.role == "user" or message.role == "assistant")
        and type(message.content) == "string" then
      messages[#messages + 1] = {
        role = message.role,
        content = message.role == "user" and Client.sanitizeInput(message.content)
          or Client.sanitizeReply(message.content),
      }
    end
  end
  messages[#messages + 1] = { role = "user", content = Client.sanitizeInput(userText) }
  return Json.encode({
    model = Client.model(),
    messages = messages,
    max_tokens = 96,
    temperature = 0.7,
    top_p = 0.9,
    stream = false,
  })
end

local function apiError(decoded)
  if type(decoded) ~= "table" then return nil end
  if type(decoded.error) == "table" then
    return decoded.error.message or decoded.error.detail or decoded.error.type
  end
  return decoded.detail or decoded.title or decoded.message
end

function Client.parseCompletion(body)
  local decoded, decodeErr = Json.decode(body or "")
  if not decoded then return nil, "NIM returned invalid JSON: " .. tostring(decodeErr) end
  local choice = decoded.choices and decoded.choices[1]
  local content = choice and choice.message and choice.message.content
  if type(content) ~= "string" or trim(content) == "" then
    return nil, tostring(apiError(decoded) or "NIM response contained no assistant message")
  end
  return Client.sanitizeReply(content)
end

-- Runs only inside the one-shot worker thread.
function Client.perform(requestBody, tag)
  local key = os.getenv("NVIDIA_API_KEY")
  if type(key) ~= "string" or key == "" then return nil, "NVIDIA_API_KEY is not set" end
  if key:find("[\r\n]") then return nil, "NVIDIA_API_KEY contains an invalid newline" end
  local endpoint, endpointErr = Client.endpoint()
  if not endpoint then return nil, endpointErr end
  return HostShell.httpPostJson(endpoint, requestBody, {
    Authorization = "Bearer " .. key,
  }, { tag = tag or "nim_npc", timeout = 60 })
end

function Client.encodeEnvelope(ok, value)
  return Json.encode(ok and { ok = true, body = value }
    or { ok = false, error = tostring(value or "unknown request error") })
end

function Client.decodeEnvelope(value)
  local decoded, err = Json.decode(value or "")
  if not decoded then return nil, "worker returned invalid JSON: " .. tostring(err) end
  if decoded.ok then return decoded.body end
  return nil, tostring(decoded.error or "NIM request failed")
end

return Client
