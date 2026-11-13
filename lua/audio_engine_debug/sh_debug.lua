--[[
	Audio Engine debug module (shared)

	Tuning tools on top of the core addon, for testing on a dev server. Loaded by
	autorun/audio_engine_init.lua whenever this folder is there; to ship the addon without them,
	delete lua/audio_engine_debug/. On by default (audio_engine_debug 1; 0 switches them off), and
	only superadmins (or the host of a listen / single-player game) may use them.

	What it changes live goes through the core's own data paths, so a result can be pasted back:
	  gearing         NW2 audio_dbg_gear on the car  -> sh_carlist.lua AudioEngine.CAR_GEARING (AudioEngine.ApplyGearing)
	  rev response    NW2 audio_dbg_rev on the car, or Global2 audio_dbg_rev for every car
	                                                 -> AudioEngine.CAR_REV / sh_drivetrain.lua Drivetrain.REV
	  handling script the car's params (server)      -> the vehicle script txt (copied out)
	  assists/tables  server convars and AudioEngine.TRACTION / AudioEngine.ANTI_SPIN / AudioEngine.STABILITY_DEFAULTS values
]]

local AudioEngine = AUDIO_ENGINE
local EngineDebug = AudioEngine.Debug or {}
AudioEngine.Debug = EngineDebug

EngineDebug.debugConVar = CreateConVar("audio_engine_debug", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED,
	"1 = the Audio Engine debug tools (audio_engine_debug_menu, !enginedebug) for superadmins (default); 0 = off")

function EngineDebug.Enabled() return EngineDebug.debugConVar:GetBool() end

function EngineDebug.Allowed(requester)
	if not EngineDebug.Enabled() or not IsValid(requester) then return false end
	return requester:IsSuperAdmin() or game.SinglePlayer() or (requester.IsListenServerHost and requester:IsListenServerHost())
end

