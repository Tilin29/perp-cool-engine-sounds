--[[
	Audio Engine - engine profiles (shared)

	A profile is everything the Rev Bench page let you change: engine layout, pitch, exhaust
	tone, volume, idle, redline, gear ratios and final drive, plus realism and turbo. Each
	car carries its own profile in a networked string, so everyone hears the same engine.
	An empty string means the car's stock preset.
]]

AUDIO_ENGINE = AUDIO_ENGINE or {}
local E = AUDIO_ENGINE

local min, max, floor, pi = math.min, math.max, math.floor, math.pi

E.LAYOUT_ORDER = {
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
E.LAYOUT_CYL = { single = 1, vtwin = 2, ptwin = 2, triple = 3, i4 = 4, boxer = 4, i5 = 5, i6 = 6, v6odd = 6, v8cross = 8, v8flat = 8, v10 = 10, v12 = 12,
	v6 = 6, flat6 = 6, flat12 = 12, w16 = 16, rotary2 = 4, rotary3 = 6, electric = 1 }

E.GEAR_PRESETS = {
	{ id = "amg5",    name = "AMG 5-speed auto", gears = { 3.59, 2.19, 1.41, 1.00, 0.83 }, final = 2.82 },
	{ id = "road",    name = "Road 6-speed",     gears = { 3.60, 2.10, 1.45, 1.10, 0.90, 0.76 }, final = 3.90 },
	{ id = "close",   name = "Close-ratio 6",    gears = { 3.00, 2.10, 1.60, 1.30, 1.10, 0.95 }, final = 4.30 },
	{ id = "seven",   name = "7-speed auto",     gears = { 4.38, 2.86, 1.92, 1.37, 1.00, 0.82, 0.73 }, final = 2.65 },
	{ id = "eco",     name = "Economy 5",        gears = { 3.45, 1.94, 1.29, 0.97, 0.78 }, final = 3.65 },
	{ id = "classic", name = "Classic 4",        gears = { 2.97, 1.84, 1.31, 1.00 }, final = 3.70 },
	{ id = "ev",      name = "Single-speed (electric)", gears = { 1.00 }, final = 9.00 },
}
local function gearPreset(id)
	for _, g in ipairs(E.GEAR_PRESETS) do if g.id == id then return g end end
	return E.GEAR_PRESETS[1]
end
E.GearPreset = gearPreset

--[[ Engine presets. topSpeed: the gearing is fitted so top gear reaches redline there. ]]
-- One preset per engine type in the game (see sh_carlist.lua for which car uses which),
-- plus the SL65's own engine and the original Rev Bench sound.
E.ENGINE_PRESETS = {
	{ id = "sl65",   name = "SL65 AMG · 6.0 V12 biturbo",               layout = "v12",     pitch = 1.00, tone = 0.40, idle = 700,  redline = 6000,  realism = 1, turbo = true,  bov = true,  pops = 0.1,  gurgle = 0.35, popTone = 0.15, gearbox = "amg5" },
	-- V12 / flat-12 / W16
	{ id = "v12na",  name = "V12",                                      layout = "v12",     pitch = 1.00, tone = 0.60, idle = 1000, redline = 8000,  realism = 1, turbo = false, bov = false, pops = 0.3,  gurgle = 0.25, popTone = 0.3,  gearbox = "seven" },
	{ id = "v12t",   name = "V12 · turbo",                              layout = "v12",     pitch = 1.00, tone = 0.50, idle = 900,  redline = 8000,  realism = 1, turbo = true,  bov = true,  pops = 0.3,  gurgle = 0.25, popTone = 0.25, gearbox = "close" },
	{ id = "f12",    name = "Flat-12 (180° V12)",                       layout = "flat12",  pitch = 1.00, tone = 0.60, idle = 1000, redline = 7200,  realism = 1, turbo = false, bov = false, pops = 0.3,  gurgle = 0.3,  popTone = 0.3,  gearbox = "close" },
	{ id = "w16",    name = "W16 · quad-turbo",                         layout = "w16",     pitch = 1.00, tone = 0.45, idle = 750,  redline = 6600,  realism = 1, turbo = true,  bov = true,  pops = 0.1,  gurgle = 0.2,  popTone = 0.2,  gearbox = "seven" },
	-- V10
	{ id = "v10",    name = "V10",                                      layout = "v10",     pitch = 1.00, tone = 0.65, idle = 950,  redline = 8500,  realism = 1, turbo = false, bov = false, pops = 0.5,  gurgle = 0.3,  popTone = 0.4,  gearbox = "close" },
	{ id = "v10l",   name = "V10 · big-block (Viper, Ram SRT-10)",      layout = "v10",     pitch = 0.90, tone = 0.55, idle = 750,  redline = 6000,  realism = 1, turbo = false, bov = false, pops = 0.3,  gurgle = 0.45, popTone = 0.3,  gearbox = "road" },
	-- V8
	{ id = "v8x",    name = "V8 · crossplane (muscle, trucks)",         layout = "v8cross", pitch = 0.95, tone = 0.65, idle = 700,  redline = 6000,  realism = 1, turbo = false, bov = false, pops = 0.4,  gurgle = 0.6,  popTone = 0.25, gearbox = "road" },
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
	{ id = "i4",     name = "Inline-4",                                 layout = "i4",      pitch = 1.00, tone = 0.40, idle = 800,  redline = 6200,  realism = 1, turbo = false, bov = false, pops = 0.0,  gurgle = 0.1,  popTone = 0.2,  gearbox = "eco" },
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
function E.EnginePreset(id)
	for _, p in ipairs(E.ENGINE_PRESETS) do if p.id == id then return p end end
	return nil
end

-- a full, editable profile from a preset (performance at the car's stock values)
function E.ProfileFromPreset(id)
	local p = E.EnginePreset(id) or E.ENGINE_PRESETS[1]
	local g = gearPreset(p.gearbox)
	local gears = {}
	for i, r in ipairs(g.gears) do gears[i] = r end
	return {
		preset = p.id, layout = p.layout, pitch = p.pitch, tone = p.tone, volume = 1,
		idle = p.idle, redline = p.redline, realism = p.realism, turbo = p.turbo,
		gears = gears, final = g.final, fit = 1,
		accel = 1, vmax = 0, pops = p.pops or 0, bov = p.bov and true or false,
		gurgle = p.gurgle or 0, popVol = 1, popTone = p.popTone or 0.2,
		turboVol = 1, bovVol = 1,
	}
end

---------------------------------------------------------------------------
-- validation (the server runs this on everything a client sends)
---------------------------------------------------------------------------
local function clampRound(x, a, b, step)
	x = tonumber(x) or a
	x = min(b, max(a, x))
	return floor(x / step + 0.5) * step
end

function E.SanitizeProfile(p)
	local o = {}
	o.preset = (type(p.preset) == "string" and p.preset:match("^[%w_]+$") and #p.preset <= 16) and p.preset or "custom"
	o.layout = E.LAYOUT_CYL[p.layout] and p.layout or "i4"
	o.pitch = clampRound(p.pitch, 0.5, 2, 0.05)
	o.tone = clampRound(p.tone, 0, 1, 0.05)
	o.volume = clampRound(p.volume, 0, 1.5, 0.05)
	o.idle = clampRound(p.idle, 500, 1500, 25)
	o.redline = clampRound(p.redline, max(3500, o.idle * 3), o.layout == "electric" and 16000 or 12000, 100)
	o.realism = clampRound(p.realism, 0, 1, 0.1)
	o.turbo = p.turbo and true or false
	o.gears = {}
	local src = type(p.gears) == "table" and p.gears or gearPreset("road").gears
	for i = 1, min(8, #src) do o.gears[i] = clampRound(src[i], 0.3, 8, 0.01) end
	if #o.gears < 1 then o.gears[1] = 1 end
	o.final = clampRound(p.final, 2, 6, 0.01)
	o.fit = (tonumber(p.fit) or 0) > 0 and 1 or 0
	-- performance: acceleration (engine power multiplier) and top speed (km/h, 0 = car's own)
	o.accel = clampRound(p.accel or 1, 0.5, 2.5, 0.05)
	o.vmax = (tonumber(p.vmax) or 0) > 0 and clampRound(p.vmax, 80, 450, 5) or 0
	-- pops & bangs: how often (0 = off) and how loud; the turbo blow-off valve
	o.pops = clampRound(p.pops or 0, 0, 1, 0.05)
	o.popVol = clampRound(p.popVol or 1, 0, 2, 0.05)
	o.bov = (p.bov == nil and o.turbo) or (p.bov and true or false)
	-- turbo whistle and blow-off valve volume (1 = default, up to 200%)
	o.turboVol = clampRound(p.turboVol or 1, 0, 2, 0.05)
	o.bovVol = clampRound(p.bovVol or 1, 0, 2, 0.05)
	-- gurgle: ragged, burbly combustion off throttle
	o.gurgle = clampRound(p.gurgle or 0, 0, 1, 0.05)
	o.popTone = clampRound(p.popTone or 0.2, 0, 1, 0.05)
	-- an electric motor has no exhaust: no turbo, pops or burble
	if o.layout == "electric" then
		o.turbo, o.bov, o.pops, o.gurgle = false, false, 0, 0
		o.idle = min(o.idle, 600)
	end
	return o
end

-- compact text form for networking:
-- preset|layout|pitch|tone|vol|idle|red|realism|turbo|g1,g2,..|final|fit|accel|vmax|pops|bov|gurgle|popVol|popTone|turboVol|bovVol
local function fmt(x) return (string.format("%.2f", x):gsub("0+$", ""):gsub("%.$", "")) end
function E.EncodeProfile(p)
	p = E.SanitizeProfile(p)
	local g = {}
	for i, r in ipairs(p.gears) do g[i] = fmt(r) end
	return table.concat({
		p.preset, p.layout, fmt(p.pitch), fmt(p.tone), fmt(p.volume), tostring(p.idle), tostring(p.redline),
		fmt(p.realism), p.turbo and "1" or "0", table.concat(g, ","), fmt(p.final), tostring(p.fit),
		fmt(p.accel), tostring(p.vmax), fmt(p.pops), p.bov and "1" or "0", fmt(p.gurgle), fmt(p.popVol), fmt(p.popTone),
		fmt(p.turboVol), fmt(p.bovVol),
	}, "|")
end

local function split(s, sep)
	local t = {}
	local start = 1
	while true do
		local i = string.find(s, sep, start, true)
		if not i then t[#t + 1] = s:sub(start); break end
		t[#t + 1] = s:sub(start, i - 1)
		start = i + 1
	end
	return t
end

function E.DecodeProfile(s)
	if type(s) ~= "string" or s == "" or #s > 200 then return nil end
	local f = split(s, "|")
	if #f < 12 then return nil end
	local gears = {}
	for _, v in ipairs(split(f[10], ",")) do gears[#gears + 1] = tonumber(v) end
	-- blow-off valve: "0" must stay off (older strings without the field default to on with a turbo)
	local bov = nil
	if f[16] ~= nil and f[16] ~= "" then bov = (f[16] == "1") end
	return E.SanitizeProfile({
		preset = f[1], layout = f[2], pitch = f[3], tone = f[4], volume = f[5], idle = f[6], redline = f[7],
		realism = f[8], turbo = f[9] == "1", gears = gears, final = f[11], fit = f[12],
		accel = f[13], vmax = f[14], pops = f[15], bov = bov,
		gurgle = f[17], popVol = f[18], popTone = f[19], turboVol = f[20], bovVol = f[21],
	})
end

---------------------------------------------------------------------------
-- profile -> the config the synth, sound bank and rpm model use
---------------------------------------------------------------------------
-- rpm points that get their own generated loop: ~1.26x apart from just above idle to redline
-- (an electric motor's whine is a few pure tones that pitch-shift cleanly: fewer, wider bands)
function E.MakeBands(idle, redline, step)
	step = step or 1.26
	local lo = idle * 1.07
	local n = math.max(4, math.ceil(math.log(redline / lo) / math.log(step)) + 1)
	local r = (redline / lo) ^ (1 / (n - 1))
	local b = {}
	for i = 1, n do b[i] = floor(lo * r ^ (i - 1) / 10 + 0.5) * 10 end
	return b
end

-- final drive so top gear reaches redline at the given top speed
function E.FitFinal(gears, redline, wheelRadius, topKmh)
	local K = 60 / (2 * pi * wheelRadius)
	return redline * 0.97 / ((topKmh / 3.6) * K * gears[#gears])
end

local resolveCache = setmetatable({}, { __mode = "k" })

--[[
	car: the model's entry from sh_config (wheelRadius, soundLevel, stability...)
	prof: a profile table, or nil for the car's stock preset
]]
-- a car's stock profile: its preset plus any per-car changes (car.stock, see sh_carlist.lua)
function E.CarStockProfile(car)
	local p = E.ProfileFromPreset(car.preset or "sl65")
	if type(car.stock) == "table" then
		for k, v in pairs(car.stock) do p[k] = v end
		p = E.SanitizeProfile(p)
	end
	-- stock pops & bangs (sh_carlist.lua CAR_POPS): runtime only, so not part of the sound key
	if car.stockPops then p.pops = math.Clamp(car.stockPops, 0, 1) end
	if car.stockPopVol then p.popVol = math.Clamp(car.stockPopVol, 0, 2) end
	-- stock blow-off valve (CAR_BOV): only with a turbo
	if car.stockBov ~= nil then p.bov = (car.stockBov and p.turbo) and true or false end
	if car.stockBovVol then p.bovVol = math.Clamp(car.stockBovVol, 0, 2) end
	return p
end

function E.ResolveProfile(car, prof)
	prof = prof or E.CarStockProfile(car)
	local r = prof.realism
	local cfg = {}
	for k, v in pairs(car) do cfg[k] = v end
	cfg.profile = prof
	cfg.layout, cfg.pitch, cfg.tone = prof.layout, prof.pitch, prof.tone
	cfg.volume = prof.volume * (car.volume or 1)
	cfg.idle, cfg.redline = prof.idle, prof.redline
	cfg.bands = E.MakeBands(prof.idle, prof.redline, prof.layout == "electric" and 1.7 or nil)
	cfg.realism = {
		bankSpread = 1.0 * r, cylinderVar = 0.07 * r, cylinderTiming = 1.5 * r, combustionVar = 0.12 * r,
		flowNoise = 1.0 * r, mufflerMode = 0.5 * r, mechanical = 1.0 * r, turboSoften = 0.6 * r,
		tailpipe = 0.3 * r, reverb = 0.2 - 0.05 * r, voice = r,
	}
	cfg.electric = prof.layout == "electric"
	cfg.turbo = (prof.turbo and not cfg.electric) and { whine = 1.0, blowoff = 1.0 } or nil
	cfg.gurgle = prof.gurgle
	cfg.popTone = prof.popTone
	cfg.gears = prof.gears
	-- the speed the car will actually reach: the profile's top speed, else the car's own
	cfg.topSpeed = prof.vmax > 0 and prof.vmax or (tonumber(car.topSpeed) or 250)
	cfg.final = prof.fit > 0 and E.FitFinal(prof.gears, prof.redline, car.wheelRadius, cfg.topSpeed) or prof.final
	cfg.reverse = prof.gears[1] * 0.9
	-- torque converter stall speed (an electric motor is direct drive)
	cfg.stallRpm = cfg.electric and prof.idle or (prof.idle + 0.27 * prof.redline)
	local p = E.EnginePreset(prof.preset)
	cfg.engineName = p and p.name or "Custom"
	-- everything that changes the generated sound; cars with the same key share sounds.
	-- The turbo, blow-off valve, volumes and how often pops happen are not in it: they are
	-- played on top at runtime, so changing them never generates a new engine.
	local key = { prof.layout, fmt(prof.pitch), fmt(prof.tone), prof.idle, prof.redline,
		fmt(r), fmt(prof.gurgle), fmt(prof.popTone) }
	-- the car's silencer (economy cars); only in the key when set, so other keys stay as they were
	if (car.muffle or 0) > 0 then key[#key + 1] = "m" .. fmt(car.muffle) end
	cfg.soundKey = table.concat(key, "_")
	cfg.id = cfg.soundKey
	-- the same engine at any redline: its rpm bands are the same sound, so a baked bank with a
	-- higher redline serves it (see cl_soundbank). Not for electric motors: their whine level
	-- follows rpm / redline.
	if not cfg.electric then
		table.remove(key, 5)
		cfg.familyKey = table.concat(key, "_")
	end
	return cfg
end

-- the car's top speed in km/h: "auto" uses the vehicle script's MaxSpeed (sent by the server)
function E.CarTopSpeed(ent, car)
	car = car or E.GetCarConfig(ent)
	local t = car and car.topSpeed
	if t == "auto" or t == nil then
		local v = IsValid(ent) and ent:GetNW2Float("audio_vmax", 0) or 0
		return v > 0 and min(400, max(80, floor(v / 5 + 0.5) * 5)) or 250
	end
	return t
end

-- the resolved config for a car entity, following its networked profile
function E.GetEngineConfig(ent)
	local car = E.GetCarConfig(ent)
	if not car then return nil end
	local s = ent:GetNW2String("audio_prof", "")
	local top = E.CarTopSpeed(ent, car)
	local c = resolveCache[ent]
	if c and c.str == s and c.car == car and c.top == top then return c.cfg end
	local carEff = {}
	for k, v in pairs(car) do carEff[k] = v end
	carEff.topSpeed = top
	local cfg = E.ResolveProfile(carEff, E.DecodeProfile(s))
	resolveCache[ent] = { str = s, car = car, top = top, cfg = cfg }
	return cfg
end
