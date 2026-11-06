local A = "/home/claude/addon/sl65amg_rtu/lua/audio_engine/"
local now = 0
local hooks, cvs, cmds, timers = {}, {}, {}, {}
hook = { Add = function(ev, id, fn) hooks[ev] = hooks[ev] or {} hooks[ev][id] = fn end }
local function run(ev, ...) for _, fn in pairs(hooks[ev] or {}) do fn(...) end end
function CreateConVar(n, d) local c = { v = d } function c:GetBool() return tonumber(self.v) ~= 0 end function c:GetFloat() return tonumber(self.v) end function c:GetInt() return tonumber(self.v) end cvs[n] = c return c end
FCVAR_ARCHIVE, FCVAR_REPLICATED = 1, 2
concommand = { Add = function(n, f) cmds[n] = f end }
timer = { Simple = function(_, f) timers[#timers + 1] = f end }
util = { AddNetworkString = function() end }
net = { Receive = function() end }
function CurTime() return now end
function FrameTime() return 1 / 66 end
function IsValid(x) return x ~= nil and x ~= false end
function istable(x) return type(x) == "table" end
table.Copy = function(t) local o = {} for k, v in pairs(t) do o[k] = type(v) == "table" and table.Copy(v) or v end return o end
string.Trim = function(s) return s end
function math.Clamp(x, a, b) return math.min(b, math.max(a, x)) end
KEY_I, KEY_K = 19, 21
IN_FORWARD, IN_BACK, IN_JUMP = 8, 16, 2
local veh = { nw = {}, enabled = true, started = true }
function veh:IsVehicle() return true end
function veh:GetModel() return "models/plpd/sl65amg_rtu.mdl" end
function veh:GetNW2Bool(k, d) local v = self.nw[k] if v == nil then return d end return v end
veh.GetNW2Float, veh.GetNW2String, veh.GetNW2Int = veh.GetNW2Bool, veh.GetNW2Bool, veh.GetNW2Bool
function veh:SetNW2Bool(k, v) self.nw[k] = v end
veh.SetNW2Float, veh.SetNW2String, veh.SetNW2Int = veh.SetNW2Bool, veh.SetNW2Bool, veh.SetNW2Bool
function veh:GetVehicleParams() return { engine = { maxSpeed = 155 * 17.6, horsepower = 480 } } end
function veh:SetVehicleParams() end
function veh:EnableEngine(b) self.enabled = b end
function veh:StartEngine(b) self.started = b end
function veh:IsEngineEnabled() return self.enabled end
local ply = { info = { audio_engine_startkey = "i" } }
function veh:GetDriver() return ply.inside and ply or nil end
function ply:GetVehicle() return self.inside and veh or nil end
function ply:GetInfo(k) return self.info[k] end
function ply:KeyDown() return false end
ents = { GetAll = function() return { veh } end }
AUDIO_ENGINE = {}
dofile(A .. "sh_config.lua"); dofile(A .. "sh_presets.lua"); dofile(A .. "sh_drivetrain.lua"); dofile(A .. "sv_engine.lua")
local function step(sec) for i = 1, math.floor(sec * 66) do now = now + 1 / 66 run("Think") end for _, f in ipairs(timers) do f() end timers = {} end
local function show(l) print(string.format("%-34s on=%-5s drivable=%-5s EnableEngine=%s", l, tostring(veh.nw.audio_on), tostring(veh.audioDrivable), tostring(veh.enabled))) end
show("spawned")
ply.inside = true run("PlayerEnteredVehicle", ply, veh) veh.enabled = true -- Source starts it on entry
step(0.05) show("got in (Source enabled the engine)")
step(2) show("2 s later, no key")
cmds.audio_engine_toggle(ply) step(0.05) show("pressed I")
local t0 = now
while not veh.audioDrivable and now - t0 < 10 do step(0.05) end
show(string.format("drivable after %.2f s (emotion start)", now - t0))
cmds.audio_engine_toggle(ply) step(0.5) show("pressed I again")
cvs.audio_engine_emotionstart.v = "0"
cmds.audio_engine_toggle(ply) t0 = now
while not veh.audioDrivable and now - t0 < 10 do step(0.05) end
show(string.format("drivable after %.2f s (normal start)", now - t0))
ply.inside = false run("PlayerLeaveVehicle", ply, veh) step(0.1) show("got out")
cvs.audio_engine_autostart.v = "1"
ply.inside = true run("PlayerEnteredVehicle", ply, veh) step(0.05) show("got in with autostart 1")
t0 = now while not veh.audioDrivable and now - t0 < 10 do step(0.05) end
show(string.format("drivable after %.2f s", now - t0))
