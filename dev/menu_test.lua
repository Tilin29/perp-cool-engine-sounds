local A = "/home/claude/addon/sl65amg_rtu/lua/audio_engine/"
local created, callbacks = {}, {}
local function proxy(kind)
  local p = { __kind = kind }
  return setmetatable(p, {
    __index = function(t, k)
      if type(k) == "string" and (k:sub(1,3) == "Get") then return function() return 100 end end
      if type(k) == "string" and (k:sub(1,2) == "Is") then return function() return false end end
      local child = proxy(kind .. "." .. tostring(k))
      rawset(t, k, child)
      return child
    end,
    __call = function(self, ...) return proxy(kind .. "()") end,
  })
end
vgui = { Create = function(kind, parent) local p = proxy(kind); created[#created+1] = p; return p end }
surface = { CreateFont = function() end, PlaySound = function() end, SetFont = function() end, GetTextSize = function() return 10, 10 end }
draw = { RoundedBox = function() end, SimpleText = function() end }
function ScrH() return 1080 end
function Color(r,g,b,a) return {r=r,g=g,b=b,a=a} end
TOP, LEFT, RIGHT, BOTTOM, FILL = 1, 2, 3, 4, 5
local timers = {}
timer = { Simple = function(_, f) timers[#timers+1] = f end }
chat = { AddText = function(...) print("chat", ...) end }
local sent = {}
net = { Start = function() end, WriteEntity = function() end, WriteString = function(s) sent[#sent+1] = s end, SendToServer = function() end }
cvars = { AddChangeCallback = function() end }
RunConsoleCommand = function(...) print("RunConsoleCommand", ...) end
concommand = { Add = function() end }
properties = { Add = function() end }
function GetConVar() return { GetInt = function() return 1 end } end
function IsValid(x) return x ~= nil end
function math.Clamp(x,a,b) return math.min(b, math.max(a, x)) end
PerpAudioEngine = {}
dofile(A.."sh_config.lua"); dofile(A.."sh_presets.lua")
local veh = { nw = {} }
function veh:GetModel() return "models/plpd/sl65amg_rtu.mdl" end
function veh:GetNW2String(k, d) return self.nw[k] or d end
function veh:GetNW2Float(k, d) return self.nw[k] or d end
veh.nw.audio_vmax = 321.9
local ply = {}
function ply:GetVehicle() return veh end
function ply:IsAdmin() return true end
function ply:IsSuperAdmin() return true end
function LocalPlayer() return ply end
dofile(A.."cl_menu.lua")
PerpAudioEngine.OpenMenu()
print("panels created on open:", #created)
-- run deferred rebuilds and poke the callbacks the menu wired up
local snap = {} for i, p in ipairs(created) do snap[i] = p end
for _, p in ipairs(snap) do
  for _, name in ipairs({"OnSelect","OnChange","OnValueChange","OnValueChanged","DoClick","TranslateValues"}) do
    local f = rawget(p, name)
    if type(f) == "function" then
      local ok, err
      if name == "OnSelect" then ok, err = pcall(f, p, 1, "x", "v8x")
      elseif name == "TranslateValues" then ok, err = pcall(f, p, 0.7, 0.5)
      elseif name == "OnChange" then ok, err = pcall(f, p, true)
      elseif name == "OnValueChange" or name == "OnValueChanged" then ok, err = pcall(f, p, "6")
      else ok, err = pcall(f, p) end
      if not ok then print("ERROR in", p.__kind, name, err) end
      callbacks[name] = (callbacks[name] or 0) + 1
    end
  end
end
for i = 1, 5 do local t = timers; timers = {}; for _, f in ipairs(t) do local ok, e = pcall(f) if not ok then print("timer error", e) end end end
for k, v in pairs(callbacks) do print("callback", k, v) end
print("sent to server:", #sent)
for _, s in ipairs(sent) do print("  ", s, s ~= "" and (PerpAudioEngine.DecodeProfile(s) and "decodes ok" or "DECODE FAIL") or "(stock)") end
