--[[
	Audio Engine - engine profiles (shared)

	A profile is everything the Rev Bench page let you change: engine layout, pitch, exhaust
	tone, volume, idle, redline, gear ratios and final drive, plus realism and turbo. Each
	car carries its own profile in a networked string, so everyone hears the same engine.
	An empty string means the car's stock preset.
]]

AUDIO_ENGINE = AUDIO_ENGINE or {}
local AudioEngine = AUDIO_ENGINE

local min, max, floor, pi = math.min, math.max, math.floor, math.pi

AudioEngine.LAYOUT_ORDER = {
	{ "single", "1 · single (thumper)" },
	{ "vtwin", "2 · V-twin, 45°" },
	{ "ptwin", "2 · parallel twin, 270°" },
	{ "triple", "3 · inline triple" },
	{ "i4", "4 · inline four" },
	{ "boxer", "4 · flat-four boxer" },
	{ "i5", "5 · inline five" },
	{ "i6", "6 · straight six" },
	{ "v6odd", "6 · V6, 90° odd-fire" },
	{ "v8cross", "8 · V8, crossplane" },
	{ "v8flat", "8 · V8, flat-plane" },
	{ "v10", "10 · V10" },
	{ "v12", "12 · V12" },
	{ "v6", "6 · V6, 60° even-fire" },
	{ "flat6", "6 · flat-six" },
	{ "flat12", "12 · flat-twelve" },
	{ "w16", "16 · W16" },
	{ "rotary2", "2-rotor Wankel" },
	{ "rotary3", "3-rotor Wankel" },
	{ "electric", "Electric motor" },
}
-- firings per 720 degrees (for a Wankel, rotor firings: one per rotor per shaft turn)
AudioEngine.LAYOUT_CYL = { single = 1, vtwin = 2, ptwin = 2, triple = 3, i4 = 4, boxer = 4, i5 = 5, i6 = 6, v6odd = 6, v8cross = 8, v8flat = 8, v10 = 10, v12 = 12,
	v6 = 6, flat6 = 6, flat12 = 12, w16 = 16, rotary2 = 4, rotary3 = 6, electric = 1 }

AudioEngine.GEAR_PRESETS = {
	{ id = "amg5",    name = "AMG 5-speed auto", gears = { 3.59, 2.19, 1.41, 1.00, 0.83 }, final = 2.82 },
	{ id = "road",    name = "Road 6-speed",     gears = { 3.60, 2.10, 1.45, 1.10, 0.90, 0.76 }, final = 3.90 },
	{ id = "close",   name = "Close-ratio 6",    gears = { 3.00, 2.10, 1.60, 1.30, 1.10, 0.95 }, final = 4.30 },
	{ id = "seven",   name = "7-speed auto",     gears = { 4.38, 2.86, 1.92, 1.37, 1.00, 0.82, 0.73 }, final = 2.65 },
	{ id = "eco",     name = "Economy 5",        gears = { 3.45, 1.94, 1.29, 0.97, 0.78 }, final = 3.65 },
	{ id = "classic", name = "Classic 4",        gears = { 2.97, 1.84, 1.31, 1.00 }, final = 3.70 },
	{ id = "ev",      name = "Single-speed (electric)", gears = { 1.00 }, final = 9.00 },
}
local function gearPreset(id)
	for _, preset in ipairs(AudioEngine.GEAR_PRESETS) do if preset.id == id then return preset end end
	return AudioEngine.GEAR_PRESETS[1]
end
AudioEngine.GearPreset = gearPreset

