-- Minimal GMod stubs to run the client code: build the sound bank, drive a car, mix the patches.
package.path = "/home/claude/tools/?.lua;" .. package.path
local W = require("wav")
local A = "/home/claude/addon/sl65amg_rtu/lua/"
local SR = 44100
local FPS = 60
local now = 0
local hooks = {}
hook = { Add = function(ev, id, fn) hooks[ev] = hooks[ev] or {}; hooks[ev][id] = fn end }
local function run(ev, ...) for _, fn in pairs(hooks[ev] or {}) do fn(...) end end
local cv = {}
function CreateClientConVar(name, def) local c = { v = def }
  function c:GetFloat() return tonumber(self.v) end function c:GetInt() return math.floor(tonumber(self.v)) end
  function c:GetBool() return tonumber(self.v) ~= 0 end function c:GetString() return self.v end
  cv[name] = c return c end
cvars = { AddChangeCallback = function() end }
RunConsoleCommand = function(...) print("RunConsoleCommand", ...) end
concommand = { Add = function() end }
function SysTime() return os.clock() end
function RealTime() return now end
function CurTime() return now end
function FrameTime() return 1 / FPS end
function MsgN(...) print(...) end
function ErrorNoHalt(m) error(m) end
function IsValid(x) return x ~= nil and x ~= false and (type(x) ~= "table" or not x.removed) end
function math.Clamp(x, a, b) return math.min(b, math.max(a, x)) end
IN_FORWARD, IN_BACK, IN_JUMP = 8, 16, 2
-- Vector
local V = {} V.__index = V
function Vector(x, y, z) if type(x) == "table" then return setmetatable({ x = x.x, y = x.y, z = x.z }, V) end return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, V) end
V.__sub = function(a, b) return Vector(a.x - b.x, a.y - b.y, a.z - b.z) end
V.__add = function(a, b) return Vector(a.x + b.x, a.y + b.y, a.z + b.z) end
function V:Dot(b) return self.x * b.x + self.y * b.y + self.z * b.z end
function V:Length() return math.sqrt(self:Dot(self)) end
function V:Normalize() local l = self:Length() self.x, self.y, self.z = self.x / l, self.y / l, self.z / l end
function V:Rotate(ang) local yaw = math.rad(ang.y) local c, s = math.cos(yaw), math.sin(yaw)
  self.x, self.y = self.x * c - self.y * s, self.x * s + self.y * c end
V.__div = function(a, k) return Vector(a.x / k, a.y / k, a.z / k) end
V.__mul = function(a, k) if type(a) == "number" then a, k = k, a end return Vector(a.x * k, a.y * k, a.z * k) end
V.__unm = function(a) return Vector(-a.x, -a.y, -a.z) end
function V:Mul(k) self.x, self.y, self.z = self.x * k, self.y * k, self.z * k end
function GetViewEntity() return LocalPlayer() end
-- sounds
local generated = {}
sound = { Generate = function(name, rate, dur, fn, loopStart)
  local n = math.floor(rate * dur + 0.5) local b = {}
  for t = 0, n - 1 do local v = fn(t) assert(v >= -1 and v <= 1 and v == v, "bad sample") b[t + 1] = v end
  generated[name] = { buf = b, loop = loopStart } end }
