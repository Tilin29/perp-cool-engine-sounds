--[[
	A small stand-in for the Garry's Mod client API, so the Audio Engine addon's own Lua files
	run unchanged in the browser (Lua 5.4 in WebAssembly). Sounds go to Web Audio through
	the JS host functions __snd / __genBegin / __push / __genEnd.
]]

-- LuaJIT -> Lua 5.4 compatibility --------------------------------------------------------
local function tobit(x) x = math.tointeger(x) or math.floor(x) x = x & 0xFFFFFFFF if x >= 0x80000000 then x = x - 0x100000000 end return x end
bit = {
	tobit = tobit,
	bxor = function(a, b) return tobit(tobit(a) ~ tobit(b)) end,
	band = function(a, b) return tobit(tobit(a) & tobit(b)) end,
	bor = function(a, b) return tobit(tobit(a) | tobit(b)) end,
	lshift = function(a, n) return tobit(tobit(a) << n) end,
	rshift = function(a, n) return tobit((tobit(a) & 0xFFFFFFFF) >> n) end,
	arshift = function(a, n) return tobit(tobit(a) // (1 << n)) end,
	bnot = function(a) return tobit(~tobit(a)) end,
}
unpack = unpack or table.unpack
math.tanh = math.tanh or function(x)
	if x > 20 then return 1 elseif x < -20 then return -1 end
	local e = math.exp(2 * x) return (e - 1) / (e + 1)
end
math.pow = math.pow or function(a, b) return a ^ b end
math.log10 = math.log10 or function(x) return math.log(x, 10) end
function math.Clamp(x, a, b) if x < a then return a elseif x > b then return b end return x end

-- time / logging ---------------------------------------------------------------------------
SIM = { t = 0, dt = 1 / 60 }
function SysTime() return __now() / 1000 end
function RealTime() return SIM.t end
function CurTime() return SIM.t end
function FrameTime() return SIM.dt end
function RealFrameTime() return SIM.dt end
local function out(...)
	local t = {}
	for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end
	__log(table.concat(t, "\t"))
end
MsgN = out
Msg = out
print = out
function ErrorNoHalt(m) __log("ERROR " .. tostring(m)) end

-- convars / commands / hooks ---------------------------------------------------------------
CV = {}
local cvMeta = {}
cvMeta.__index = cvMeta
function cvMeta:GetFloat() return tonumber(self.v) or 0 end
function cvMeta:GetInt() return math.floor(tonumber(self.v) or 0) end
function cvMeta:GetBool() return (tonumber(self.v) or 0) ~= 0 end
function cvMeta:GetString() return tostring(self.v) end
function CreateClientConVar(name, def) local c = CV[name] or setmetatable({ v = def }, cvMeta) CV[name] = c return c end
CreateConVar = CreateClientConVar
function GetConVar(name) return CV[name] end
local cvCallbacks = {}
cvars = { AddChangeCallback = function(name, fn, id) cvCallbacks[name] = cvCallbacks[name] or {} cvCallbacks[name][id or fn] = fn end }
function SetCV(name, v)
	local c = CreateClientConVar(name, v)
	local old = tostring(c.v)
	c.v = v
	for _, fn in pairs(cvCallbacks[name] or {}) do fn(name, old, tostring(v)) end
end
function RunConsoleCommand(name, v) SetCV(name, v) end
concommand = { cmds = {}, Add = function(name, fn) concommand.cmds[name] = fn end }
local hooks = {}
hook = {
	Add = function(ev, id, fn) hooks[ev] = hooks[ev] or {} hooks[ev][id] = fn end,
	Remove = function(ev, id) if hooks[ev] then hooks[ev][id] = nil end end,
	Run = function(ev, ...) for _, fn in pairs(hooks[ev] or {}) do fn(...) end end,
}
timer = { Simple = function(_, fn) fn() end }

-- vectors ----------------------------------------------------------------------------------
local V = {}
V.__index = V
function Vector(x, y, z)
	if type(x) == "table" then return setmetatable({ x = x.x, y = x.y, z = x.z }, V) end
	return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, V)
