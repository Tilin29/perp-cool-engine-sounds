--[[
	Audio Engine - sound bank (client)

	For each registered car this renders, in the background over a few frames:
	  * one seamless loop per rpm band, on throttle and off throttle
	  * a rev-limiter loop
	  * start-up one-shots (normal and "emotion" start), a shut-down one-shot
	  * a few overrun pops
	and registers them as game sounds with sound.Generate.

	Every car's stock engine also ships pre-generated (dev/baker renders this same build to
	sound/audio_engine/, described by cl_baked.lua). A bank whose sound key has a baked copy
	loads from those files instantly; only tuned engines are generated in game.
]]

local E = AUDIO_ENGINE
local Synth = E.Synth
local Bank = E.Bank or {}
E.Bank = Bank
Bank.list = Bank.list or {}
Bank.serial = Bank.serial or 0

local cvRate = CreateClientConVar("audio_engine_samplerate", "44100", true, false,
	"Sample rate for generated engine sounds: 44100 or 22050 (lower = faster to generate)")
local cvBudget = CreateClientConVar("audio_engine_genbudget", "6", true, false,
	"Milliseconds per frame spent generating engine sounds", 1, 50)

local function sampleRate()
	local r = cvRate:GetInt()
	if r ~= 22050 and r ~= 11025 then r = 44100 end
	return r
end

local function peakOf(buf, p)
	for i = 1, #buf do
		local a = buf[i]
		if a < 0 then a = -a end
		if a > p then p = a end
	end
	return p
end

local function scale(buf, g)
	for i = 1, #buf do buf[i] = buf[i] * g end
end

