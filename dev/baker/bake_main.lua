--[[
	Baker driver: renders every registered car's stock engine (plus the shared road / wind /
	turbo bank) through the addon's own cl_soundbank build, and describes each bank for
	lua/audio_engine/cl_baked.lua. bake.js writes the WAVs as sound.Generate hands them over.
]]
local E = PerpAudioEngine
local Bank = E.Bank
BAKE = {}

local function fnv(s)
	local h = 2166136261
	for i = 1, #s do h = ((h ~ s:byte(i)) * 16777619) & 0xFFFFFFFF end
	return string.format("%08x", h)
end

-- every distinct stock engine family (the same engine at any redline, see cfg.familyKey), with
-- the cars that use it. Each family is baked once, at its highest redline.
function BAKE.list(version)
	local byFam, fams = {}, {}
	for _, car in pairs(E.Cars) do
		local cfg = E.ResolveProfile(car)
		-- the game (LuaJIT) must build the same key: idle / redline have to print as integers
		assert(not cfg.id:find("%.0_") and not cfg.id:find("%d%.%d*0_"), "non-canonical sound key " .. cfg.id)
		local fk = cfg.familyKey or cfg.id
		local e = byFam[fk]
		if not e then
			e = { family = cfg.familyKey, cars = {}, redlines = {} }
			byFam[fk] = e
			fams[#fams + 1] = fk
		end
		if not e.cfg or cfg.redline > e.cfg.redline then e.cfg = cfg end
		e.redlines[cfg.redline] = true
		e.cars[#e.cars + 1] = car.name or car.model
	end
	BAKE.items, BAKE.families = {}, {}
	for _, fk in ipairs(fams) do
		local e = byFam[fk]
		local cfg = e.cfg
		e.key = cfg.id
		-- readable folder: <preset>_<redline>_<hash>. Cars that share an engine share the folder;
		-- the hash (sound key + synth version) keeps a re-bake from reusing a cached file name
		local dir = string.format("%s_%d_%s", cfg.profile.preset, cfg.redline, fnv(cfg.id .. "|" .. version):sub(1, 6))
		e.dir = dir:lower():gsub("[^%w_]", "_")
		local rl = {}
		for r in pairs(e.redlines) do rl[#rl + 1] = r end
		table.sort(rl)
		e.redlines = rl
		table.sort(e.cars)
		BAKE.items[#BAKE.items + 1] = e
		if e.family then BAKE.families[e.family] = e.key end
	end
	table.sort(BAKE.items, function(a, b) return a.key < b.key end)
	return #BAKE.items
end

function BAKE.info(i)
	local e = BAKE.items[i]
	-- one string: wasmoon leaks stack slots on multiple return values
	return table.concat({ e.dir, e.cfg.engineName or "?", #e.cars, table.concat(e.cars, ", "),
		e.cfg.electric and "1" or "0", e.key }, "\t")
end

local function run(b)
	while b.co and coroutine.status(b.co) ~= "dead" do
		local ok, err = coroutine.resume(b.co)
		if not ok then error(err) end
	end
	b.co = nil
end

local function stem(b, name) return (name:sub(#b.prefix + 1)) end

-- the bank's prefix is set to "<dir>/" so every generated name is its file path
function BAKE.bake(i, sr)
	local e = BAKE.items[i]
	CV.audio_engine_samplerate.v = tostring(sr)
	local b = Bank.Build(e.cfg)
	b.prefix = e.dir .. "/"
	b.startRedlines = e.redlines
	run(b)
	assert(b.ready, "bank did not finish")
	local m = { dir = e.dir, sr = b.sr, cyl = b.cyl, limitedDb = b.limitedDb, cars = e.cars, engine = e.cfg.engineName }
	if #e.redlines > 1 then m.redlines = e.redlines end
	if next(b.startEmoAt) then
		m.startEmoAt = {}
		for fk, s in pairs(b.startEmoAt) do m.startEmoAt[fk] = { fadeAt = s.fadeAt, dur = s.dur } end
	end
	m.layers = {}
	m.trims = {}
	for k, L in ipairs(b.layers) do m.layers[k], m.trims[k] = L.rpm, L.trim or 1 end
	m.limiter = b.limiter.rpm
	m.start = { fadeAt = b.start.fadeAt, dur = b.start.dur }
	m.startEmo = { fadeAt = b.startEmo.fadeAt, dur = b.startEmo.dur }
	m.stop = { dur = b.stop.dur }
	m.pops, m.bangs = #b.pops, #b.bangs
	m.peak = {}
	for name, pk in pairs(b.peak) do m.peak[stem(b, name)] = pk end
	e.meta = m
	Bank.list[e.cfg.id] = nil
	return #b.layers
end

function BAKE.bakeEnv(version)
	local b = Bank.GetEnv()
	b.prefix = "env_" .. fnv("env|" .. version) .. "/"
	run(b)
	local m = { dir = b.prefix:sub(1, -2), sr = b.sr, peak = {} }
	for k, pk in pairs(b.peak) do
		if not k:find("/", 1, true) then m.peak[k] = pk end
	end
	BAKE.env = m
	return m.dir
end

-- Lua source of cl_baked.lua, keys sorted so a re-bake gives a clean diff
local function ser(v, ind)
	local t = type(v)
	if t == "number" then
		if math.type(v) == "integer" then return tostring(v) end
		return (string.format("%.6g", v))
	elseif t == "string" then
		return string.format("%q", v)
	elseif t == "boolean" then
		return tostring(v)
	end
	local n = #v
	local parts = {}
	if n > 0 then
		for k = 1, n do parts[k] = ser(v[k], ind) end
		return "{ " .. table.concat(parts, ", ") .. " }"
	end
	local ks = {}
	for k in pairs(v) do ks[#ks + 1] = k end
	table.sort(ks)
	local pad = ind .. "\t"
	for _, k in ipairs(ks) do
		local key = k:match("^[%a_][%w_]*$") and k or ("[" .. string.format("%q", k) .. "]")
		parts[#parts + 1] = pad .. key .. " = " .. ser(v[k], pad) .. ","
	end
	return "{\n" .. table.concat(parts, "\n") .. "\n" .. ind .. "}"
end

-- manifest pieces, so parallel workers can each hand theirs back
function BAKE.entry(i)
	local e = BAKE.items[i]
	return "\t[" .. string.format("%q", e.key) .. "] = " .. ser(e.meta, "\t") .. ","
end

function BAKE.envEntry() return "E.BAKED_ENV = " .. ser(BAKE.env, "") end

-- family key -> the baked sound key that serves it
function BAKE.familyEntry() return "E.BAKED_FAMILY = " .. ser(BAKE.families, "") .. "\n" end

function BAKE.header(version)
	local L = {
		"--[[",
		"\tAudio Engine - pre-generated engine sounds (client). GENERATED by dev/baker/bake.js: don't edit.",
		"",
		"\tOne entry per stock engine family (by sound key, see E.ResolveProfile): the same engine at",
		"\tseveral redlines is baked once, at the highest, and E.BAKED_FAMILY points the others at it.",
		"\tThe WAVs live in sound/audio_engine/<dir>/. cl_soundbank.lua loads these instead of",
		"\tgenerating, so stock cars cost no CPU; tuned engines are still generated in game.",
		"\tSynth version: " .. version,
		"]]",
		"",
		"local E = PerpAudioEngine",
		"E.BAKED_VERSION = " .. string.format("%q", version),
	}
	return table.concat(L, "\n") .. "\n"
end