--[[ Engine presets. topSpeed: the gearing is fitted so top gear reaches redline there. ]]
-- One preset per engine type in the game (see sh_carlist.lua for which car uses which),
-- plus the SL65's own engine and the original Rev Bench sound.
AudioEngine.ENGINE_PRESETS = {
	{ id = "sl65",   name = "SL65 AMG · 6.0 V12 biturbo",               layout = "v12",     pitch = 1.00, tone = 0.40, idle = 700,  redline = 6000,  realism = 1, turbo = true,  bov = true,  pops = 0.1,  gurgle = 0.35, popTone = 0.15, gearbox = "amg5" },
	-- V12 / flat-12 / W16
	{ id = "v12na",  name = "V12",                                      layout = "v12",     pitch = 1.00, tone = 0.60, idle = 1000, redline = 8000,  realism = 1, turbo = false, bov = false, pops = 0.3,  gurgle = 0.25, popTone = 0.3,  gearbox = "seven" },
	{ id = "v12t",   name = "V12 · turbo",                              layout = "v12",     pitch = 1.00, tone = 0.50, idle = 900,  redline = 8000,  realism = 1, turbo = true,  bov = true,  pops = 0.3,  gurgle = 0.25, popTone = 0.25, gearbox = "close" },
	{ id = "f12",    name = "Flat-12 (180° V12)",                       layout = "flat12",  pitch = 1.00, tone = 0.60, idle = 1000, redline = 7200,  realism = 1, turbo = false, bov = false, pops = 0.3,  gurgle = 0.3,  popTone = 0.3,  gearbox = "close" },
	{ id = "w16",    name = "W16 · quad-turbo",                         layout = "w16",     pitch = 0.90, tone = 0.50, idle = 750,  redline = 6600,  realism = 1, turbo = true,  bov = true,  pops = 0.1,  gurgle = 0.35, popTone = 0.2,  gearbox = "seven" },
	-- V10
	{ id = "v10",    name = "V10",                                      layout = "v10",     pitch = 1.00, tone = 0.65, idle = 950,  redline = 8500,  realism = 1, turbo = false, bov = false, pops = 0.5,  gurgle = 0.3,  popTone = 0.4,  gearbox = "close" },
	{ id = "v10l",   name = "V10 · big-block (Viper, Ram SRT-10)",      layout = "v10",     pitch = 0.90, tone = 0.55, idle = 750,  redline = 6000,  realism = 1, turbo = false, bov = false, pops = 0.3,  gurgle = 0.45, popTone = 0.3,  gearbox = "road" },
	-- V8
	{ id = "v8x",    name = "V8 · crossplane (heavy duty, trucks)",     layout = "v8cross", pitch = 0.95, tone = 0.65, idle = 700,  redline = 6000,  realism = 1, turbo = false, bov = false, pops = 0.4,  gurgle = 0.6,  popTone = 0.25, gearbox = "road" },
	-- own voices, tuned in Tone Studio; muffle = the car's silencer (config.muffle)
	{ id = "v8m",    name = "V8 · old muscle",                          layout = "v8cross", pitch = 0.90, tone = 0.85, idle = 800,  redline = 6000,  realism = 1, turbo = false, bov = false, pops = 0.4,  gurgle = 0.85, popTone = 0.25, gearbox = "road",
	  character = { f1 = 56, f2 = 340, f3 = 150, w = 1.25, o1 = 0.32, o05 = 0.45 } },
	{ id = "v8p",    name = "V8 · modern performance",                  layout = "v8cross", pitch = 1.00, tone = 0.80, idle = 750,  redline = 6000,  realism = 1, turbo = false, bov = false, pops = 0.4,  gurgle = 0.4,  popTone = 0.25, gearbox = "road",
	  character = { f1 = 85, f2 = 450, f3 = 195, w = 0.88, o1 = 0.15, o05 = 0.18 } },
	{ id = "v8r",    name = "V8 · refined sedan",                       layout = "v8cross", pitch = 1.00, tone = 0.30, idle = 650,  redline = 6000,  realism = 1, turbo = false, bov = false, pops = 0.4,  gurgle = 0.2,  popTone = 0.25, gearbox = "road",
	  character = { f1 = 70, f2 = 220, f3 = 125, w = 1.35, o1 = 0.09, o05 = 0.12 }, muffle = 0.65 },
	{ id = "v8s",    name = "V8 · crossplane, high-revving (M3, AMG)",  layout = "v8cross", pitch = 1.05, tone = 0.60, idle = 800,  redline = 8000,  realism = 1, turbo = false, bov = false, pops = 0.4,  gurgle = 0.4,  popTone = 0.3,  gearbox = "seven" },
	{ id = "v8flat", name = "V8 · flat-plane (Ferrari, McLaren)",       layout = "v8flat",  pitch = 1.05, tone = 0.70, idle = 950,  redline = 8500,  realism = 1, turbo = false, bov = false, pops = 0.5,  gurgle = 0.3,  popTone = 0.45, gearbox = "close" },
	{ id = "v8xt",   name = "V8 · twin-turbo",                          layout = "v8cross", pitch = 1.00, tone = 0.55, idle = 750,  redline = 7000,  realism = 1, turbo = true,  bov = true,  pops = 0.6,  gurgle = 0.5,  popTone = 0.25, gearbox = "seven" },
	{ id = "v8h",    name = "V8 hybrid (918 Spyder, P1)",               layout = "v8flat",  pitch = 1.05, tone = 0.65, idle = 1000, redline = 9000,  realism = 1, turbo = false, bov = false, pops = 0.4,  gurgle = 0.2,  popTone = 0.4,  gearbox = "seven" },
	-- V6
	{ id = "v6",     name = "V6",                                       layout = "v6",      pitch = 1.00, tone = 0.50, idle = 750,  redline = 6800,  realism = 1, turbo = false, bov = false, pops = 0.2,  gurgle = 0.3,  popTone = 0.2,  gearbox = "eco" },
	{ id = "v6odd",  name = "V6 · 90° odd-fire (DeLorean)",              layout = "v6odd",   pitch = 1.00, tone = 0.45, idle = 750,  redline = 6000,  realism = 1, turbo = false, bov = false, pops = 0.2,  gurgle = 0.4,  popTone = 0.2,  gearbox = "classic" },
	{ id = "v6t",    name = "V6 · twin-turbo",                          layout = "v6",      pitch = 1.00, tone = 0.55, idle = 800,  redline = 7000,  realism = 1, turbo = true,  bov = true,  pops = 0.4,  gurgle = 0.3,  popTone = 0.3,  gearbox = "close" },
	-- flat-six / straight six / five
	{ id = "f6",     name = "Flat-6 (Porsche GT3)",                     layout = "flat6",   pitch = 1.05, tone = 0.70, idle = 950,  redline = 9000,  realism = 1, turbo = false, bov = false, pops = 0.4,  gurgle = 0.25, popTone = 0.4,  gearbox = "close" },
	{ id = "i6",     name = "Inline-6",                                 layout = "i6",      pitch = 1.00, tone = 0.50, idle = 750,  redline = 7000,  realism = 1, turbo = false, bov = false, pops = 0.2,  gurgle = 0.25, popTone = 0.2,  gearbox = "road" },
	{ id = "i6t",    name = "Inline-6 · turbo",                         layout = "i6",      pitch = 1.00, tone = 0.50, idle = 750,  redline = 7000,  realism = 1, turbo = true,  bov = true,  pops = 0.4,  gurgle = 0.3,  popTone = 0.25, gearbox = "road" },
	{ id = "i5t",    name = "Inline-5 · turbo",                         layout = "i5",      pitch = 1.00, tone = 0.60, idle = 850,  redline = 7000,  realism = 1, turbo = true,  bov = true,  pops = 0.7,  gurgle = 0.45, popTone = 0.35, gearbox = "close" },
	-- four, three
	-- i4: tuned in Tone Studio on an economy car, now the sporty voice (i4st with a turbo); i4w and i4q are the
	-- economy voices. economyTuned: economy cars keep the preset's tone and burble
	{ id = "i4",     name = "Inline-4 · sporty",                        layout = "i4",      pitch = 1.25, tone = 0.75, idle = 800,  redline = 6200,  realism = 1, turbo = false, bov = false, pops = 0.0,  gurgle = 0.05, popTone = 0.2,  gearbox = "eco",
	  character = { f1 = 130, f2 = 647, f3 = 193, w = 1.44, o1 = 0.3, o05 = 0.15 }, economyTuned = true },
	{ id = "i4st",   name = "Inline-4 · sporty turbo",                  layout = "i4",      pitch = 1.25, tone = 0.75, idle = 850,  redline = 7000,  realism = 1, turbo = true,  bov = true,  pops = 0.5,  gurgle = 0.05, popTone = 0.3,  gearbox = "road",
	  character = { f1 = 130, f2 = 647, f3 = 193, w = 1.44, o1 = 0.3, o05 = 0.15 } },
	{ id = "i4w",    name = "Inline-4 · warm hatch",                    layout = "i4",      pitch = 1.00, tone = 0.42, idle = 800,  redline = 6200,  realism = 1, turbo = false, bov = false, pops = 0.0,  gurgle = 0.05, popTone = 0.2,  gearbox = "eco",
	  character = { f1 = 92, f2 = 320, f3 = 175, w = 1.15, o1 = 0.14, o05 = 0.1 }, economyTuned = true, muffle = 0.7 },
	{ id = "i4q",    name = "Inline-4 · quiet hum",                     layout = "i4",      pitch = 1.15, tone = 0.30, idle = 800,  redline = 6200,  realism = 1, turbo = false, bov = false, pops = 0.0,  gurgle = 0,    popTone = 0.2,  gearbox = "eco",
	  character = { f1 = 120, f2 = 420, f3 = 215, w = 1.0, o1 = 0.05, o05 = 0.03 }, economyTuned = true, muffle = 0.9 },
	{ id = "i4s",    name = "Inline-4 · high-revving (Type R, S2000)",  layout = "i4",      pitch = 1.05, tone = 0.65, idle = 900,  redline = 8800,  realism = 1, turbo = false, bov = false, pops = 0.3,  gurgle = 0.15, popTone = 0.3,  gearbox = "close" },
	{ id = "i4t",    name = "Inline-4 · turbo",                         layout = "i4",      pitch = 1.05, tone = 0.55, idle = 850,  redline = 7000,  realism = 1, turbo = true,  bov = true,  pops = 0.5,  gurgle = 0.3,  popTone = 0.3,  gearbox = "road" },
	{ id = "i4h",    name = "Inline-4 hybrid (Prius)",                  layout = "i4",      pitch = 0.95, tone = 0.25, idle = 1000, redline = 5200,  realism = 1, turbo = false, bov = false, pops = 0.0,  gurgle = 0.0,  popTone = 0.1,  gearbox = "eco" },
	{ id = "i3",     name = "Inline-3",                                 layout = "triple",  pitch = 1.00, tone = 0.45, idle = 850,  redline = 6300,  realism = 1, turbo = false, bov = false, pops = 0.1,  gurgle = 0.2,  popTone = 0.2,  gearbox = "eco" },
	{ id = "f4",     name = "Flat-4 (FR-S)",                            layout = "boxer",   pitch = 1.00, tone = 0.55, idle = 800,  redline = 7400,  realism = 1, turbo = false, bov = false, pops = 0.3,  gurgle = 0.35, popTone = 0.25, gearbox = "road" },
	{ id = "f4air",  name = "Flat-4 · air-cooled (Beetle, Camper)",     layout = "boxer",   pitch = 0.90, tone = 0.55, idle = 850,  redline = 4500,  realism = 1, turbo = false, bov = false, pops = 0.1,  gurgle = 0.5,  popTone = 0.2,  gearbox = "classic" },
	{ id = "boxer",  name = "Flat-4 · turbo (Subaru)",                  layout = "boxer",   pitch = 1.00, tone = 0.60, idle = 800,  redline = 7000,  realism = 1, turbo = true,  bov = true,  pops = 0.6,  gurgle = 0.5,  popTone = 0.3,  gearbox = "road" },
	-- rotary
	{ id = "r2",     name = "2-rotor Wankel (RX-8)",                    layout = "rotary2", pitch = 1.00, tone = 0.60, idle = 900,  redline = 9000,  realism = 1, turbo = false, bov = false, pops = 0.4,  gurgle = 0.7,  popTone = 0.4,  gearbox = "road" },
	{ id = "r2t",    name = "2-rotor Wankel · turbo (RX-7)",            layout = "rotary2", pitch = 1.00, tone = 0.60, idle = 900,  redline = 8000,  realism = 1, turbo = true,  bov = true,  pops = 0.6,  gurgle = 0.6,  popTone = 0.4,  gearbox = "close" },
	{ id = "r3",     name = "3-rotor Wankel (Mazda Furai)",             layout = "rotary3", pitch = 1.00, tone = 0.80, idle = 1100, redline = 10000, realism = 1, turbo = false, bov = false, pops = 0.7,  gurgle = 0.6,  popTone = 0.6,  gearbox = "close" },
	-- electric
	{ id = "ev",     name = "Electric motor",                           layout = "electric",pitch = 1.00, tone = 0.40, idle = 500,  redline = 16000, realism = 1, turbo = false, bov = false, pops = 0.0,  gurgle = 0.0,  popTone = 0.2,  gearbox = "ev" },
	-- the original page
	{ id = "rb",     name = "Rev Bench classic (inline-4)",             layout = "i4",      pitch = 1.00, tone = 0.55, idle = 850,  redline = 7000,  realism = 0, turbo = false, bov = false, pops = 0.3,  gurgle = 0.0,  popTone = 0.25, gearbox = "road" },
}
function AudioEngine.EnginePreset(id)
	for _, preset in ipairs(AudioEngine.ENGINE_PRESETS) do if preset.id == id then return preset end end
	return nil
