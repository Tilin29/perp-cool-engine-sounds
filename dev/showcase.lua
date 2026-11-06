-- Minimal GMod stubs to run the client code: build the sound bank, drive a car, mix the patches.
package.path = "/home/claude/tools/?.lua;" .. package.path
local W = require("wav")
local A = "/home/claude/addon/sl65amg_rtu/lua/"
local SR = 44100
RAMP = os.getenv("RAMP") == "1"
VLOG = io.open("/home/claude/tools/out/vlog.txt", "w")
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
    local kind = "x"
    PLAYS = PLAYS or {} PLAYS[kind] = (PLAYS[kind] or 0) + 1 end
  function p:ChangeVolume(v) v = math.min(1, v) local d = math.abs(v - self.vol) if d > 0.004 and VLOG then VLOG:write(string.format("%.3f %s %.4f %.4f\n", now, name:match("_([%w]+)$") or name, self.vol, v)) end self.vol = v end
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
      local vv = p.vol
      if RAMP and p.lastVol then vv = p.lastVol + (p.vol - p.lastVol) * (i / n) end
      out[#out - n + i] = out[#out - n + i] + s * vv
      if p.fade then p.vol = math.max(0, p.vol - p.fade) end
      p.pos = p.pos + p.pitch / 100
      if p.pos >= N - 1 then if g.loop then p.pos = p.pos - (N - 1 - g.loop) else p.playing = false break end end
    end p.lastVol = p.vol end end
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
run("InitPostEntity")
local t0 = os.clock()
local stockKey = AUDIO_ENGINE.ResolveProfile(AUDIO_ENGINE.Cars["models/plpd/sl65amg_rtu.mdl"]).id
for i = 1, 100000 do run("Think") if AUDIO_ENGINE.Bank.list[stockKey].ready then break end end
print("bank ready", stockKey, "cpu", os.clock() - t0)
local sdump = 0 for k, v in pairs(generated) do sdump = sdump + #v.buf end print("generated samples", sdump)

-- drive script: simple longitudinal physics standing in for Source (m/s)
local v = 0
local out = {}
local log = io.open("/home/claude/tools/out/drive_log3.csv", "w") log:write("t,v_kmh,rpm,gear,thr,soundThr,phase\n")
local function keys(f, b, h) ply.keys[IN_FORWARD] = f ply.keys[IN_BACK] = b ply.keys[IN_JUMP] = h end
do local pp = AUDIO_ENGINE.ProfileFromPreset(os.getenv("PRESET") or "sl65") if os.getenv("POPS") then pp.pops = 1 pp.popVol = 2 end car.nw.audio_prof = AUDIO_ENGINE.EncodeProfile(pp) end
for i = 1, 100000 do run("Think") local c = AUDIO_ENGINE.ClientCars[car] if c and c.bank and c.bank.ready and c.bank.key == AUDIO_ENGINE.GetEngineConfig(car).id then break end end
local script = {
  { 0, function() keys(false, false, true) car.nw.audio_on = true car.nw.audio_on_t = now - 10 end },
  { 1.5, function() keys(true, false, true) end },  { 1.8, function() keys(false, false, true) end },   -- blip
  { 2.6, function() keys(true, false, true) end },  { 3.0, function() keys(false, false, true) end },   -- blip
  { 4.0, function() keys(true, false, true) end },                                                     -- rev to the limiter
  { 5.6, function() keys(false, false, true) end },
  { 7.6, nil },
}
local si = 1
local dt = 1 / FPS
while true do
  if now >= script[si][1] then if not script[si][2] then break end script[si][2]() si = si + 1 end
  -- crude car: traction-limited acceleration, drag, braking
  local thrust = (ply.keys[IN_FORWARD] and not ply.keys[IN_JUMP]) and math.min(7.5, 600000 / (1950 * math.max(v, 5) * 3.6)) or 0
  local brake = ply.keys[IN_BACK] and v > 0 and 9 or 0
  v = math.max(0, v + (thrust - 0.00025 * v * v - 0.12 - brake) * dt)
  if v > 69.4 then v = 69.4 end
  car.pos.y = car.pos.y + v / 0.0254 * dt
  now = now + dt
  run("Think")
  local c = AUDIO_ENGINE.ClientCars[car]
  local st = c.st
  log:write(string.format("%.3f,%.1f,%.0f,%d,%.2f,%.2f,%s\n", now, c.v * 3.6, st.rpm, st.gear, st.thr, st.soundThr, st.phase))
  local n = SR / FPS
  for i = 1, n do out[#out + 1] = 0 end
  mix(n, out)
  if now > 5.50 and now < 5.56 then local t = {} for _, p in ipairs(patches) do if p.playing then t[#t+1] = string.format('%s=%.2f', p.name:match('_([%w]+)$'), p.vol) end end print('PEAKDBG', string.format('%.3f', now), table.concat(t, ' ')) end
end
log:close()
local pk = 0 for i = 1, #out do pk = math.max(pk, math.abs(out[i])) end
local nclip, tpk = 0, 0 for i = 1, #out do if math.abs(out[i]) > 1 then nclip = nclip + 1 end if math.abs(out[i]) == pk then tpk = i / SR end end
print(string.format("MIXPEAK %s peak %.2f at %.2fs  clipped samples %d", os.getenv("PRESET") or "sl65", pk, tpk, nclip))
W.write("/home/claude/tools/out/show_" .. (os.getenv("PRESET") or "sl65") .. (RAMP and "_ramp" or "") .. ".wav", out, SR, 0.5)
local np = 0 for _, p in ipairs(patches) do if p.playing then np = np + 1 end end
print("patches created", #patches, "still playing", np)
for k, v in pairs(PLAYS or {}) do print("played", k, v) end
