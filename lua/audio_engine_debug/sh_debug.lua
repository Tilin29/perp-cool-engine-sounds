--[[
	Audio Engine debug module (shared)

	Tuning tools on top of the core addon, for testing on a dev server. Loaded by
	autorun/audio_engine_init.lua whenever this folder is there; to ship the addon without them,
	delete lua/audio_engine_debug/. On by default (audio_engine_debug 1; 0 switches them off), and
	only superadmins (or the host of a listen / single-player game) may use them.

	What it changes live goes through the core's own data paths, so a result can be pasted back:
	  gearing         NW2 audio_dbg_gear on the car  -> sh_carlist.lua E.CAR_GEARING (E.ApplyGearing)
	  rev response    NW2 audio_dbg_rev on the car, or Global2 audio_dbg_rev for every car
	                                                 -> E.CAR_REV / sh_drivetrain.lua DT.REV
	  handling script the car's params (server)      -> the vehicle script txt (copied out)
	  assists/tables  server convars and E.TRACTION / E.ANTI_SPIN / E.STABILITY_DEFAULTS values
]]

local E = AUDIO_ENGINE
local DBG = E.Debug or {}
E.Debug = DBG

DBG.cvDebug = CreateConVar("audio_engine_debug", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED,
	"1 = the Audio Engine debug tools (audio_engine_debug_menu, !enginedebug) for superadmins (default); 0 = off")

function DBG.Enabled() return DBG.cvDebug:GetBool() end

function DBG.Allowed(ply)
	if not DBG.Enabled() or not IsValid(ply) then return false end
	return ply:IsSuperAdmin() or game.SinglePlayer() or (ply.IsListenServerHost and ply:IsListenServerHost())
end

---------------------------------------------------------------------------
-- server convars the debug menu shows as controls (the client asks the server to set them)
---------------------------------------------------------------------------
DBG.SERVER_CVARS = {
	{ "audio_engine_editor", "bool", "Engine editor (Rev Bench menu, !engine)" },
	{ "audio_engine_handling", "bool", "Anti-spin setup (brake bias, power cut cap, lower centre, lock at speed)" },
	{ "audio_engine_traction", "bool", "Traction control (launch slip + slide power cut)" },
	{ "audio_engine_stability", "bool", "Stability control (yaw, slip limit, straight-line hold, grip)" },
	{ "audio_engine_cruise", "bool", "Speed limiter (middle mouse)" },
	{ "audio_engine_autostart", "bool", "Engine starts by itself on entering" },
	{ "audio_engine_keeprunning", "bool", "Engine keeps idling after getting out" },
	{ "audio_engine_emotionstart", "bool", "Rev flare on start-up (CAR_EMOTION cars)" },
	{ "audio_engine_mutestock", "bool", "Mute the TDM engine recordings" },
	{ "audio_engine_muteskid", "bool", "Mute the TDM brake screech" },
	{ "audio_engine_mutetyrescrape", "bool", "Mute the sliding tyre scrape" },
	{ "audio_engine_tuneaccess", "int", "Who may use the engine editor (0 driver, 1 admins, 2 superadmins)", 0, 2 },
	{ "audio_engine_tunecooldown", "float", "Seconds between engine editor changes", 0, 30 },
}
DBG.SERVER_CVAR_SET = {}
for _, c in ipairs(DBG.SERVER_CVARS) do DBG.SERVER_CVAR_SET[c[1]] = c end

-- the convars that are the addon's handling changes: all 0 = PERP's own handling
DBG.HANDLING_CVARS = { "audio_engine_handling", "audio_engine_traction", "audio_engine_stability" }

