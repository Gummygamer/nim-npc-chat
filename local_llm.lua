-- On-device text model for the Switch 2 port: NVIDIA Nemotron Labs Dory 1.0
-- 4B through the native ns2text bridge (llama.cpp; GPU via OunceVK, CPU
-- fallback). Elsewhere ns2text is absent and available() is false, so the
-- hosted NVIDIA NIM path is used exactly as before.
-- The same file ships in the Fakemon and NPC chat mods.
local Json = require("src.link.Json")

local LocalLlm = {}
LocalLlm.MODEL = "nemotron-labs-dory1.0-4b-q5_k_m (local)"
LocalLlm.LOOPS = 1

-- JSON-only output (llama.cpp grammars/json.gbnf, MIT, The ggml authors).
LocalLlm.JSON_GRAMMAR = [[
root   ::= object
value  ::= object | array | string | number | ("true" | "false" | "null") ws
object ::= "{" ws ( string ":" ws value ("," ws string ":" ws value)* )? "}" ws
array  ::= "[" ws ( value ("," ws value)* )? "]" ws
string ::= "\"" ( [^"\\\x7F\x00-\x1F] | "\\" (["\\bfnrt] | "u" [0-9a-fA-F]{4}) )* "\"" ws
number ::= ("-"? ([0-9] | [1-9] [0-9]{0,15})) ("." [0-9]+)? ([eE] [-+]? [0-9] [1-9]{0,15})? ws
ws ::= | " " | "\n" [ \t]{0,20}
]]

local native
local function lib()
  if native == nil then
    local ok, module = pcall(require, "ns2text")
    native = ok and type(module) == "table" and module or false
  end
  return native or nil
end

function LocalLlm.available()
  local n = lib()
  if not n then return false end
  local ok, ready = pcall(n.ready)
  return ok and ready == true
end

-- Dory's ChatML template with thinking off; template markers typed by the
-- player (NPC questions) cannot open or close turns.
function LocalLlm.prompt(messages)
  local out = {}
  for _, message in ipairs(messages or {}) do
    local role = message.role == "system" and "system" or message.role == "assistant" and "assistant" or "user"
    local content = tostring(message.content or ""):gsub("<|", "< |"):gsub("|>", "| >")
    out[#out + 1] = "<|im_start|>" .. role .. "\n" .. content .. "<|im_end|>\n"
  end
  out[#out + 1] = "<|im_start|>assistant\n<think></think>"
  return table.concat(out)
end

-- Takes the mods' chat-completions request body and returns a body of the
-- same shape the hosted API returns, so existing parsers and validators run.
function LocalLlm.complete(requestBody, options)
  options = options or {}
  local n = lib()
  if not n then return nil, "local text model unavailable" end
  local request = Json.decode(requestBody)
  if type(request) ~= "table" or type(request.messages) ~= "table" then
    return nil, "invalid local text request"
  end
  -- One Dory loop: ~3x the speed of two at similar quality in evaluation
  -- (offline/llm-evaluation.json); generation is bandwidth-bound on Switch 2.
  local device, openErr = n.open(options.loops or LocalLlm.LOOPS)
  if not device then return nil, "local text model: " .. tostring(openErr) end
  local text, err = n.generate({
    prompt = LocalLlm.prompt(request.messages),
    max_tokens = math.min(tonumber(request.max_tokens) or 256, 1400),
    temperature = tonumber(request.temperature) or 0.7,
    top_p = tonumber(request.top_p) or 0.9,
    seed = tonumber(options.seed) or 0,
    grammar = options.grammar or (options.json and LocalLlm.JSON_GRAMMAR) or nil,
  })
  if not text then return nil, "local text model: " .. tostring(err) end
  return Json.encode({ model = LocalLlm.MODEL,
    choices = { { message = { role = "assistant", content = text } } } })
end

return LocalLlm