---------------------------------------------------------------------------
-- server convars the debug menu shows as controls (the client asks the server to set them)
---------------------------------------------------------------------------
EngineDebug.SERVER_CVARS = {
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
EngineDebug.SERVER_CVAR_SET = {}
for _, cvarEntry in ipairs(EngineDebug.SERVER_CVARS) do EngineDebug.SERVER_CVAR_SET[cvarEntry[1]] = cvarEntry end

-- the convars that are the addon's handling changes: all 0 = PERP's own handling
EngineDebug.HANDLING_CVARS = { "audio_engine_handling", "audio_engine_traction", "audio_engine_stability" }

--[[
	Server tables tuned live: { table in E, key, min, max, decimals, label }. They reset to the
	file's values on a map change / restart: copy the changed lines out with the menu's button.
]]
EngineDebug.TUNABLES = {
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
-- gearing by shift speeds (sh_presets.lua AudioEngine.ApplyGearing), as text for the network
-- "topRpm;mph,rpm,down;mph,rpm,down;...;,,down"
---------------------------------------------------------------------------
local function clampNumber(value, low, high, decimals)
	value = tonumber(value)
	if not value then return nil end
	value = math.Clamp(value, low, high)
	local rounding = 10 ^ (decimals or 0)
	return math.floor(value * rounding + 0.5) / rounding
end

function EngineDebug.SanitizeGearing(spec)
	if type(spec) ~= "table" then return nil end
	local gearCount = math.min(8, #spec)
	if gearCount < 1 then return nil end
	local clean = { topRpm = clampNumber(spec.topRpm, 500, 20000, 0) }
	for i = 1, gearCount do
		local gearSpec = type(spec[i]) == "table" and spec[i] or {}
		local downMph = clampNumber(gearSpec.down, 0, 300, 1)
		clean[i] = {
			mph = i < gearCount and (clampNumber(gearSpec.mph, 1, 300, 1) or 10) or nil,
			rpm = i < gearCount and (clampNumber(gearSpec.rpm, 500, 20000, 0) or 5000) or nil,
			down = (i > 1 and downMph and downMph > 0) and downMph or nil,
		}
	end
	return clean
end

function EngineDebug.EncodeGearing(spec)
	spec = EngineDebug.SanitizeGearing(spec)
	if not spec then return "" end
	local parts = { spec.topRpm and tostring(spec.topRpm) or "" }
	for i, gearSpec in ipairs(spec) do
		parts[i + 1] = (gearSpec.mph and tostring(gearSpec.mph) or "") .. "," .. (gearSpec.rpm and tostring(gearSpec.rpm) or "") .. "," .. (gearSpec.down and tostring(gearSpec.down) or "")
	end
	return table.concat(parts, ";")
end

function EngineDebug.DecodeGearing(text)
	if type(text) ~= "string" or text == "" or #text > 400 then return nil end
	local parts = string.Explode(";", text)
	local spec = { topRpm = tonumber(parts[1]) }
	for i = 2, #parts do
		local fields = string.Explode(",", parts[i])
		spec[i - 1] = { mph = tonumber(fields[1]), rpm = tonumber(fields[2]), down = tonumber(fields[3]) }
	end
	return EngineDebug.SanitizeGearing(spec)
end

-- the gearing a resolved config drives with, as shift speeds (what the editor starts from)
function EngineDebug.GearingFromConfig(config)
	local Drivetrain = AudioEngine.Drivetrain
	local shiftPoints = config.shift and Drivetrain.ShiftPoints(config.shift) or Drivetrain.SHIFT
	local rpmPerSpeed = 60 / (2 * math.pi * config.wheelRadius)
	local shiftPlan = config.shiftPlan
	local gearCount = #config.gears
	local spec = {}
	for i = 1, gearCount do
		local ratio = config.gears[i] * config.final
		local gearSpec = {}
		if i < gearCount then
			gearSpec.rpm = math.floor((shiftPlan and shiftPlan.up[i] or config.redline * shiftPoints.upRpm) + 0.5)
			gearSpec.mph = math.floor(gearSpec.rpm / (rpmPerSpeed * ratio) / 0.44704 * 10 + 0.5) / 10
		end
		if shiftPlan and shiftPlan.down[i] then gearSpec.down = math.floor(shiftPlan.down[i] / 0.44704 * 10 + 0.5) / 10 end
		spec[i] = gearSpec
	end
	spec.topRpm = math.floor(config.topSpeed / 3.6 * rpmPerSpeed * config.gears[gearCount] * config.final + 0.5)
	return spec
end

-- as an entry for sh_carlist.lua AudioEngine.CAR_GEARING
function EngineDebug.GearingLua(name, spec)
	local parts = {}
	for i, gearSpec in ipairs(spec) do
		local fields = {}
		if gearSpec.mph then fields[#fields + 1] = "mph = " .. gearSpec.mph end
		if gearSpec.rpm then fields[#fields + 1] = "rpm = " .. gearSpec.rpm end
		if gearSpec.down then fields[#fields + 1] = "down = " .. gearSpec.down end
		parts[i] = "{ " .. table.concat(fields, ", ") .. " }"
	end
	return string.format('["%s"] = { topRpm = %d, %s },', name, spec.topRpm or 0, table.concat(parts, ", "))
end

---------------------------------------------------------------------------
-- rev response: "rise,fall"
---------------------------------------------------------------------------
EngineDebug.REV_RANGE = { 100, 1500 }
function EngineDebug.DecodeRev(text)
	if type(text) ~= "string" or text == "" then return nil end
	local rise, fall = text:match("^([%d%.]+),([%d%.]+)$")
	rise, fall = tonumber(rise), tonumber(fall)
	if not (rise and fall) then return nil end
	local low, high = EngineDebug.REV_RANGE[1], EngineDebug.REV_RANGE[2]
	return math.Clamp(math.floor(rise + 0.5), low, high), math.Clamp(math.floor(fall + 0.5), low, high)
end
function EngineDebug.EncodeRev(rise, fall) return string.format("%d,%d", rise, fall) end

---------------------------------------------------------------------------
-- the live overrides, on top of the core's config (every client and the server)
---------------------------------------------------------------------------
local Drivetrain = AudioEngine.Drivetrain
EngineDebug.REV_DEFAULT = EngineDebug.REV_DEFAULT or { rise = Drivetrain.REV.rise, fall = Drivetrain.REV.fall }
local lastGlobalRev

-- the global rev response (Global2 audio_dbg_rev) onto Drivetrain.REV, back to the file's values when cleared
local function followGlobalRev()
	local globalRev = GetGlobal2String("audio_dbg_rev", "")
	if globalRev == lastGlobalRev then return end
	lastGlobalRev = globalRev
	local rise, fall = EngineDebug.DecodeRev(globalRev)
	Drivetrain.REV.rise, Drivetrain.REV.fall = rise or EngineDebug.REV_DEFAULT.rise, fall or EngineDebug.REV_DEFAULT.fall
end

local overrideCache = setmetatable({}, { __mode = "k" })

function EngineDebug.Install()
	if not AudioEngine.GetEngineConfig or AudioEngine.GetEngineConfig == EngineDebug.wrapper then return end
	local base = AudioEngine.GetEngineConfig
	EngineDebug.baseGetEngineConfig = base
	-- cl_engine and sv_engine call AudioEngine.GetEngineConfig every frame: the overrides ride on it
	EngineDebug.wrapper = function(ent)
		local config = base(ent)
		if not config then return config end
		followGlobalRev()
		local gearingString, revString = ent:GetNW2String("audio_dbg_gear", ""), ent:GetNW2String("audio_dbg_rev", "")
		if gearingString == "" and revString == "" then return config end
		local cached = overrideCache[ent]
		if cached and cached.baseConfig == config and cached.gearingString == gearingString and cached.revString == revString then return cached.config end
		local overridden = {}
		for key, value in pairs(config) do overridden[key] = value end
		local spec = EngineDebug.DecodeGearing(gearingString)
		if spec then AudioEngine.ApplyGearing(overridden, spec) end
		local rise, f = EngineDebug.DecodeRev(revString)
		if rise then overridden.revRise, overridden.revFall = rise, f end
		overrideCache[ent] = { baseConfig = config, gearingString = gearingString, revString = revString, config = overridden }
		return overridden
	end
	AudioEngine.GetEngineConfig = EngineDebug.wrapper
end

-- the core's own config (without the debug overrides)
function EngineDebug.BaseConfig(ent)
	return (EngineDebug.baseGetEngineConfig or AudioEngine.GetEngineConfig)(ent)
end

EngineDebug.Install()