--[[
	Server tables tuned live: { table in E, key, min, max, decimals, label }. They reset to the
	file's values on a map change / restart: copy the changed lines out with the menu's button.
]]
DBG.TUNABLES = {
	{ "TRACTION", "slideFloor", 0, 1, 2, "Slide: least power left while sliding" },
	{ "TRACTION", "slideCut", 0, 10, 1, "Slide: how fast the power goes (per s)" },
	{ "TRACTION", "slideMaxTime", 0, 5, 1, "Slide: longest power cut (s)" },
	{ "TRACTION", "slideTurnFloor", 0, 1, 2, "Slide: least power in a corner (not spinning)" },
	{ "STABILITY_DEFAULTS", "slideFrom", 0, 30, 0, "Slide counts from (degrees tail out)" },
	{ "STABILITY_DEFAULTS", "holdGrace", 0, 3, 1, "Straight-line hold: longest settle out of a turn (s)" },
	{ "STABILITY_DEFAULTS", "holdSettled", 0, 10, 1, "Straight-line hold: settled under (deg/s)" },
	{ "TRACTION", "floor", 0, 1, 2, "Launch: least power at a standstill" },
	{ "TRACTION", "floorFast", 0, 1, 2, "Launch: least power from ~36 mph" },
	{ "TRACTION", "slip", 0.05, 1, 2, "Wheel slip that counts as spinning" },
	{ "STABILITY_DEFAULTS", "straightHold", 0, 10, 1, "Straight-line hold: turn back per degree off" },
	{ "STABILITY_DEFAULTS", "straightDamp", 0, 40, 0, "Straight-line hold: how firmly" },
	{ "STABILITY_DEFAULTS", "gripAssist", 0, 3, 2, "Extra side grip (g)" },
	{ "STABILITY_DEFAULTS", "slipMax", 1, 20, 0, "Slip limit (degrees tail out)" },
	{ "STABILITY_DEFAULTS", "turnShare", 0, 1, 2, "Turn-in help share" },
	{ "ANTI_SPIN", "throttleReduceFast", 0, 1, 2, "Most power cut while steering at speed" },
	{ "ANTI_SPIN", "steerFast", 1, 2.5, 2, "Steering lock at speed x" },
	{ "ANTI_SPIN", "frontBrake", 0.4, 0.8, 2, "Least front brake share" },
	{ "HIGH_SPEED_STEER", "scale", 0.5, 1.2, 2, "Lock tightens to x this by 90 mph" },
	{ "STEER_GRIP", "g", 0.5, 4, 2, "Lock cap: turn it allows (g)" },
	{ "STEER_GRIP", "slip", 0, 20, 1, "Lock cap: tyre slip angle on top (deg)" },
}

---------------------------------------------------------------------------
-- gearing by shift speeds (sh_presets.lua E.ApplyGearing), as text for the network
-- "topRpm;mph,rpm,down;mph,rpm,down;...;,,down"
---------------------------------------------------------------------------
local function num(x, lo, hi, dec)
	x = tonumber(x)
	if not x then return nil end
	x = math.Clamp(x, lo, hi)
	local m = 10 ^ (dec or 0)
	return math.floor(x * m + 0.5) / m
end