local patches = {}
function CreateSound(ent, name)
  assert(generated[name], "unknown sound " .. tostring(name))
  local p = { name = name, playing = false, vol = 0, pitch = 100, pos = 0 }
  function p:SetSoundLevel() end
  function p:PlayEx(v, pi) self.playing = true self.vol = math.min(1, v) self.pitch = pi self.pos = 0
    local kind = name:match("_(%a+)%d*$") or "?"
    PLAYS = PLAYS or {} PLAYS[kind] = (PLAYS[kind] or 0) + 1 end
  function p:ChangeVolume(v) self.vol = math.min(1, v) end
  function p:ChangePitch(pi) self.pitch = pi end
  function p:Stop() self.playing = false end
  function p:SetDSP() end
  function p:IsPlaying() return self.playing end
  function p:FadeOut(t) self.fade = self.vol / (t * SR) end
  patches[#patches + 1] = p
  return p
end
local function mix(n, out)
  for _, p in ipairs(patches) do if p.playing then
    local g = generated[p.name] local b, N = g.buf, #g.buf
    for i = 1, n do
      local i0 = math.floor(p.pos) local fr = p.pos - i0
      local s = (b[i0 + 1] or 0) * (1 - fr) + (b[i0 + 2] or b[(g.loop or 0) + 1] or 0) * fr
      out[#out - n + i] = out[#out - n + i] + s * p.vol
      if p.fade then p.vol = math.max(0, p.vol - p.fade) end
      p.pos = p.pos + p.pitch / 100
      if p.pos >= N - 1 then if g.loop then p.pos = p.pos - (N - 1 - g.loop) else p.playing = false break end end
    end end end
end
-- the car
local car = { pos = Vector(0, 0, 0), yaw = 0, nw = {}, removed = false }
function car:GetModel() return "models/plpd/sl65amg_rtu.mdl" end
function car:GetPos() return Vector(self.pos) end
function car:GetAngles() return { p = 0, y = self.yaw, r = 0 } end
function car:GetUp() return Vector(0, 0, 1) end
function car:IsDormant() return false end
function car:SetPoseParameter() end
function car:LookupAttachment() return 0 end
function car:GetNW2Bool(k, d) local v = self.nw[k] if v == nil then return d end return v end
car.GetNW2Float, car.GetNW2Int, car.GetNW2String = car.GetNW2Bool, car.GetNW2Bool, car.GetNW2Bool
ents = { FindByClass = function() return { car } end }
local ply = { keys = {} }
function ply:EyePos() return Vector(0, 0, 64) end
function LocalPlayer() return ply end
function ply:GetVehicle() return car end
function ply:KeyDown(k) return self.keys[k] or false end
bit = require("bit")

AUDIO_ENGINE = {}
dofile(A .. "audio_engine/sh_config.lua"); dofile(A .. "audio_engine/sh_presets.lua"); dofile(A .. "audio_engine/sh_drivetrain.lua")
dofile(A .. "audio_engine/cl_synth.lua"); dofile(A .. "audio_engine/cl_soundbank.lua")
util = util or {}; util.TraceLine = function() return { Hit = false, Fraction = 1 } end
input = { IsKeyDown = function() return false end }
cookie = { GetNumber = function(_, d) return d end, Set = function() end }
dofile(A .. "audio_engine/cl_engine.lua")

local E = AUDIO_ENGINE
local SRr = tonumber(os.getenv("SR") or "22050")
cv["audio_engine_samplerate"].v = tostring(SRr)
local function rms(buf, a, b) local s = 0 for i = a, b do s = s + buf[i] * buf[i] end return math.sqrt(s / (b - a + 1)) end
local function hpl(buf)
  local f = E.Synth.Biquad("highpass", 250, SRr, 0.7)
  local b0, b1, b2, a1, a2, z1, z2 = f[1], f[2], f[3], f[4], f[5], 0, 0
  local s = 0
  for i = 1, #buf do local x = buf[i] local y = b0 * x + z1 z1 = b1 * x - a1 * y + z2 z2 = b2 * x - a2 * y s = s + y * y end
  return 20 * math.log10(math.sqrt(s / #buf))
end
local function pk(buf) local m = 0 for i = 1, #buf do m = math.max(m, math.abs(buf[i])) end return m end
local ids = {}
for w in (os.getenv("PRESETS") or ""):gmatch("[^,]+") do ids[#ids + 1] = w end
if #ids == 0 then for _, p in ipairs(E.ENGINE_PRESETS) do ids[#ids + 1] = p.id end end
local car = E.Cars["models/plpd/sl65amg_rtu.mdl"]
for _, id in ipairs(ids) do
  local cfg = E.ResolveProfile(car, E.ProfileFromPreset(id))
  local b = E.Bank.Build(cfg)
  while b.buildCoroutine do run("Think") end
  local n = #b.layers
  local function L(i, k) return generated[b.layers[i][k]].buf end
  local mid = math.max(1, math.floor(n * 0.6))
  local onMid, onTop, offMid = L(mid, "on"), L(n, "on"), L(mid, "off")
  local gpk = 0 for i = 1, n do gpk = math.max(gpk, pk(L(i, "on")), pk(L(i, "off"))) end
  local hsum = 0 for i = 2, n do hsum = hsum + hpl(L(i, "on")) end
  local extra = ""
  local tb = os.clock()
  extra = string.format(" | limited %.1f dB | built %.1fs", b.limitedDb or 0, b.buildTime or 0)
  if false then
    local t = generated[b.turbo.loop].buf
    local bo = generated[b.turbo.blowoff[1]].buf
    local head = {} for i = 1, math.floor(SRr * 0.15) do head[i] = bo[i] end
    extra = string.format(" | turbo rms@default %.4f  bov head rms@default %.4f", rms(t, 2, #t) * 0.5, rms(head, 1, #head) * 0.5)
  end
  print(string.format("%-8s HPloud(on, mean of bands) %6.1f dB%s", id, hsum / (n - 1), extra))
  print(string.format("%-8s %-8s on@mid %6.1f dB  on@top %6.1f dB  off@mid %6.1f dB  idle-off %6.1f dB  loops peak %.2f  lim pk %.2f",
    id, cfg.layout, 20 * math.log10(rms(onMid, 2, #onMid)), 20 * math.log10(rms(onTop, 2, #onTop)), 20 * math.log10(rms(offMid, 2, #offMid)),
    20 * math.log10(rms(L(1, "off"), 2, #L(1, "off"))), gpk, pk(generated[b.limiter.off].buf)))
end
