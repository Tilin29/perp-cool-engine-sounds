--[[
	Tone Studio glue: runs after the addon's own files (bake_shim.lua, sh_*, cl_synth) in the
	page's worker. Renders an engine from a car's stock sound plus the page's changes, through
	the same E.ResolveProfile + Synth code the baker and the game use, so what the page plays is
	what a re-bake would ship. Results go to JS through callbacks (__result, __push): wasmoon
	leaks stack slots on doString return values.
]]
local E = AUDIO_ENGINE
local Synth = E.Synth
STUDIO = {}

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
			character = car.character and pick(car.character, CHAR_FIELDS) or {},
		}
	end
	table.sort(cars, function(a, b) return a.name < b.name end)
	local presets = {}
	for _, p in ipairs(E.ENGINE_PRESETS) do
		presets[#presets + 1] = { id = p.id, name = p.name, sound = pick(p, SOUND_FIELDS) }
	end
	local layouts = {}
	for _, o in ipairs(E.LAYOUT_ORDER) do layouts[#layouts + 1] = { id = o[1], name = o[2], cyl = E.LAYOUT_CYL[o[1]] } end
	__result(json({ cars = cars, presets = presets, layouts = layouts, character = Synth.CHARACTER }))
end

-- the car with the page's changes: req.car, req.sound (profile fields), req.character
local function resolve(req)
	local base = byName[req.car]
	assert(base, "unknown car " .. tostring(req.car))
	local car = {}
	for k, v in pairs(base) do car[k] = v end
	car.topSpeed = 250
	-- req.character replaces the car's own (nil keeps it, {} clears it)
	if req.character ~= nil then car.character = next(req.character) and req.character or nil end
	local prof = E.CarStockProfile(car)
	for k, v in pairs(req.sound or {}) do prof[k] = v end
	-- the same rounding and limits the game applies to a profile
	prof = E.SanitizeProfile(prof)
	return E.ResolveProfile(car, prof), prof
end

-- the firing pattern the generator uses: angle, strength and bank of every firing over 720 degrees
function STUDIO.rhythm(req)
	local cfg = resolve(req)
	local R = Synth.RealismOf(cfg)
	local iv, am, n, banks = Synth.LayoutParams(cfg.layout, R.cylVar, R.cylTiming, R.char.o1 * R.voice, R.char.o05 * R.voice)
	local ang, a = {}, 0
	for i = 1, n do ang[i] = a; a = a + iv[i] end
	__result(json({ angles = ang, amp = am, banks = banks }))
end

local function push(buf, n)
	local k = 1
	while k <= n do
		local j = math.min(n, k + 399)
		__push(table.unpack(buf, k, j))
		k = j + 1
	end
end

--[[
	req.mode "hold": a steady loop at req.rpm / req.thr (what the game cross-fades between).
	req.mode "rev":  idle, a full-throttle pull to near redline, a lift (the off-throttle
	                 burble) and back to idle, the way you'd blip it standing next to the car.
]]
function STUDIO.render(req)
	local cfg, prof = resolve(req)
	local sr = req.sr or 44100
	local out, n, loop
	if req.mode == "hold" then
		local rpm = math.max(cfg.idle, math.min(cfg.redline, req.rpm or 3000))
		out, n = Synth.RenderSteadyLoop(cfg, sr, rpm, req.thr or 1, nil, 2.0)
		loop = true
	else
		local g, ch = Synth.NewEngine(cfg, sr)
		g.allowPops = false
		g.on = true; g.gain = 1
		g.rpm, g.tRpm, g.thr, g.tThr = cfg.idle, cfg.idle, 0, 0
		local top = cfg.redline * 0.95
		local warm = math.floor(sr * 0.8)
		local total = warm + math.floor(sr * 7.5)
		out = Synth.RenderControlled(g, ch, {
			skip = warm,
			control = function(t)
				t = t - 0.8
				if t < 0.7 then return { tRpm = cfg.idle, tThr = 0, on = true } end
				if t < 3.6 then
					-- the revs climb with the throttle like a free-revving engine: slower near the top
					local x = (t - 0.7) / 2.9
					return { tRpm = cfg.idle + (top - cfg.idle) * (1 - (1 - x) ^ 1.6), tThr = 1, on = true }
				end
				if t < 6.2 then
					local x = (t - 3.6) / 2.6
					return { tRpm = top + (cfg.idle - top) * (1 - (1 - x) ^ 2.2), tThr = 0, on = true }
				end
				return { tRpm = cfg.idle, tThr = 0, on = true }
			end,
		}, total)
		n = #out
		loop = false
	end
	__genBegin("render", sr, loop and 0 or -1, n)
	push(out, n)
	__genEnd("render")
	__result(json({ key = cfg.soundKey, profile = pick(prof, SOUND_FIELDS), redline = cfg.redline, idle = cfg.idle,
		cyl = E.LAYOUT_CYL[cfg.layout] or 4, char = Synth.RealismOf(cfg).char }))
end