function DBG.SanitizeGearing(spec)
	if type(spec) ~= "table" then return nil end
	local n = math.min(8, #spec)
	if n < 1 then return nil end
	local o = { topRpm = num(spec.topRpm, 500, 20000, 0) }
	for i = 1, n do
		local g = type(spec[i]) == "table" and spec[i] or {}
		local d = num(g.down, 0, 300, 1)
		o[i] = {
			mph = i < n and (num(g.mph, 1, 300, 1) or 10) or nil,
			rpm = i < n and (num(g.rpm, 500, 20000, 0) or 5000) or nil,
			down = (i > 1 and d and d > 0) and d or nil,
		}
	end
	return o
end

function DBG.EncodeGearing(spec)
	spec = DBG.SanitizeGearing(spec)
	if not spec then return "" end
	local parts = { spec.topRpm and tostring(spec.topRpm) or "" }
	for i, g in ipairs(spec) do
		parts[i + 1] = (g.mph and tostring(g.mph) or "") .. "," .. (g.rpm and tostring(g.rpm) or "") .. "," .. (g.down and tostring(g.down) or "")
	end
	return table.concat(parts, ";")
end

function DBG.DecodeGearing(s)
	if type(s) ~= "string" or s == "" or #s > 400 then return nil end
	local parts = string.Explode(";", s)
	local spec = { topRpm = tonumber(parts[1]) }
	for i = 2, #parts do
		local f = string.Explode(",", parts[i])
		spec[i - 1] = { mph = tonumber(f[1]), rpm = tonumber(f[2]), down = tonumber(f[3]) }
	end
	return DBG.SanitizeGearing(spec)
end

-- the gearing a resolved config drives with, as shift speeds (what the editor starts from)
function DBG.GearingFromConfig(cfg)
	local DT = E.Drivetrain
	local SH = cfg.shift and DT.ShiftPoints(cfg.shift) or DT.SHIFT
	local K = 60 / (2 * math.pi * cfg.wheelRadius)
	local plan = cfg.shiftPlan
	local n = #cfg.gears
	local spec = {}
	for i = 1, n do
		local ratio = cfg.gears[i] * cfg.final
		local g = {}
		if i < n then
			g.rpm = math.floor((plan and plan.up[i] or cfg.redline * SH.upRpm) + 0.5)
			g.mph = math.floor(g.rpm / (K * ratio) / 0.44704 * 10 + 0.5) / 10
		end
		if plan and plan.down[i] then g.down = math.floor(plan.down[i] / 0.44704 * 10 + 0.5) / 10 end
		spec[i] = g
	end
	spec.topRpm = math.floor(cfg.topSpeed / 3.6 * K * cfg.gears[n] * cfg.final + 0.5)
	return spec
end

-- as an entry for sh_carlist.lua E.CAR_GEARING
function DBG.GearingLua(name, spec)
	local parts = {}
	for i, g in ipairs(spec) do
		local f = {}
		if g.mph then f[#f + 1] = "mph = " .. g.mph end
		if g.rpm then f[#f + 1] = "rpm = " .. g.rpm end
		if g.down then f[#f + 1] = "down = " .. g.down end
		parts[i] = "{ " .. table.concat(f, ", ") .. " }"
	end
	return string.format('["%s"] = { topRpm = %d, %s },', name, spec.topRpm or 0, table.concat(parts, ", "))
end

---------------------------------------------------------------------------
-- rev response: "rise,fall"
---------------------------------------------------------------------------
DBG.REV_RANGE = { 100, 1500 }
function DBG.DecodeRev(s)
	if type(s) ~= "string" or s == "" then return nil end
	local r, f = s:match("^([%d%.]+),([%d%.]+)$")
	r, f = tonumber(r), tonumber(f)
	if not (r and f) then return nil end
	local lo, hi = DBG.REV_RANGE[1], DBG.REV_RANGE[2]
	return math.Clamp(math.floor(r + 0.5), lo, hi), math.Clamp(math.floor(f + 0.5), lo, hi)
end
function DBG.EncodeRev(r, f) return string.format("%d,%d", r, f) end

---------------------------------------------------------------------------
-- the live overrides, on top of the core's config (every client and the server)
---------------------------------------------------------------------------
local DT = E.Drivetrain
DBG.REV_DEFAULT = DBG.REV_DEFAULT or { rise = DT.REV.rise, fall = DT.REV.fall }
local lastGlobalRev

-- the global rev response (Global2 audio_dbg_rev) onto DT.REV, back to the file's values when cleared
local function followGlobalRev()
	local g = GetGlobal2String("audio_dbg_rev", "")
	if g == lastGlobalRev then return end
	lastGlobalRev = g
	local r, f = DBG.DecodeRev(g)
	DT.REV.rise, DT.REV.fall = r or DBG.REV_DEFAULT.rise, f or DBG.REV_DEFAULT.fall
end

local cache = setmetatable({}, { __mode = "k" })

function DBG.Install()
	if not E.GetEngineConfig or E.GetEngineConfig == DBG.wrapper then return end
	local base = E.GetEngineConfig
	DBG.baseGetEngineConfig = base
	-- cl_engine and sv_engine call E.GetEngineConfig every frame: the overrides ride on it
	DBG.wrapper = function(ent)
		local cfg = base(ent)
		if not cfg then return cfg end
		followGlobalRev()
		local gs, rs = ent:GetNW2String("audio_dbg_gear", ""), ent:GetNW2String("audio_dbg_rev", "")
		if gs == "" and rs == "" then return cfg end
		local c = cache[ent]
		if c and c.base == cfg and c.gs == gs and c.rs == rs then return c.cfg end
		local o = {}
		for k, v in pairs(cfg) do o[k] = v end
		local spec = DBG.DecodeGearing(gs)
		if spec then E.ApplyGearing(o, spec) end
		local r, f = DBG.DecodeRev(rs)
		if r then o.revRise, o.revFall = r, f end
		cache[ent] = { base = cfg, gs = gs, rs = rs, cfg = o }
		return o
	end
	E.GetEngineConfig = DBG.wrapper
end

-- the core's own config (without the debug overrides)
function DBG.BaseConfig(ent)
	return (DBG.baseGetEngineConfig or E.GetEngineConfig)(ent)
end

DBG.Install()
