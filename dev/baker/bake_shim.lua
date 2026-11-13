--[[
	Just enough of the Garry's Mod API to run the addon's shared files, the synth and the
	sound bank under Lua 5.4 (wasmoon), so bake.js can render every stock engine to WAV files.
	sound.Generate hands each finished sound to JS (__genBegin / __push / __genEnd).
]]

-- LuaJIT -> Lua 5.4 ------------------------------------------------------------------------
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
function string.Trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

CLIENT, SERVER = true, false

-- time / logging -----------------------------------------------------------------------------
function SysTime() return __now() / 1000 end
function RealTime() return 0 end
function CurTime() return 0 end
function FrameTime() return 1 / 60 end
local function out(...)
	local t = {}
	for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end
	__log(table.concat(t, "\t"))
end
MsgN, Msg, print = out, out, out
function ErrorNoHalt(m) error(m, 2) end

-- convars / hooks ------------------------------------------------------------------------------
CV = {}
local cvMeta = {}
cvMeta.__index = cvMeta
function cvMeta:GetFloat() return tonumber(self.v) or 0 end
function cvMeta:GetInt() return math.floor(tonumber(self.v) or 0) end
function cvMeta:GetBool() return (tonumber(self.v) or 0) ~= 0 end
function cvMeta:GetString() return tostring(self.v) end
function CreateClientConVar(name, def) local c = CV[name] or setmetatable({ v = def }, cvMeta) CV[name] = c return c end
CreateConVar = CreateClientConVar
FCVAR_NONE, FCVAR_ARCHIVE, FCVAR_REPLICATED = 0, 128, 8192
function GetConVar(name) return CV[name] end
cvars = { AddChangeCallback = function() end }
concommand = { Add = function() end }
hook = { Add = function() end, Remove = function() end }
timer = { Simple = function() end }
list = { Set = function() end }
function IsValid(x) return x ~= nil and x ~= false end
function LocalPlayer() return nil end
function AddCSLuaFile() end
-- the baker must render, never load the files it is about to write
file = { Exists = function() return false end, Read = function() return nil end }
util = { PrecacheSound = function() end }

-- sound.Generate: every sample goes to JS, which writes the WAV
sound = {
	Generate = function(name, rate, dur, fn, loopStart)
		local n = math.floor(rate * dur + 0.5)
		__genBegin(name, rate, loopStart or -1, n)
		local chunk, k = {}, 0
		for t = 0, n - 1 do
			k = k + 1
			chunk[k] = fn(t)
			if k == 400 then __push(table.unpack(chunk, 1, k)) k = 0 end
		end
		if k > 0 then __push(table.unpack(chunk, 1, k)) end
		__genEnd(name)
	end,
	Add = function() end,
}