end
V.__add = function(a, b) return Vector(a.x + b.x, a.y + b.y, a.z + b.z) end
V.__sub = function(a, b) return Vector(a.x - b.x, a.y - b.y, a.z - b.z) end
V.__mul = function(a, k) if type(a) == "number" then a, k = k, a end return Vector(a.x * k, a.y * k, a.z * k) end
V.__div = function(a, k) return Vector(a.x / k, a.y / k, a.z / k) end
V.__unm = function(a) return Vector(-a.x, -a.y, -a.z) end
function V:Dot(b) return self.x * b.x + self.y * b.y + self.z * b.z end
function V:Length() return math.sqrt(self:Dot(self)) end
function V:Normalize() local l = self:Length() if l > 0 then self.x, self.y, self.z = self.x / l, self.y / l, self.z / l end end
function V:Mul(k) self.x, self.y, self.z = self.x * k, self.y * k, self.z * k end
function V:Rotate(a)
	local yaw = math.rad(a.y)
	local c, s = math.cos(yaw), math.sin(yaw)
	self.x, self.y = self.x * c - self.y * s, self.x * s + self.y * c
end
function V:DistToSqr(b) local d = self - b return d:Dot(d) end

-- the car and the player ---------------------------------------------------------------------
CAR = { pos = Vector(0, 0, 0), yaw = 0, nw = {}, pose = {} }
function CAR:GetModel() return "models/plpd/sl65amg_rtu.mdl" end
function CAR:GetPos() return Vector(self.pos) end
function CAR:GetAngles() return { p = 0, y = self.yaw, r = 0 } end
function CAR:GetUp() return Vector(0, 0, 1) end
function CAR:IsValid() return true end
function CAR:IsDormant() return false end
function CAR:SetPoseParameter(k, v) self.pose[k] = v end
function CAR:LookupAttachment() return 0 end
local function nw(self, k, d) local v = self.nw[k] if v == nil then return d end return v end
CAR.GetNW2Bool, CAR.GetNW2Float, CAR.GetNW2Int, CAR.GetNW2String = nw, nw, nw, nw
ents = { FindByClass = function() return { CAR } end }
IN_FORWARD, IN_BACK, IN_JUMP = 8, 16, 2
PLY = { keys = {}, inCar = true, eye = Vector(0, 0, 64) }
function LocalPlayer() return PLY end
function PLY:GetVehicle() return self.inCar and CAR or nil end
function PLY:KeyDown(k) return self.keys[k] or false end
function PLY:EyePos() return Vector(self.eye) end
function PLY:IsAdmin() return true end
function GetViewEntity() return PLY end
function IsValid(x) return x ~= nil and x ~= false end
function PLY:IsTyping() return false end
util = { TraceLine = function() return { Hit = false, Fraction = 1 } end }
input = { IsKeyDown = function() return false end }
cookie = { GetNumber = function(_, d) return d end, Set = function() end }
gui = { IsGameUIVisible = function() return false end }
vgui = { GetKeyboardFocus = function() return nil end }

-- sound -------------------------------------------------------------------------------------
-- sound.Generate calls fn(t) for every sample, like the game; the buffer is handed to JS
sound = {
	Generate = function(name, rate, dur, fn, loopStart)
		local n = math.floor(rate * dur + 0.5)
		__genBegin(name, rate, loopStart or -1, n)
		local chunk, k = {}, 0
		for t = 0, n - 1 do
			k = k + 1
			chunk[k] = fn(t)
			if k == 200 then __push(table.unpack(chunk, 1, k)) k = 0 end
		end
		if k > 0 then __push(table.unpack(chunk, 1, k)) end
		__genEnd(name)
	end,
}
local P = {}
P.__index = P
local nextPatch = 0
function CreateSound(ent, name)
	nextPatch = nextPatch + 1
	local p = setmetatable({ id = nextPatch, name = name }, P)
	__snd("create", p.id, name)
	return p
end
function P:SetSoundLevel(l) __snd("level", self.id, l) end
function P:SetDSP(d) __snd("dsp", self.id, d) end
function P:IsPlaying() return true end
function P:PlayEx(v, pitch) __snd("play", self.id, v, pitch) end
function P:Play() __snd("play", self.id, 1, 100) end
function P:ChangeVolume(v, dt) __snd("vol", self.id, v, dt or 0) end
function P:ChangePitch(p, dt) __snd("pitch", self.id, p, dt or 0) end
function P:Stop() __snd("stop", self.id) end
function P:FadeOut(t) __snd("fade", self.id, t) end