-- rough loudness: rms above ~250 Hz (the ear barely counts the 80 Hz boom)
local function loudness(buf, sr)
	local f = Synth.Biquad("highpass", 250, sr, 0.7)
	local b0, b1, b2, a1, a2, z1, z2 = f[1], f[2], f[3], f[4], f[5], 0, 0
	local s = 0
	for i = 1, #buf do
		local x = buf[i]
		local y = b0 * x + z1; z1 = b1 * x - a1 * y + z2; z2 = b2 * x - a2 * y
		s = s + y * y
	end
	return math.sqrt(s / #buf) + 1e-9
end

-- gentle look-ahead leveller: keep any 20 ms window from getting louder than capDb
local function capLoudness(buf, sr, capDb, capBroadDb)
	local f = Synth.Biquad("highpass", 250, sr, 0.7)
	local b0, b1, b2, a1, a2, z1, z2 = f[1], f[2], f[3], f[4], f[5], 0, 0
	local blk = math.floor(sr * 0.02)
	local nBlk = math.ceil(#buf / blk)
	local g = {}
	for k = 1, nBlk do
		local s, sb, n = 0, 0, 0
		for i = (k - 1) * blk + 1, math.min(#buf, k * blk) do
			local x = buf[i]
			local yv = b0 * x + z1; z1 = b1 * x - a1 * yv + z2; z2 = b2 * x - a2 * yv
			s = s + yv * yv; sb = sb + x * x; n = n + 1
		end
		n = math.max(n, 1)
		local db = 20 * math.log10(math.sqrt(s / n) + 1e-9)
		local dbB = 20 * math.log10(math.sqrt(sb / n) + 1e-9)
		g[k] = math.min(1, 10 ^ ((capDb - db) / 20), 10 ^ ((capBroadDb - dbB) / 20))
	end
	-- look ahead / hold: each block takes the lowest gain of its neighbours
	local h = {}
	for k = 1, nBlk do
		local m = 1
		for j = math.max(1, k - 3), math.min(nBlk, k + 3) do m = math.min(m, g[j]) end
		h[k] = m
	end
	for i = 1, #buf do
		local pos = (i - 1) / blk + 0.5
		local k = math.floor(pos)
		local fr = pos - k
		local ga = h[math.max(1, math.min(nBlk, k))]
		local gb = h[math.max(1, math.min(nBlk, k + 1))]
		buf[i] = buf[i] * (ga + (gb - ga) * fr)
	end
end

--[[
	Look-ahead peak limiter: turns down only the few loudest firing pulses so a loop can be
	played louder without clipping. Gain is worked out per 1 ms block, held across the
	neighbouring blocks (look-ahead), smoothed, and interpolated per sample. `circular` treats
	the buffer as a loop so the gain is continuous across the loop point.
]]
local function limitPeaks(buf, sr, ceiling, circular)
	local blk = math.max(1, math.floor(sr * 0.001))
	local N = #buf
	local nBlk = math.ceil(N / blk)
	local g = {}
	local any = false
	for k = 1, nBlk do
		local pk = 0
		for i = (k - 1) * blk + 1, math.min(N, k * blk) do
			local a = buf[i]
			if a < 0 then a = -a end
			if a > pk then pk = a end
		end
		g[k] = pk > ceiling and ceiling / pk or 1
		if g[k] < 1 then any = true end
	end
	if not any then return 0 end
	local function at(t, k)
		if circular then return t[(k - 1) % nBlk + 1] end
		return t[math.max(1, math.min(nBlk, k))]
	end
	local h = {}
	for k = 1, nBlk do
		local m = 1
		for j = k - 4, k + 4 do m = math.min(m, at(g, j)) end
		h[k] = m
	end
	local sm = {}
	for k = 1, nBlk do
		local acc = 0
		for j = k - 3, k + 3 do acc = acc + at(h, j) end
		sm[k] = acc / 7
	end
	local most = 1
	for i = 1, N do
		local pos = (i - 1) / blk + 0.5
		local k = math.floor(pos)
		local fr = pos - k
		local ga = at(sm, circular and k or math.max(1, k))
		local gb = at(sm, k + 1)
		local gg = ga + (gb - ga) * fr
		if gg < most then most = gg end
		buf[i] = buf[i] * gg
	end
	return -20 * math.log10(most)
end
Bank.LimitPeaks = limitPeaks

-- every engine is matched to the same loudness (rms above 250 Hz of its on-throttle loops),
-- so a V8 isn't quieter than an inline-4. Electric motors sit well below the engines.
local TARGET_DB, TARGET_EV_DB = -21, -30

local function build(b)
	local cfg, sr = b.cfg, b.sr
	local y = coroutine.yield
	local jobs = {}
	local function add(name, data, loop, own)
		jobs[#jobs + 1] = { name = b.prefix .. name, data = data, loop = loop, own = own }
		return b.prefix .. name
	end

	-- rpm bands
	local nb = #cfg.bands
	local refDb
	local bandGain = {}
	local popAgc, popDist = 1, math.huge
	local loudest, loudestBroad = -200, -200
	for i, R in ipairs(cfg.bands) do
		local off, _, agcOff = Synth.RenderSteadyLoop(cfg, sr, R, 0, y)
		local on = Synth.RenderSteadyLoop(cfg, sr, R, 1, y)
		-- loudness curve: on-throttle gets ~5 dB louder from the lowest to the highest band
		local db = 20 * math.log10(loudness(on, sr))
		refDb = refDb or db
		local want = refDb + 3 * (nb > 1 and (i - 1) / (nb - 1) or 0)
		local g = math.min(4, math.max(0.5, 10 ^ ((want - db) / 20)))
		bandGain[i] = g
		scale(off, g); scale(on, g)
		loudest = math.max(loudest, db + 20 * math.log10(g))
		if i > 1 or nb == 1 then
			-- the idle band can boom when the firing rate sits on the 78 Hz resonance; leave it out
			local sq = 0
			for k = 1, #on do sq = sq + on[k] * on[k] end
			loudestBroad = math.max(loudestBroad, 20 * math.log10(math.sqrt(sq / #on) + 1e-9))
		end
		b.layers[i] = { rpm = R, off = add("b" .. i .. "off", off, true), on = add("b" .. i .. "on", on, true) }
		if math.abs(R - 4200) < popDist then popDist = math.abs(R - 4200); popAgc = agcOff end
		y()
	end

	-- rev limiter
	local lim = Synth.RenderLimiterLoop(cfg, sr, y)
	scale(lim, bandGain[nb])
	b.limiter = { off = add("lim", lim, true), rpm = cfg.redline }

	-- start / stop
	local st, fadeAt, dur = Synth.RenderStart(cfg, sr, false, y)
	scale(st, bandGain[1])
	capLoudness(st, sr, loudest + 1, loudestBroad + 1)
	b.start = { name = add("start", st, false), fadeAt = fadeAt, dur = dur }
	local ste, fadeAtE, durE = Synth.RenderStart(cfg, sr, true, y)
	scale(ste, bandGain[1])
	capLoudness(ste, sr, loudest + 1, loudestBroad + 1)
	y()
	b.startEmo = { name = add("starte", ste, false), fadeAt = fadeAtE, dur = durE }
	local sp, spDur = Synth.RenderStop(cfg, sr, y)
	scale(sp, bandGain[1])
	b.stop = { name = add("stop", sp, false), dur = spDur }

	-- pops & bangs: always generated, the profile decides how often and how loud
	-- (not for an electric motor)
	b.bangs = {}
	if not cfg.electric then
		local function rmsHead(buf, n)
			local s2, m = 0, math.min(#buf, n)
			for i = 1, m do s2 = s2 + buf[i] * buf[i] end
			return math.sqrt(s2 / m) + 1e-9
		end
		local ref = 10 ^ (loudestBroad / 20)
		local win = math.floor(sr * 0.05)
		-- small pops and quick crackle bursts for the overrun, big bangs for lift-off
		local kinds = { "pop", "pop", "crackle", "pop", "crackle" }
		for i, kind in ipairs(kinds) do
			local p = Synth.RenderBackfire(cfg, sr, 1234 + i * 777, kind, y)
			-- generated 6 dB hot and played at half volume, so the pop volume can go to 200%
			scale(p, ref * 10 ^ (2 / 20) / rmsHead(p, math.floor(sr * 0.02)))
			b.pops[i] = add("pop" .. i, p, false, true)
		end
		b.bangs = {}
		for i = 1, 3 do
			local bg = Synth.RenderBackfire(cfg, sr, 4321 + i * 999, "bang", y)
			scale(bg, ref * 10 ^ (9 / 20) / rmsHead(bg, win))
			b.bangs[i] = add("bang" .. i, bg, false, true)
		end
	end

	-- the limiter loop has gaps (fuel cuts); bring its level up to the top band's full throttle
	do
		local function rms(buf)
			local s2 = 0
			for i = 1, #buf do s2 = s2 + buf[i] * buf[i] end
			return math.sqrt(s2 / #buf) + 1e-9
		end
		local topOn = nil
		for _, j in ipairs(jobs) do
			if j.name == b.layers[nb].on then topOn = j.data end
			if j.name == b.limiter.off then
				local target = topOn and rms(topOn) * 1.15 or rms(j.data)
				scale(j.data, math.min(3, target / rms(j.data)))
			end
		end
	end

	-- (turbo whistle and blow-off valve are shared by every engine: see the shared bank below)

	-- one gain for everything, so the relative levels stay as rendered: set by loudness, so
	-- every engine plays equally loud. The loudest pulses of loops and one-shots are then
	-- limited to stay under full scale; pops & bangs are only turned down if they would clip.
	local lsum, ln = 0, 0
	for i = (nb > 1 and 2 or 1), nb do
		local d
		for _, j in ipairs(jobs) do if j.name == b.layers[i].on then d = j.data end end
		if d then lsum = lsum + 20 * math.log10(loudness(d, sr)); ln = ln + 1 end
	end
	local target = cfg.electric and TARGET_EV_DB or TARGET_DB
	local gain = ln > 0 and 10 ^ ((target - lsum / ln) / 20) or 1
	gain = math.min(gain, 30)
	b.limitedDb = 0
	for _, j in ipairs(jobs) do
		if not j.own then
			scale(j.data, gain)
			local db = limitPeaks(j.data, sr, 0.95, j.loop)
			if j.loop then b.limitedDb = math.max(b.limitedDb, db) end
			y()
		end
	end
	y()

	for _, j in ipairs(jobs) do
		local data = j.data
		local samples = data
		if j.loop then
			-- one pre-roll sample, then loop from sample 1: [y_L, y_1 .. y_L] with loopStart = 1
			samples = { data[#data] }
			for i = 1, #data do samples[i + 1] = data[i] end
		end
		local N = #samples
		local jg = 1
		if j.own then
			jg = gain
			local pk = peakOf(samples, 0)
			if pk * jg > 0.98 then jg = 0.98 / pk end
		end
		-- the peak each sound plays at (cl_engine keeps the car's mix under full scale with it)
		b.peak = b.peak or {}
		b.peak[j.name] = math.min(1, peakOf(samples, 0) * jg)
		sound.Generate(j.name, sr, N / sr, function(t)
			local v = (samples[(t % N) + 1] or 0) * jg
			if v > 1 then v = 1 elseif v < -1 then v = -1 end
			return v
		end, j.loop and 1 or nil)
		j.data = nil
		y()
	end

	b.ready = true
	b.buildTime = SysTime() - b.started
	MsgN(string.format("[Audio Engine] %s: generated %d sounds at %d Hz in %.1fs",
		cfg.engineName or cfg.name or cfg.id, #jobs, sr, b.buildTime))
end

local cvMax = CreateClientConVar("audio_engine_maxsounds", "10", true, false,
	"How many different engine sounds to keep generated (each ~4 MB)", 2, 40)

Bank.queue = Bank.queue or {}
Bank.count = Bank.count or 0

-- road & wind loops, shared by every car (built once)
local function buildEnv(b)
	local sr, y = b.sr, coroutine.yield
	local function rms(buf)
		local s2 = 0
		for i = 1, #buf do s2 = s2 + buf[i] * buf[i] end
		return math.sqrt(s2 / #buf) + 1e-9
	end
	-- name, buffer, level (rms), loop, level measured over the first n seconds
	-- The turbo sounds are generated 6 dB hot and played at half volume by default, so their
	-- volume sliders can go to 200%. Every engine is matched to the same loudness, so one
	-- turbo and one blow-off level suit them all, and switching the turbo on or off (or its
	-- volumes) never needs a new engine.
	local jobs = {
		{ "road", Synth.RenderRoadLoop(sr, y), 0.07, true },
		{ "wind", Synth.RenderWindLoop(sr, y), 0.06, true },
		{ "turbo", Synth.RenderTurboLoop(sr, y), 0.068, true },
		{ "bov1", Synth.RenderBlowoff(sr, 0xB10F + 4099, y), 0.234, false, 0.15 },
		{ "bov2", Synth.RenderBlowoff(sr, 0xB10F + 2 * 4099, y), 0.234, false, 0.15 },
	}
	b.peak = {}
	for _, j in ipairs(jobs) do
		local data, target, loop, head = j[2], j[3], j[4], j[5]
		local ref = data
		if head then
			ref = {}
			for i = 1, math.min(#data, math.floor(sr * head)) do ref[i] = data[i] end
		end
		local g = target / rms(ref)
		local pk0 = peakOf(data, 0)
		if pk0 * g > 0.98 then g = 0.98 / pk0 end
		local samples
		if loop then
			samples = { data[#data] * g }
			for i = 1, #data do samples[i + 1] = data[i] * g end
		else
			samples = {}
			for i = 1, #data do samples[i] = data[i] * g end
		end
		local N = #samples
		local name = b.prefix .. j[1]
		b.peak[j[1]] = math.min(1, pk0 * g)
		b.peak[name] = b.peak[j[1]]
		sound.Generate(name, sr, N / sr, function(t)
			local v = samples[(t % N) + 1] or 0
			if v > 1 then v = 1 elseif v < -1 then v = -1 end
			return v
		end, loop and 1 or nil)
		b[j[1]] = name
		y()
	end
	b.blowoff = { b.bov1, b.bov2 }
	b.ready = true
end

---------------------------------------------------------------------------
-- pre-generated banks (cl_baked.lua + sound/audio_engine/<dir>/*.wav)
---------------------------------------------------------------------------
local cvBaked = CreateClientConVar("audio_engine_baked", "1", true, false,
	"1 = stock engines play the pre-generated sounds from the content; 0 = generate everything in game")

local function bakedFiles(m, probe)
	if not m or not cvBaked:GetBool() then return nil end
	local dir = "audio_engine/" .. m.dir .. "/"
	-- the content pack may be missing or out of date: then generate as before
	if not file.Exists("sound/" .. dir .. probe .. ".wav", "GAME") then return nil end
	return function(stem) return dir .. stem .. ".wav" end
end

local function bakedBank(cfg)
	local m = E.BAKED and E.BAKED[cfg.id]
	local n = bakedFiles(m, "b1on")
	if not n then return nil end
	local b = {
		cfg = cfg, key = cfg.id, sr = m.sr, ready = true, baked = true, cyl = m.cyl,
		layers = {}, pops = {}, bangs = {}, peak = {}, limitedDb = m.limitedDb,
	}
	for i, rpm in ipairs(m.layers) do b.layers[i] = { rpm = rpm, off = n("b" .. i .. "off"), on = n("b" .. i .. "on") } end
	b.limiter = { off = n("lim"), rpm = m.limiter }
	b.start = { name = n("start"), fadeAt = m.start.fadeAt, dur = m.start.dur }
	b.startEmo = { name = n("starte"), fadeAt = m.startEmo.fadeAt, dur = m.startEmo.dur }
	b.stop = { name = n("stop"), dur = m.stop.dur }
	for i = 1, m.pops do b.pops[i] = n("pop" .. i) end
	for i = 1, m.bangs do b.bangs[i] = n("bang" .. i) end
	for stem, pk in pairs(m.peak) do
		local name = n(stem)
		b.peak[name] = pk
		util.PrecacheSound(name)
	end
	return b
end

local function bakedEnv()
	local m = E.BAKED_ENV
	local n = bakedFiles(m, "road")
	if not n then return nil end
	local b = { sr = m.sr, ready = true, baked = true, peak = {} }
	for stem, pk in pairs(m.peak) do
		b[stem] = n(stem)
		b.peak[stem] = pk
		b.peak[b[stem]] = pk
		util.PrecacheSound(b[stem])
	end
	b.blowoff = { b.bov1, b.bov2 }
	return b
end

function Bank.GetEnv()
	if Bank.env then return Bank.env end
	local baked = bakedEnv()
	if baked then
		Bank.env = baked
		return baked
	end
	Bank.serial = Bank.serial + 1
	local b = { sr = 22050, ready = false, prefix = "audenv_" .. Bank.serial .. "_" }
	b.co = coroutine.create(function() buildEnv(b) end)
	Bank.queue[#Bank.queue + 1] = b
	Bank.env = b
	return b
end

function Bank.Build(cfg)
	-- a stock engine with a baked copy: no generation, and it doesn't count toward maxsounds
	local baked = bakedBank(cfg)
	if baked then
		if Bank.list[cfg.id] and not Bank.list[cfg.id].baked then Bank.count = Bank.count - 1 end
		Bank.list[cfg.id] = baked
		return baked
	end
	Bank.serial = Bank.serial + 1
	local _, _, cyl = Synth.LayoutParams(cfg.layout)
	local b = {
		cfg = cfg, key = cfg.id, sr = sampleRate(), ready = false, cyl = cyl,
		prefix = "audeng_" .. Bank.serial .. "_",
		layers = {}, pops = {}, started = SysTime(),
	}
	b.co = coroutine.create(function() build(b) end)
	if not Bank.list[cfg.id] then Bank.count = Bank.count + 1 end
	Bank.list[cfg.id] = b
	Bank.queue[#Bank.queue + 1] = b
	return b
end

--[[
	The bank for an engine config: built on first use. Cars with the same engine sound share
	one bank. Past the audio_engine_maxsounds limit, new engines fall back to `fallback`
	(the car's stock engine) instead of generating more.
	urgent = true moves it to the front of the queue (the car you're driving).
]]
function Bank.Get(cfg, fallback, urgent)
	local b = Bank.list[cfg.id]
	if not b then
		if fallback and fallback.id ~= cfg.id and Bank.count >= cvMax:GetInt() then
			return Bank.Get(fallback, nil, urgent)
		end
		b = Bank.Build(cfg)
	end
	if urgent and b.co and Bank.queue[1] ~= b then
		for i, q in ipairs(Bank.queue) do
			if q == b then table.remove(Bank.queue, i) break end
		end
		table.insert(Bank.queue, 1, b)
	end
	return b
end

hook.Add("Think", "audio_engine_bank", function()
	local b = Bank.queue[1]
	if not b then return end
	if not b.co then table.remove(Bank.queue, 1) return end
	local t0 = SysTime()
	local budget = cvBudget:GetFloat() / 1000
	while SysTime() - t0 < budget do
		local ok, err = coroutine.resume(b.co)
		if not ok then
			ErrorNoHalt("[Audio Engine] sound generation failed: " .. tostring(err) .. "\n")
			b.co = nil
		elseif coroutine.status(b.co) == "dead" then
			b.co = nil
		end
		if not b.co then
			table.remove(Bank.queue, 1)
			break
		end
	end
end)

-- right after joining: the shared bank, and the stock engines that have no baked copy, while
-- there are few enough of them. Baked engines load (instantly) when a car using one shows up,
-- so a player only holds the sounds of the cars around them.
local function prebuild()
	Bank.GetEnv()
	local gen = {}
	for _, car in pairs(E.Cars) do
		local cfg = E.ResolveProfile(car)
		if not (E.BAKED and E.BAKED[cfg.id]) then gen[cfg.id] = cfg end
	end
	if table.Count(gen) <= cvMax:GetInt() then
		for _, cfg in pairs(gen) do Bank.Get(cfg) end
	end
end
hook.Add("InitPostEntity", "audio_engine_bank", prebuild)
if IsValid(LocalPlayer()) then prebuild() end -- lua refresh / late load

function Bank.RebuildAll()
	local old = Bank.list
	Bank.list, Bank.queue, Bank.count = {}, {}, 0
	Bank.env = nil
	Bank.GetEnv()
	for _, b in pairs(old) do Bank.Build(b.cfg) end
	MsgN("[Audio Engine] regenerating engine sounds at " .. sampleRate() .. " Hz...")
end
concommand.Add("audio_engine_rebuild", Bank.RebuildAll, nil, "Regenerate the procedural engine sounds (after changing the synth or presets)")

-- switching between 44.1 and 22.05 kHz regenerates everything at the new rate
cvars.AddChangeCallback("audio_engine_samplerate", function(_, old, new)
	if old ~= new then Bank.RebuildAll() end
end, "audio_engine_rebuild")
cvars.AddChangeCallback("audio_engine_baked", function(_, old, new)
	if old ~= new then Bank.RebuildAll() end
end, "audio_engine_rebuild")
