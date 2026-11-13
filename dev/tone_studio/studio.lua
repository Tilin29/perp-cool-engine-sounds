--[[
	Tone Studio glue: runs after the addon's own files (bake_shim.lua, sh_*, cl_synth) in the
	page's worker. Runs an engine live from a car's stock sound plus the page's changes, through
	the same E.ResolveProfile + Synth code the baker and the game use, so what the page plays is
	the synth a re-bake would ship. Results go to JS through callbacks (__result, __push): wasmoon
	leaks stack slots on doString return values.
]]
local E = AUDIO_ENGINE
local Synth = E.Synth
local DT = E.Drivetrain
STUDIO = {}
LIVE = {}

-- the incremental collector's pauses reached 120 ms, generational stays under 20: the stream's
-- buffer only has to cover that
collectgarbage("generational")

local SOUND_FIELDS = { "layout", "pitch", "tone", "idle", "redline", "realism", "gurgle", "popTone" }
local CHAR_FIELDS = { "f1", "f2", "f3", "w", "o1", "o05" }

local function json(v)
	local t = type(v)
	if t == "table" then
		if #v > 0 or next(v) == nil then
			local o = {}
			for i = 1, #v do o[i] = json(v[i]) end
			return "[" .. table.concat(o, ",") .. "]"
		end
		local o = {}
		for k, x in pairs(v) do
			if type(x) ~= "function" then o[#o + 1] = string.format("%q", tostring(k)) .. ":" .. json(x) end
		end
		return "{" .. table.concat(o, ",") .. "}"
	elseif t == "string" then
		return (string.format("%q", v):gsub("\\\n", "\\n"))
	elseif t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then return "0" end
		return string.format("%.10g", v)
	elseif t == "boolean" then
		return v and "true" or "false"
	end
	return "null"
end

local byName = {}
for _, car in pairs(E.Cars) do
	if car.name then byName[car.name] = car end
end

local function pick(t, fields)
	local o = {}
	for _, k in ipairs(fields) do o[k] = t[k] end
	return o
end

-- everything the page needs: cars with their stock sound, presets, layouts, engine-type voices
function STUDIO.data()
	local cars = {}
	for name, car in pairs(byName) do
		local prof = E.CarStockProfile(car)
		cars[#cars + 1] = {
			name = name, preset = car.preset, economy = car.economy or false, muffle = car.muffle or 0,
			stock = pick(prof, SOUND_FIELDS),
			character = pick(car.character or (E.EnginePreset(car.preset) or {}).character or {}, CHAR_FIELDS),
		}
	end
	table.sort(cars, function(a, b) return a.name < b.name end)
	local presets = {}
	for _, p in ipairs(E.ENGINE_PRESETS) do
		presets[#presets + 1] = { id = p.id, name = p.name, sound = pick(p, SOUND_FIELDS), character = pick(p.character or {}, CHAR_FIELDS) }
	end
	local layouts = {}
	for _, o in ipairs(E.LAYOUT_ORDER) do layouts[#layouts + 1] = { id = o[1], name = o[2], cyl = E.LAYOUT_CYL[o[1]] } end
	local shapes = {}
	for id, L in pairs(Synth.LAYOUTS) do shapes[id] = { angles = L.angles, amp = L.amp, banks = L.banks } end
	__result(json({ cars = cars, presets = presets, layouts = layouts, shapes = shapes, character = Synth.CHARACTER }))
end

-- a firing pattern drawn on the page (req.custom): an engine layout like those in cl_synth,
-- with the voice of the layout it started from
local function defineCustom(c)
	Synth.LAYOUTS.custom = { angles = c.angles, amp = c.amp, banks = c.banks }
	Synth.CHARACTER.custom = Synth.CHARACTER[c.base] or Synth.CHARACTER.i4
	E.LAYOUT_CYL.custom = #c.angles
end

-- the car with the page's changes: req.car, req.sound (profile fields, and muffle: the car's
-- silencer), req.character, req.custom
local function resolve(req)
	local base = byName[req.car]
	assert(base, "unknown car " .. tostring(req.car))
	local car = {}
	for k, v in pairs(base) do car[k] = v end
	car.topSpeed = 250
	-- req.character replaces the car's own (nil keeps it, {} clears it)
	if req.character ~= nil then car.character = next(req.character) and req.character or nil end
	if req.custom then defineCustom(req.custom) end
	local sound = req.sound or {}
	if sound.muffle then car.muffle = sound.muffle end
	local prof = E.CarStockProfile(car)
	for k, v in pairs(sound) do prof[k] = v end
	-- the same rounding and limits the game applies to a profile
	prof = E.SanitizeProfile(prof)
	return E.ResolveProfile(car, prof), prof
end

-- the firing pattern the generator uses: angle, strength and bank of every firing over 720 degrees
function STUDIO.rhythm(req)
	local cfg = resolve(req)
	local R = Synth.RealismOf(cfg)
	local iv, am, n, banks = Synth.LayoutParams(cfg.layout, R.cylinderVariation, R.cylinderTiming, R.character.o1 * R.voice, R.character.o05 * R.voice)
	local ang, a = {}, 0
	for i = 1, n do ang[i] = a; a = a + iv[i] end
	__result(json({ angles = ang, amp = am, banks = banks }))
end

--[[
	The live engine: one generator and exhaust chain that keep running while the page retunes them
	and works the pedals. Each step renders one control tick (1/60 s) through the same
	Synth.RenderControlled the baker uses, and the game's own E.Drivetrain drives the revs.
]]
local SR, CHUNK = 44100, 735
local live

-- what NewGen / NewChain work out from a profile. The running engine takes these on and keeps
-- everything else (firing phase, filter and resonator state), so a change lands without a restart
local GEN_FIELDS = { "pitch", "tone", "cylinderCount", "firingIntervals", "firingStrengths", "firingBanks", "redline", "realism", "electric" }
local CHAIN_FIELDS = { "drive", "driveNorm", "tailWet", "reverbWet", "muffleScale", "electric" }
local CHAIN_FILTERS = { "bodyPeak", "lowShelf", "topLowpass", "highShelf" }

function LIVE.config(req)
	local cfg = resolve(req)
	local g, ch = Synth.NewEngine(cfg, SR)
	if live then
		local lg, lc = live.g, live.ch
		for _, k in ipairs(GEN_FIELDS) do lg[k] = g[k] end
		lg.firingIndex = lg.firingIndex % #g.firingIntervals
		lg.evToneOrder = nil
		for _, k in ipairs(CHAIN_FIELDS) do lc[k] = ch[k] end
		for _, k in ipairs(CHAIN_FILTERS) do
			for i = 1, 5 do lc[k][i] = ch[k][i] end
		end
	else
		g.allowPops = false
		g.ignitionOn = true; g.gain = 1
		g.rpm, g.targetRpm = cfg.idle, cfg.idle
		local st = DT.New()
		DT.SkipStart(st, cfg)
		live = { g = g, ch = ch, st = st, v = 0, t = 0, ref = 0.06, fx = {}, msg = {},
			inp = { mode = "rev", rpm = 3000, thr = 1, fwd = false, back = false } }
		live.ctl = { control = function() return live.msg end }
	end
	live.cfg = cfg
	live.emotion = E.CAR_EMOTION[req.car] and true or false
	__result(json({ key = cfg.soundKey, redline = cfg.redline, idle = cfg.idle, cyl = E.LAYOUT_CYL[cfg.layout] or 4 }))
end

-- req: any of mode ("rev", "drive", "sweep", "hold"), rpm, thr, fwd, back
function LIVE.input(req)
	if req.mode and req.mode ~= live.inp.mode then live.t = 0; live.v = 0 end
	for k, v in pairs(req) do live.inp[k] = v end
end

function LIVE.ignition()
	local st = live.st
	if st.on then
		DT.Stop(st)
	else
		live.g.gain = 0
		DT.Start(st, live.emotion)
	end
end

-- a free rev like a blip beside the car: idle, a full-throttle pull, a lift, idle again (7.5 s)
local function sweep(L, dt)
	local cfg = L.cfg
	local top = cfg.redline * 0.95
	L.t = (L.t + dt) % 7.5
	local t = L.t
	if t < 0.7 then return cfg.idle, 0 end
	if t < 3.6 then return cfg.idle + (top - cfg.idle) * (1 - (1 - (t - 0.7) / 2.9) ^ 1.6), 1 end
	if t < 6.2 then return top + (cfg.idle - top) * (1 - (1 - (t - 3.6) / 2.6) ^ 2.2), 0 end
	return cfg.idle, 0
end

-- a plain car for the gearbox to work against: pulls until drag meets it at the top speed
local function roll(L, dt)
	local v, top, inp = L.v, L.cfg.topSpeed / 3.6, L.inp
	local a = -0.4 - 1.5 * (v / top) ^ 2
	if inp.back then a = -9 elseif inp.fwd then a = 7 * (1 - (v / top) ^ 2) end
	L.v = math.max(0, v + a * dt)
end

local function control(L, dt)
	local st, cfg, inp, m = L.st, L.cfg, L.inp, L.msg
	if st.on and st.phase ~= "run" then
		DT.StartSequence(st, cfg, dt)
	elseif st.on and (inp.mode == "hold" or inp.mode == "sweep") then
		local rpm, thr = inp.rpm, inp.thr
		if inp.mode == "sweep" then rpm, thr = sweep(L, dt) end
		st.rpm, st.soundThrottle, st.fuelCut, st.crankMode, st.gear = rpm, thr, false, 0, 0
	elseif inp.mode == "drive" then
		DT.Step(st, cfg, dt, { forward = inp.fwd, backward = inp.back and L.v > 0.7, speed = L.v })
		roll(L, dt)
	else
		DT.Step(st, cfg, dt, { forward = inp.fwd, handbrake = true, speed = 0 })
	end
	m.targetRpm, m.targetThrottle, m.fuelCut, m.crankMode, m.ignitionOn = st.rpm, st.soundThrottle, st.fuelCut, st.crankMode, st.on or st.rpm > 25
end

-- a pop or bang on top of the engine, at the level the sound bank gives it (cl_soundbank) and the
-- 0.7 the game plays it at. L.ref stands in for the bank's loudest band
function LIVE.pop(kind)
	local L = live
	if L.cfg.electric then return end
	local big = kind == "bang"
	local buf = Synth.RenderBackfire(L.cfg, SR, math.random(1, 1000000), kind)
	local s2, m = 0, math.min(#buf, math.floor(SR * (big and 0.05 or 0.02)))
	for i = 1, m do s2 = s2 + buf[i] * buf[i] end
	local gain = 0.7 * L.ref * 10 ^ ((big and 3 or -4) / 20) / (math.sqrt(s2 / m) + 1e-9)
	L.fx[#L.fx + 1] = { buf = buf, pos = 1, n = #buf, gain = gain }
end

function LIVE.step()
	local L = live
	control(L, CHUNK / SR)
	local out = Synth.RenderControlled(L.g, L.ch, L.ctl, CHUNK)
	local st = L.st
	if st.soundThrottle > 0.7 then
		local s2 = 0
		for i = 1, CHUNK do s2 = s2 + out[i] * out[i] end
		L.ref = math.max(L.ref * 0.9995, math.sqrt(s2 / CHUNK))
	end
	for i = #L.fx, 1, -1 do
		local f = L.fx[i]
		for k = 1, math.min(CHUNK, f.n - f.pos + 1) do out[k] = out[k] + f.buf[f.pos + k - 1] * f.gain end
		f.pos = f.pos + CHUNK
		if f.pos > f.n then table.remove(L.fx, i) end
	end
	__live(st.rpm, st.gear, L.v * 3.6, st.soundThrottle, st.on and st.phase == "run" and 1 or 0, L.cfg.electric and 1 or 0)
	__push(table.unpack(out, 1, 400))
	__push(table.unpack(out, 401, CHUNK))
end