end

-- a full, editable profile from a preset (performance at the car's stock values)
function AudioEngine.ProfileFromPreset(id)
	local preset = AudioEngine.EnginePreset(id) or AudioEngine.ENGINE_PRESETS[1]
	local gearbox = gearPreset(preset.gearbox)
	local gears = {}
	for index, ratio in ipairs(gearbox.gears) do gears[index] = ratio end
	return {
		preset = preset.id, layout = preset.layout, pitch = preset.pitch, tone = preset.tone, volume = 1,
		idle = preset.idle, redline = preset.redline, realism = preset.realism, turbo = preset.turbo,
		gears = gears, final = gearbox.final, fit = 1,
		accel = 1, vmax = 0, pops = preset.pops or 0, bov = preset.bov and true or false,
		gurgle = preset.gurgle or 0, popVol = 1, popTone = preset.popTone or 0.2,
		turboVol = 1, bovVol = 1,
	}
end

---------------------------------------------------------------------------
-- validation (the server runs this on everything a client sends)
---------------------------------------------------------------------------
local function clampAndRound(value, low, high, step)
	value = tonumber(value) or low
	value = min(high, max(low, value))
	return floor(value / step + 0.5) * step
end

function AudioEngine.SanitizeProfile(profile)
	local clean = {}
	clean.preset = (type(profile.preset) == "string" and profile.preset:match("^[%w_]+$") and #profile.preset <= 16) and profile.preset or "custom"
	clean.layout = AudioEngine.LAYOUT_CYL[profile.layout] and profile.layout or "i4"
	clean.pitch = clampAndRound(profile.pitch, 0.5, 2, 0.05)
	clean.tone = clampAndRound(profile.tone, 0, 1, 0.05)
	clean.volume = clampAndRound(profile.volume, 0, 1.5, 0.05)
	clean.idle = clampAndRound(profile.idle, 500, 1500, 25)
	clean.redline = clampAndRound(profile.redline, max(3500, clean.idle * 3), clean.layout == "electric" and 16000 or 12000, 100)
	clean.realism = clampAndRound(profile.realism, 0, 1, 0.1)
	clean.turbo = profile.turbo and true or false
	clean.gears = {}
	local sourceGears = type(profile.gears) == "table" and profile.gears or gearPreset("road").gears
	for i = 1, min(8, #sourceGears) do clean.gears[i] = clampAndRound(sourceGears[i], 0.3, 8, 0.01) end
	if #clean.gears < 1 then clean.gears[1] = 1 end
	clean.final = clampAndRound(profile.final, 2, 6, 0.01)
	clean.fit = (tonumber(profile.fit) or 0) > 0 and 1 or 0
	-- performance: acceleration (engine power multiplier) and top speed (km/h, 0 = car's own)
	clean.accel = clampAndRound(profile.accel or 1, 0.5, 2.5, 0.05)
	clean.vmax = (tonumber(profile.vmax) or 0) > 0 and clampAndRound(profile.vmax, 40, 450, 1) or 0   -- km/h (the menu sets it in whole mph)
	-- pops & bangs: how often (0 = off) and how loud; the turbo blow-off valve
	clean.pops = clampAndRound(profile.pops or 0, 0, 1, 0.05)
	clean.popVol = clampAndRound(profile.popVol or 1, 0, 2, 0.05)
	clean.bov = (profile.bov == nil and clean.turbo) or (profile.bov and true or false)
	-- turbo whistle and blow-off valve volume (1 = default, up to 200%)
	clean.turboVol = clampAndRound(profile.turboVol or 1, 0, 2, 0.05)
	clean.bovVol = clampAndRound(profile.bovVol or 1, 0, 2, 0.05)
	-- gurgle: ragged, burbly combustion off throttle
	clean.gurgle = clampAndRound(profile.gurgle or 0, 0, 1, 0.05)
	clean.popTone = clampAndRound(profile.popTone or 0.2, 0, 1, 0.05)
	-- an electric motor has no exhaust: no turbo, pops or burble
	if clean.layout == "electric" then
		clean.turbo, clean.bov, clean.pops, clean.gurgle = false, false, 0, 0
		clean.idle = min(clean.idle, 600)
	end
	return clean
end

-- compact text form for networking:
-- preset|layout|pitch|tone|vol|idle|red|realism|turbo|g1,g2,..|final|fit|accel|vmax|pops|bov|gurgle|popVol|popTone|turboVol|bovVol
local function formatNumber(value) return (string.format("%.2f", value):gsub("0+$", ""):gsub("%.$", "")) end
function AudioEngine.EncodeProfile(profile)
	profile = AudioEngine.SanitizeProfile(profile)
	local gearTexts = {}
	for index, ratio in ipairs(profile.gears) do gearTexts[index] = formatNumber(ratio) end
	return table.concat({
		profile.preset, profile.layout, formatNumber(profile.pitch), formatNumber(profile.tone), formatNumber(profile.volume), tostring(profile.idle), tostring(profile.redline),
		formatNumber(profile.realism), profile.turbo and "1" or "0", table.concat(gearTexts, ","), formatNumber(profile.final), tostring(profile.fit),
		formatNumber(profile.accel), tostring(profile.vmax), formatNumber(profile.pops), profile.bov and "1" or "0", formatNumber(profile.gurgle), formatNumber(profile.popVol), formatNumber(profile.popTone),
		formatNumber(profile.turboVol), formatNumber(profile.bovVol),
	}, "|")
end

local function split(text, separator)
	local parts = {}
	local start = 1
	while true do
		local found = string.find(text, separator, start, true)
		if not found then parts[#parts + 1] = text:sub(start); break end
		parts[#parts + 1] = text:sub(start, found - 1)
		start = found + 1
	end
	return parts
end

function AudioEngine.DecodeProfile(text)
	if type(text) ~= "string" or text == "" or #text > 200 then return nil end
	local fields = split(text, "|")
	if #fields < 12 then return nil end
	local gears = {}
	for _, value in ipairs(split(fields[10], ",")) do gears[#gears + 1] = tonumber(value) end
	-- blow-off valve: "0" must stay off (older strings without the field default to on with a turbo)
	local bov = nil
	if fields[16] ~= nil and fields[16] ~= "" then bov = (fields[16] == "1") end
	return AudioEngine.SanitizeProfile({
		preset = fields[1], layout = fields[2], pitch = fields[3], tone = fields[4], volume = fields[5], idle = fields[6], redline = fields[7],
		realism = fields[8], turbo = fields[9] == "1", gears = gears, final = fields[11], fit = fields[12],
		accel = fields[13], vmax = fields[14], pops = fields[15], bov = bov,
		gurgle = fields[17], popVol = fields[18], popTone = fields[19], turboVol = fields[20], bovVol = fields[21],
	})
end

---------------------------------------------------------------------------
-- profile -> the config the synth, sound bank and rpm model use
---------------------------------------------------------------------------
-- rpm points that get their own generated loop: ~1.26x apart from just above idle to redline
-- (an electric motor's whine is a few tones that pitch-shift cleanly: fewer, wider bands, though
-- not so wide that its body resonances move far)
function AudioEngine.MakeBands(idle, redline, step)
	step = step or 1.26
	local lowest = idle * 1.07
	local bandCount = math.max(4, math.ceil(math.log(redline / lowest) / math.log(step)) + 1)
	local bandRatio = (redline / lowest) ^ (1 / (bandCount - 1))
	local bands = {}
	for i = 1, bandCount do bands[i] = floor(lowest * bandRatio ^ (i - 1) / 10 + 0.5) * 10 end
	return bands
end

-- final drive so top gear reaches redline at the given top speed
function AudioEngine.FitFinal(gears, redline, wheelRadius, topKmh, fit)
	local rpmPerSpeed = 60 / (2 * pi * wheelRadius)
	-- (with fitted gearing it turns AudioEngine.TOP_GEAR_DROP under redline there, see AudioEngine.FitGearCount)
	return redline * (fit and AudioEngine.TopGearShare(redline) or 0.97) / ((topKmh / 3.6) * rpmPerSpeed * gears[#gears])
end

--[[
	The top gear never reaches redline: at the top speed it turns TOP_GEAR_DROP rpm under redline
	(AudioEngine.FitFinal; at least TOP_GEAR_MIN of it, for the low-revving diesels), so the gears are spaced
	up to the speed the top gear would reach at redline.
]]
AudioEngine.TOP_GEAR_DROP, AudioEngine.TOP_GEAR_MIN = 1000, 0.6
function AudioEngine.TopGearShare(redline)
	return max(AudioEngine.TOP_GEAR_MIN, (redline - AudioEngine.TOP_GEAR_DROP) / redline)
end

--[[
	Fitted gearing comes from the top speed alone, not from a model of a real gearbox: about one
	gear per GEAR_FIT.kmhPerGear of top speed, and enough that no step between gears is over
	stepMax (a slow car's 1st still ends at firstMin km/h), at least 2 and at most maxCount or the
	box's own count, whichever is lower. A car may set its own count (sh_carlist.lua CAR_GEARS,
	any 2..8: the Furai's 6). 1st reaches firstShare of the top speed (at least firstMin km/h),
	the gears in between end at speeds evenly spaced in speed^spread: a car gains speed slower the
	faster it goes, so each gear spans less speed than the one before. If that makes a step over
	stepMax (few gears over a wide span) the spread is lowered until it fits.
	upShare: where the debug module's gearing editor puts a gear's upshift (share of redline).
]]
AudioEngine.GEAR_FIT = { firstMin = 25, firstShare = 0.28, kmhPerGear = 40, stepMax = 2.3, spread = 2.2, maxCount = 5, upShare = 0.92 }

--[[
	A guess at the car's full-throttle acceleration (AudioEngine.GearAccel), only for audio_engine_accel_log
	and the drive demo (not the gear spacing): a pull of GEAR_ACCEL.perWkg x its power-to-weight
	(W/kg, NW2 audio_pwr), at most GEAR_ACCEL.max m/s2, fading as (v/top)^fade towards the top speed.
]]
AudioEngine.GEAR_ACCEL = { perWkg = 0.035, max = 5, fade = 3, defaultWkg = 60, floor = 0.02 }

-- the modelled full-throttle acceleration (m/s2) at v (m/s), for a car of wkg W/kg and top speed vmax (m/s)
function AudioEngine.GearAccel(speed, topSpeed, powerToWeight)
	local accelerationModel = AudioEngine.GEAR_ACCEL
	local launchAcceleration = min(accelerationModel.max, accelerationModel.perWkg * (powerToWeight or accelerationModel.defaultWkg))
	return max(accelerationModel.floor, launchAcceleration * (1 - (min(speed, topSpeed * 0.999) / topSpeed) ^ accelerationModel.fade))
end

-- the modelled time (s) from a standstill to share x top speed (audio_engine_accel_log compares it)
local T_STEPS = 240
function AudioEngine.GearModelTime(topKmh, powerToWeight, share)
	local topSpeed = topKmh / 3.6
	local speedStep = topSpeed * share / T_STEPS
	local elapsed = 0
	for i = 1, T_STEPS do elapsed = elapsed + speedStep / AudioEngine.GearAccel((i - 0.5) * speedStep, topSpeed, powerToWeight) end
	return elapsed
end

-- the speeds (km/h) where each gear reaches redline (`count`: sh_carlist.lua CAR_GEARS)
function AudioEngine.FitGearEnds(topKmh, maxCount, redline, powerToWeight, count)
	local gearFit = AudioEngine.GEAR_FIT
	local firstGearEnd = max(gearFit.firstMin, topKmh * gearFit.firstShare)
	local speedSpan = topKmh / AudioEngine.TopGearShare(redline or 6000) / firstGearEnd
	local countBySteps = 1 + math.ceil(math.log(speedSpan) / math.log(gearFit.stepMax))
	local gearCount
	if count then gearCount = math.Clamp(count, 2, 8)
	else gearCount = math.Clamp(max(floor(topKmh / gearFit.kmhPerGear + 0.5), countBySteps), 2, min(maxCount or gearFit.maxCount, gearFit.maxCount)) end
	-- the speed (as a share of 1st's) where gear i ends, for a spread p (p 0 = geometric)
	local function gearEndsFor(spread)
		local gearEnds = {}
		for i = 1, gearCount do
			local position = (i - 1) / (gearCount - 1)
			gearEnds[i] = spread < 0.05 and speedSpan ^ position or (1 + position * (speedSpan ^ spread - 1)) ^ (1 / spread)
		end
		return gearEnds
	end
	local spread, gearEnds = gearFit.spread
	repeat
		gearEnds = gearEndsFor(spread)
		local withinStepMax = true
		for i = 2, gearCount do if gearEnds[i] / gearEnds[i - 1] > gearFit.stepMax then withinStepMax = false end end
		if withinStepMax then break end
		spread = spread - 0.25
	until spread < 0.05
	if spread < 0.05 then gearEnds = gearEndsFor(0) end
	local endSpeeds = {}
	for i = 1, gearCount do endSpeeds[i] = gearEnds[i] * firstGearEnd end
	return endSpeeds
end

-- the box's ratios respaced for the car's top speed (AudioEngine.FitFinal then sets the final drive)
function AudioEngine.FitGearCount(gears, topKmh, count, redline, powerToWeight)
	if #gears < 2 then return gears end
	local gearEnds = AudioEngine.FitGearEnds(topKmh, #gears, redline, powerToWeight, count)
	local ratios = {}
	for i = 1, #gearEnds do ratios[i] = floor(gears[1] * gearEnds[1] / gearEnds[i] * 100 + 0.5) / 100 end
	return ratios
end

--[[
	A car's own gearing (sh_carlist.lua AudioEngine.CAR_GEARING, made with the debug module's gearing editor),
	set by shift speeds instead of ratios. One entry per gear, the last is the top gear:
	  { mph = 24, rpm = 5500 }             changes up at 24 mph, where it turns 5,500 rpm (W held:
	                                       gentler pulling changes up a little earlier)
	  { mph = 42, rpm = 5600, down = 15 }  ... and changes down under 15 mph coasting or braking
	                                       (no `down`: the default shift points)
	  { down = 60 }                        the top gear: it turns topRpm at the car's top speed
	  topRpm = 5200                        (default: AudioEngine.TOP_GEAR_DROP under redline)
	Each gear is at least GEAR_MIN_STEP taller than the one before, so every upshift drops the
	revs far enough to hear it. Runtime only: no re-bake.
]]
AudioEngine.GEAR_MIN_STEP = 1.1
local MS_PER_MPH = 0.44704

function AudioEngine.ApplyGearing(config, spec)
	local gearCount = #spec
	if gearCount < 1 then return config end
	local rpmPerSpeed = 60 / (2 * pi * config.wheelRadius)
	local redline, idle = config.redline, config.idle
	local ratios, upshiftRpms, downshiftSpeeds = {}, {}, {}
	for i = 1, gearCount do
		local gearSpec = spec[i]
		local ratio
		if i < gearCount then
			upshiftRpms[i] = math.Clamp(tonumber(gearSpec.rpm) or redline * 0.92, idle * 1.5, redline * 0.99)
			ratio = upshiftRpms[i] / (max(1, tonumber(gearSpec.mph) or 10) * MS_PER_MPH * rpmPerSpeed)
		else
			local topRpm = math.Clamp(tonumber(spec.topRpm) or redline * AudioEngine.TopGearShare(redline), idle * 1.5, redline * 0.985)
			ratio = topRpm / (config.topSpeed / 3.6 * rpmPerSpeed)
		end
		if i > 1 then ratio = min(ratio, ratios[i - 1] / AudioEngine.GEAR_MIN_STEP) end
		ratios[i] = ratio
		local downMph = tonumber(gearSpec.down)
		if i > 1 and downMph and downMph > 0 then
			-- under the speed where the gear below changes up (or it would change straight back)
			local belowUpshiftSpeed = (upshiftRpms[i - 1] or redline * 0.92) / (ratios[i - 1] * rpmPerSpeed)
			downshiftSpeeds[i] = min(downMph * MS_PER_MPH, belowUpshiftSpeed * 0.9)
		end
	end
	config.gears, config.final, config.reverse = ratios, 1, ratios[1] * 0.9
	config.shiftPlan = { up = upshiftRpms, down = downshiftSpeeds }
	return config
end

local resolveCache = setmetatable({}, { __mode = "k" })

--[[
	car: the model's entry from sh_config (wheelRadius, soundLevel, stability...)
	prof: a profile table, or nil for the car's stock preset
]]
-- a car's stock profile: its preset plus any per-car changes (car.stock, see sh_carlist.lua)
function AudioEngine.CarStockProfile(carConfig)
	local profile = AudioEngine.ProfileFromPreset(carConfig.preset or "sl65")
	if type(carConfig.stock) == "table" then
		for key, value in pairs(carConfig.stock) do profile[key] = value end
		profile = AudioEngine.SanitizeProfile(profile)
	end
	-- stock pops & bangs (sh_carlist.lua CAR_POPS): runtime only, so not part of the sound key
	if carConfig.stockPops then profile.pops = math.Clamp(carConfig.stockPops, 0, 1) end
	if carConfig.stockPopVol then profile.popVol = math.Clamp(carConfig.stockPopVol, 0, 2) end
	-- stock blow-off valve (CAR_BOV): only with a turbo
	if carConfig.stockBov ~= nil then profile.bov = (carConfig.stockBov and profile.turbo) and true or false end
	if carConfig.stockBovVol then profile.bovVol = math.Clamp(carConfig.stockBovVol, 0, 2) end
	-- a supercharged car (CAR_SUPERCHARGER) doesn't also get its preset's turbo
	if carConfig.supercharger then profile.turbo, profile.bov = false, false end
	return profile
end

function AudioEngine.ResolveProfile(carConfig, profile)
	profile = profile or AudioEngine.CarStockProfile(carConfig)
	local realism = profile.realism
	local config = {}
	for key, value in pairs(carConfig) do config[key] = value end
	config.profile = profile
	config.layout, config.pitch, config.tone = profile.layout, profile.pitch, profile.tone
	config.volume = profile.volume * (carConfig.volume or 1)
	config.idle, config.redline = profile.idle, profile.redline
	config.bands = AudioEngine.MakeBands(profile.idle, profile.redline, profile.layout == "electric" and 1.35 or nil)
	config.realism = {
		bankSpread = 1.0 * realism, cylinderVar = 0.07 * realism, cylinderTiming = 1.5 * realism, combustionVar = 0.12 * realism,
		flowNoise = 1.0 * realism, mufflerMode = 0.5 * realism, mechanical = 1.0 * realism, turboSoften = 0.6 * realism,
		tailpipe = 0.3 * realism, reverb = 0.2 - 0.05 * realism, voice = realism,
	}
	config.electric = profile.layout == "electric"
	config.turbo = (profile.turbo and not config.electric) and { whine = 1.0, blowoff = 1.0 } or nil
	config.gurgle = profile.gurgle
	config.popTone = profile.popTone
	-- the speed the car will actually reach: the profile's top speed, else the car's own
	config.topSpeed = profile.vmax > 0 and profile.vmax or (tonumber(carConfig.topSpeed) or 250)
	-- power to weight (W/kg): the car's own (server, NW2 audio_pwr), scaled by the tuned acceleration
	config.powerKg = (tonumber(carConfig.powerKg) or AudioEngine.GEAR_ACCEL.defaultWkg) * (profile.accel or 1)
	config.gears = profile.fit > 0 and AudioEngine.FitGearCount(profile.gears, config.topSpeed, carConfig.gearCount, profile.redline, config.powerKg) or profile.gears
	config.final = profile.fit > 0 and AudioEngine.FitFinal(config.gears, profile.redline, carConfig.wheelRadius, config.topSpeed, true) or profile.final
	config.reverse = profile.gears[1] * 0.9
	-- torque converter stall speed (an electric motor is direct drive)
	config.stallRpm = config.electric and profile.idle or (profile.idle + 0.27 * profile.redline)
	-- the car's own gearing (AudioEngine.CAR_GEARING), unless the profile sets its ratios by hand (fit 0)
	if type(carConfig.gearing) == "table" and profile.fit > 0 then AudioEngine.ApplyGearing(config, carConfig.gearing) end
	-- how fast it revs up and drops back in neutral (AudioEngine.CAR_REV; sh_drivetrain.lua Drivetrain.REV)
	if type(carConfig.rev) == "table" then config.revRise, config.revFall = tonumber(carConfig.rev.rise), tonumber(carConfig.rev.fall) end
	local preset = AudioEngine.EnginePreset(profile.preset)
	config.engineName = preset and preset.name or "Custom"
	-- the exhaust voice: the car's own, else its preset's (sh_presets character), else the layout's
	if type(carConfig.character) ~= "table" and preset and preset.character then config.character = preset.character end
	-- everything that changes the generated sound; cars with the same key share sounds.
	-- The turbo, blow-off valve, volumes and how often pops happen are not in it: they are
	-- played on top at runtime, so changing them never generates a new engine.
	local keyParts = { profile.layout, formatNumber(profile.pitch), formatNumber(profile.tone), profile.idle, profile.redline,
		formatNumber(realism), formatNumber(profile.gurgle), formatNumber(profile.popTone) }
	-- the car's silencer (economy cars); only in the key when set, so other keys stay as they were
	if (carConfig.muffle or 0) > 0 then keyParts[#keyParts + 1] = "m" .. formatNumber(carConfig.muffle) end
	-- the car's own exhaust voice (sh_carlist.lua character): likewise only when set
	if type(config.character) == "table" then
		local characterParts = {}
		for _, key in ipairs({ "f1", "f2", "f3", "w", "o1", "o05" }) do characterParts[#characterParts + 1] = config.character[key] and formatNumber(config.character[key]) or "" end
		keyParts[#keyParts + 1] = "c" .. table.concat(characterParts, ",")
	end
	config.soundKey = table.concat(keyParts, "_")
	config.id = config.soundKey
	-- the same engine at any redline: its rpm bands are the same sound, so a baked bank with a
	-- higher redline serves it (see cl_soundbank). Not for electric motors: their whine level
	-- follows rpm / redline.
	if not config.electric then
		table.remove(keyParts, 5)
		config.familyKey = table.concat(keyParts, "_")
	end
	return config
end

-- the car's top speed in km/h: "auto" uses the vehicle script's MaxSpeed (sent by the server)
function AudioEngine.CarTopSpeed(entity, carConfig)
	carConfig = carConfig or AudioEngine.GetCarConfig(entity)
	local topSpeed = carConfig and carConfig.topSpeed
	if topSpeed == "auto" or topSpeed == nil then
		local scriptTopSpeed = IsValid(entity) and entity:GetNW2Float("audio_vmax", 0) or 0
		return scriptTopSpeed > 0 and min(400, max(40, floor(scriptTopSpeed / 5 + 0.5) * 5)) or 250
	end
	return topSpeed
end

-- the car's power to weight in W/kg (stock horsepower over mass, sent by the server), for the gear spacing
function AudioEngine.CarPower(entity, carConfig)
	local powerToWeight = IsValid(entity) and entity:GetNW2Float("audio_pwr", 0) or 0
	if powerToWeight > 0 then return floor(powerToWeight + 0.5) end
	return carConfig and tonumber(carConfig.powerKg) or AudioEngine.GEAR_ACCEL.defaultWkg
end

-- the resolved config for a car entity, following its networked profile
function AudioEngine.GetEngineConfig(entity)
	local carConfig = AudioEngine.GetCarConfig(entity)
	if not carConfig then return nil end
	local profileString = entity:GetNW2String("audio_prof", "")
	local topSpeed, powerToWeight = AudioEngine.CarTopSpeed(entity, carConfig), AudioEngine.CarPower(entity, carConfig)
	local cached = resolveCache[entity]
	if cached and cached.profileString == profileString and cached.carConfig == carConfig and cached.topSpeed == topSpeed and cached.powerToWeight == powerToWeight then return cached.config end
	local effectiveCar = {}
	for key, value in pairs(carConfig) do effectiveCar[key] = value end
	effectiveCar.topSpeed, effectiveCar.powerKg = topSpeed, powerToWeight
	local config = AudioEngine.ResolveProfile(effectiveCar, AudioEngine.DecodeProfile(profileString))
	resolveCache[entity] = { profileString = profileString, carConfig = carConfig, topSpeed = topSpeed, powerToWeight = powerToWeight, config = config }
	return config
end
