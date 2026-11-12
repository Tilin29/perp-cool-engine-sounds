--[[
	Audio Engine debug module: performance profiler (client). Not part of the final addon.
	Superadmins (or the host), while audio_engine_debug is 1.

	Nothing here runs until asked: the measuring wrappers (and E.PerfCar, the core's per-car
	timing point) are put on only while a capture runs or the overlay is open, then taken off.

	  audio_engine_perf [seconds] [client | server | both]
	                                    measures for 10 s (default) and prints a report to the console
	  audio_engine_perf_hud [0/1]       live overlay, client and server figures once a second
	  audio_engine_perf_snapshot        what's loaded and playing right now (no timing)
	  audio_engine_perf_spawn <count> [car | mixed] [lights 0/1], audio_engine_perf_clear
	                                    stress test: running PERP cars in front of you (sv_perf.lua)

	Client figures:
	  time      the addon's hooks per frame (average, worst), each car's own update (E.PerfCar),
	            against the frame time
	  sound     CSoundPatches the addon holds and how many play (Source mixes a limited number of
	            channels for everything: past that sounds drop out), sound commands per frame
	            (volume / pitch changes, starts, stops: each one is engine work)
	  memory    the sound banks: generated ones (samples kept in Lua tables, 8 bytes each, and in the
	            engine's buffer, ~2 bytes each), baked ones (their WAV files, loaded by the engine), the
	            env bank, the siren's tones; the client's whole Lua heap
	  other     traces (tunnel probes), dynamic lights and lens quads / glow sprites drawn per frame
]]

local E = AUDIO_ENGINE
local DBG = E.Debug

-- (Lua refresh: take the previous load's wrappers off before this one starts)
if DBG.PerfClient and DBG.PerfClient.Uninstall then DBG.PerfClient.Uninstall() end
local PERF = {}
DBG.PerfClient = PERF

local OURS = { "^audio_engine", "^police_siren" }
local UNITS_TO_M = 0.01905
local HUD_EVERY = 1
local SNAPSHOT_EVERY = 0.5
local LUA_BYTES_PER_SAMPLE = 8
local ENGINE_BYTES_PER_SAMPLE = 2
local MB = 1024 * 1024
local SOUND_METHODS = { "ChangeVolume", "ChangePitch", "PlayEx", "Play", "Stop", "SetDSP", "SetSoundLevel", "FadeOut" }

local function ours(name)
	if not isstring(name) then return false end
	for _, p in ipairs(OURS) do
		if string.find(name, p) then return true end
	end

	return false
end

local function say(msg)
	chat.AddText(Color(255, 190, 60), "[Audio Engine perf] ", Color(230, 230, 230), msg)
end

---------------------------------------------------------------------------
-- accumulators: a capture and the overlay each keep their own
---------------------------------------------------------------------------
local accs = {}

local function newAcc()
	return { t0 = SysTime(), frames = 0, frameSum = 0, frameMax = 0, hooks = {}, cars = {}, traces = 0,
		sound = {}, creates = 0, dlights = 0, quads = 0, sprites = 0 }
end

local function each(fn)
	for _, a in pairs(accs) do fn(a) end
end

local inHook = 0

local function addTime(tbl, key, dt)
	local h = tbl[key]
	if not h then
		h = { calls = 0, total = 0, max = 0 }
		tbl[key] = h
	end
	h.calls = h.calls + 1
	h.total = h.total + dt
	if dt > h.max then h.max = dt end
end

---------------------------------------------------------------------------
-- the measuring wrappers
---------------------------------------------------------------------------
local installed = false
local wrapped = {}
local saved = {}

local function counter(field)
	return function(a) a[field] = a[field] + 1 end
end
local countTrace, countCreate, countDlight = counter("traces"), counter("creates"), counter("dlights")
local countQuad, countSprite = counter("quads"), counter("sprites")

local function wrapLib(lib, fname, count)
	local orig = lib[fname]
	if not orig then return end
	saved[#saved + 1] = { lib, fname, orig }
	lib[fname] = function(...)
		if inHook > 0 then each(count) end
		return orig(...)
	end
end

local function install()
	if installed then return end
	installed = true
	for event, list in pairs(hook.GetTable()) do
		if not string.find(event, "/", 1, true) then
			for name, fn in pairs(list) do
				if ours(name) and isfunction(fn) then
					local key = event .. " / " .. name
					local function wrapper(...)
						inHook = inHook + 1
						local t0 = SysTime()
						local a, b, c, d, e, f = fn(...)
						local dt = SysTime() - t0
						for _, acc in pairs(accs) do addTime(acc.hooks, key, dt) end
						inHook = inHook - 1
						return a, b, c, d, e, f
					end
					hook.Add(event, name, wrapper)
					table.insert(wrapped, { event, name, fn, wrapper })
				end
			end
		end
	end
	hook.Add("Think", "audio_dbg_perf_frame", function()
		local ft = RealFrameTime()
		for _, a in pairs(accs) do
			a.frames = a.frames + 1
			a.frameSum = a.frameSum + ft
			if ft > a.frameMax then a.frameMax = ft end
		end
	end)
	E.PerfCar = function(ent, dt)
		for _, a in pairs(accs) do addTime(a.cars, ent, dt) end
	end
	wrapLib(util, "TraceLine", countTrace)
	wrapLib(util, "TraceHull", countTrace)
	wrapLib(_G, "CreateSound", countCreate)
	wrapLib(_G, "DynamicLight", countDlight)
	wrapLib(render, "DrawQuadEasy", countQuad)
	wrapLib(render, "DrawSprite", countSprite)
	local meta = FindMetaTable("CSoundPatch")
	for _, m in ipairs(SOUND_METHODS) do
		wrapLib(meta, m, function(a) a.sound[m] = (a.sound[m] or 0) + 1 end)
	end
end

local function uninstall()
	if not installed then return end
	installed = false
	for _, w in ipairs(wrapped) do
		local list = hook.GetTable()[w[1]]
		if list and list[w[2]] == w[4] then hook.Add(w[1], w[2], w[3]) end
	end
	wrapped = {}
	hook.Remove("Think", "audio_dbg_perf_frame")
	E.PerfCar = nil
	for i = #saved, 1, -1 do
		local s = saved[i]
		s[1][s[2]] = s[3]
	end
	saved = {}
end
PERF.Uninstall = uninstall

local function refresh()
	if next(accs) then install() else uninstall() end
end

---------------------------------------------------------------------------
-- snapshot: what's loaded and playing (no timing)
---------------------------------------------------------------------------
local wavBytes = setmetatable({}, { __mode = "k" })

-- the bytes of a baked bank's WAV files (the engine loads them when the bank is used)
local function bakedBytes(b)
	if wavBytes[b] then return wavBytes[b] end
	local total = 0
	for name in pairs(b.peak or {}) do
		if isstring(name) and string.EndsWith(name, ".wav") then total = total + (file.Size("sound/" .. name, "GAME") or 0) end
	end
	wavBytes[b] = total

	return total
end

local function bankMemory()
	local m = { baked = 0, bakedBytes = 0, generated = 0, genSamples = 0, building = 0 }
	local Bank = E.Bank
	if not Bank then return m end
	local function add(b)
		if not b then return end
		if b.baked then
			m.baked = m.baked + 1
			m.bakedBytes = m.bakedBytes + bakedBytes(b)
		else
			m.generated = m.generated + 1
			m.genSamples = m.genSamples + (b.samples or 0)
			if not b.ready then m.building = m.building + 1 end
		end
	end
	for _, b in pairs(Bank.list or {}) do add(b) end
	add(Bank.env)
	m.count = Bank.count or 0
	local cv = GetConVar("audio_engine_maxsounds")
	m.max = cv and cv:GetInt() or 0
	m.queue = #(Bank.queue or {})

	return m
end

local function snapshot()
	local s = { cars = {}, patches = 0, playing = 0, running = 0, lights = 0, vehicles = 0 }
	local eye = LocalPlayer():EyePos()
	for _, ent in ipairs(ents.FindByClass("prop_vehicle_jeep*")) do
		s.vehicles = s.vehicles + 1
		local car = E.GetClientCar and E.GetClientCar(ent)
		if car then
			local n, playing = 0, 0
			for _, p in pairs(car.patches or {}) do
				n = n + 1
				if p:IsPlaying() then playing = playing + 1 end
			end
			if car.oneshot and car.oneshot.patch then
				n = n + 1
				if car.oneshot.patch:IsPlaying() then playing = playing + 1 end
			end
			local cfg = E.GetCarConfig(ent)
			local bank = car.bank
			local on = ent:GetNW2Bool("audio_on", false)
			local lights = ent:GetNW2Int("audio_lights", 0) > 0
			s.patches, s.playing = s.patches + n, s.playing + playing
			if on then s.running = s.running + 1 end
			if lights then s.lights = s.lights + 1 end
			s.cars[ent] = {
				name = cfg and cfg.name or ent:GetModel(), dist = ent:GetPos():Distance(eye) * UNITS_TO_M, on = on, lights = lights,
				patches = n, playing = playing, mode = car.mode or "active",
				bank = not bank and "none" or bank.baked and "baked" or bank.ready and "generated" or "building",
			}
		end
	end
	s.banks = bankMemory()
	s.siren = POLICE_SIREN and POLICE_SIREN.Stats and POLICE_SIREN.Stats() or nil
	s.luaKB = collectgarbage("count")

	return s
end
PERF.Snapshot = snapshot

local function memoryLines(s, out)
	local b = s.banks
	local genLua, genEngine = b.genSamples * LUA_BYTES_PER_SAMPLE, b.genSamples * ENGINE_BYTES_PER_SAMPLE
	out(string.format("Sound banks: %d baked (WAV files %.1f MB in the engine), %d generated (%.1f MB of Lua tables + ~%.1f MB in the engine)%s",
		b.baked, b.bakedBytes / MB, b.generated, genLua / MB, genEngine / MB,
		b.building > 0 and string.format(", %d still building", b.building) or ""))
	out(string.format("  generated engines count %d of audio_engine_maxsounds %d; %d in the build queue", b.count or 0, b.max or 0, b.queue or 0))
	local p = s.siren
	if p then
		local sr = (p.sampleRate or 44100)
		out(string.format("Siren: %d tone versions built (%.1f s of audio: %.1f MB of Lua tables + ~%.1f MB in the engine), %d siren cars near, %d sounding, %d patches (%d playing)%s",
			p.tonesBuilt * 2, p.samples / sr, p.samples * LUA_BYTES_PER_SAMPLE / MB, p.samples * ENGINE_BYTES_PER_SAMPLE / MB,
			p.cars, p.sounding, p.patches, p.playing, p.building > 0 and string.format(", %d building", p.building) or ""))
	end
	out(string.format("Client Lua memory (all addons): %.1f MB", s.luaKB / 1024))
end

local function printSnapshot(s, out, timing)
	out(string.format("Cars: %d vehicles, %d with the procedural engine (%d running, %d lights on)",
		s.vehicles, table.Count(s.cars), s.running, s.lights))
	out(string.format("Engine sound patches: %d held, %d playing (all the game's sounds share a limited number of channels)",
		s.patches, s.playing))
	local list = {}
	for ent, c in pairs(s.cars) do
		local t = timing and timing[ent]
		c.ms = t and t.total / math.max(timing.frames, 1) * 1000 or 0
		c.max = t and t.max * 1000 or 0
		table.insert(list, c)
	end
	table.sort(list, function(a, b)
		if a.ms ~= b.ms then return a.ms > b.ms end
		return a.dist < b.dist
	end)
	out("  car                                     dist m  engine  state    bank        patches(playing)" .. (timing and "   ms/frame   worst ms" or ""))
	for _, c in ipairs(list) do
		out(string.format("  %-38s %7.0f  %-6s  %-7s  %-10s  %3d (%d)%s", string.sub(c.name, 1, 38), c.dist, c.on and "on" or "off",
			c.mode, c.bank, c.patches, c.playing, timing and string.format("        %8.4f %10.3f", c.ms, c.max) or ""))
	end
	out("  (state: active = every frame; parked = idle sound only, 10x a second while you move slowly; asleep = engine off,"
		.. " 4x a second; far = past audio_engine_range, silent; dormant = out of view)")
	memoryLines(s, out)
end

---------------------------------------------------------------------------
-- the timing summary of an accumulator
---------------------------------------------------------------------------
local function timing(a)
	local frames = math.max(a.frames, 1)
	local hooks, total = {}, 0
	for key, h in pairs(a.hooks) do
		table.insert(hooks, { key = key, ms = h.total * 1000 / frames, max = h.max * 1000, calls = h.calls / frames })
		total = total + h.total
	end
	table.sort(hooks, function(x, y) return x.ms > y.ms end)
	local cars = { frames = frames }
	local carTotal = 0
	for ent, t in pairs(a.cars) do
		cars[ent] = t
		carTotal = carTotal + t.total
	end
	local sound, soundTotal = {}, 0
	for m, n in pairs(a.sound) do
		table.insert(sound, string.format("%s %.1f", m, n / frames))
		soundTotal = soundTotal + n
	end
	table.sort(sound)

	return {
		secs = SysTime() - a.t0, frames = frames, frameMs = a.frameSum / frames * 1000, frameMax = a.frameMax * 1000,
		hooks = hooks, totalMs = total * 1000 / frames, carMs = carTotal * 1000 / frames, cars = cars,
		traces = a.traces / frames, sound = sound, soundPerFrame = soundTotal / frames, creates = a.creates,
		dlights = a.dlights / frames, quads = a.quads / frames, sprites = a.sprites / frames,
	}
end

local function printReport(t, s, out)
	out(string.format("==== Audio Engine performance, CLIENT: %.1f s, %d frames, %.1f fps (frame %.2f ms average, %.1f ms worst) ====",
		t.secs, t.frames, 1000 / math.max(t.frameMs, 0.001), t.frameMs, t.frameMax))
	out(string.format("Addon Lua: %.3f ms per frame (%.1f%% of the frame); the cars' own updates %.3f ms of it",
		t.totalMs, t.totalMs / math.max(t.frameMs, 0.001) * 100, t.carMs))
	out("  hook (event / name)                               ms/frame   worst ms  calls/frame")
	for _, h in ipairs(t.hooks) do
		out(string.format("  %-48s %8.4f %10.3f %10.2f", h.key, h.ms, h.max, h.calls))
	end
	out(string.format("Per frame: %.1f sound commands (%s), %.1f traces, %.1f dynamic lights, %.1f lens quads, %.1f glow sprites; %d sounds created",
		t.soundPerFrame, table.concat(t.sound, ", "), t.traces, t.dlights, t.quads, t.sprites, t.creates))
	printSnapshot(s, out, t.cars)
end

---------------------------------------------------------------------------
-- commands
---------------------------------------------------------------------------
local function allowed()
	if DBG.Allowed(LocalPlayer()) then return true end
	say(DBG.Enabled() and "Superadmins only." or "The debug tools are off on this server (audio_engine_debug 0).")

	return false
end

local capture
concommand.Add("audio_engine_perf", function(_, _, args)
	if not allowed() then return end
	if capture then
		say("A capture is already running.")
		return
	end
	local secs = math.Clamp(tonumber(args[1]) or 10, 1, 120)
	local which = string.lower(args[2] or "both")
	if which == "both" or which == "server" then
		net.Start("audio_dbg_perf_cap")
		net.WriteFloat(secs)
		net.SendToServer()
	end
	if which == "both" or which == "client" then
		capture = newAcc()
		accs.capture = capture
		refresh()
		timer.Create("audio_dbg_perf_capture", secs, 1, function()
			local t = timing(capture)
			accs.capture, capture = nil, nil
			refresh()
			printReport(t, snapshot(), print)
			say("Report printed to the console.")
		end)
	end
	say(string.format("Measuring for %.0f s (%s); the report goes to the console. Play normally meanwhile.", secs, which))
end, nil, "Performance capture (debug): audio_engine_perf [seconds = 10] [client | server | both]")

concommand.Add("audio_engine_perf_snapshot", function()
	if not allowed() then return end
	printSnapshot(snapshot(), print)
end, nil, "What the Audio Engine has loaded and playing right now: cars, sound patches, memory (debug)")

---------------------------------------------------------------------------
-- the live overlay
---------------------------------------------------------------------------
local hud = false
local hudAcc, hudTiming, hudSnap, serverStats
local nextHud, nextSnap = 0, 0

local function setHud(on)
	if on == hud then return end
	hud = on
	if on then
		hudAcc = newAcc()
		accs.hud = hudAcc
		hudTiming, hudSnap, serverStats = nil, nil, nil
	else
		accs.hud, hudAcc = nil, nil
	end
	refresh()
	net.Start("audio_dbg_perf_sub")
	net.WriteBool(on)
	net.SendToServer()
	if on then
		hook.Add("HUDPaint", "audio_dbg_perf", PERF.Paint)
	else
		hook.Remove("HUDPaint", "audio_dbg_perf")
	end
end

concommand.Add("audio_engine_perf_hud", function(_, _, args)
	local want = args[1] and args[1] ~= "0" or (not args[1] and not hud)
	if want and not allowed() then return end
	setHud(want)
end, nil, "Live performance overlay (debug): audio_engine_perf_hud [0/1]")

net.Receive("audio_dbg_perf_stats", function()
	serverStats = net.ReadTable()
end)

local FONT = "DebugFixed"
local LINE = 13

function PERF.Paint()
	local now = SysTime()
	if now >= nextHud and hudAcc then
		nextHud = now + HUD_EVERY
		hudTiming = timing(hudAcc)
		hudAcc = newAcc()
		accs.hud = hudAcc
	end
	if now >= nextSnap then
		nextSnap = now + SNAPSHOT_EVERY
		hudSnap = snapshot()
	end
	local lines = {}
	local function out(s) lines[#lines + 1] = s end
	out("AUDIO ENGINE PERF (audio_engine_perf_hud 0 to close)")
	local t = hudTiming
	if t then
		out(string.format("client %.0f fps  frame %.2f ms  addon %.3f ms (%.1f%%)  cars %.3f ms",
			1000 / math.max(t.frameMs, 0.001), t.frameMs, t.totalMs, t.totalMs / math.max(t.frameMs, 0.001) * 100, t.carMs))
		for i = 1, math.min(5, #t.hooks) do
			out(string.format("  %-44s %7.3f ms  (worst %.2f)", t.hooks[i].key, t.hooks[i].ms, t.hooks[i].max))
		end
		out(string.format("per frame: %.0f sound cmds  %.1f traces  %.1f dlights  %.0f quads  %.0f sprites",
			t.soundPerFrame, t.traces, t.dlights, t.quads, t.sprites))
	end
	local s = hudSnap
	if s then
		out(string.format("cars %d (%d running, %d lights)  patches %d held / %d playing",
			table.Count(s.cars), s.running, s.lights, s.patches, s.playing))
		local b = s.banks
		out(string.format("banks: %d baked %.1f MB wav, %d generated %.1f MB Lua + %.1f MB engine; Lua %.1f MB",
			b.baked, b.bakedBytes / MB, b.generated, b.genSamples * LUA_BYTES_PER_SAMPLE / MB, b.genSamples * ENGINE_BYTES_PER_SAMPLE / MB, s.luaKB / 1024))
		if s.siren then
			out(string.format("siren: %d versions built %.1f MB Lua, %d sounding, %d patches", s.siren.tonesBuilt * 2,
				s.siren.samples * LUA_BYTES_PER_SAMPLE / MB, s.siren.sounding, s.siren.patches))
		end
		-- the costliest cars (by the last second's timing), else the nearest
		local list = {}
		for ent, c in pairs(s.cars) do
			local ct = t and t.cars[ent]
			c.ms = ct and ct.total / t.frames * 1000 or 0
			table.insert(list, c)
		end
		table.sort(list, function(x, y)
			if x.ms ~= y.ms then return x.ms > y.ms end
			return x.dist < y.dist
		end)
		for i = 1, math.min(8, #list) do
			local c = list[i]
			out(string.format("  %-30s %5.0f m %-3s %-9s %2d/%-2d  %.4f ms", string.sub(c.name, 1, 30), c.dist, c.on and "on" or "off",
				c.bank, c.playing, c.patches, c.ms))
		end
	end
	local sv = serverStats
	if sv then
		out(string.format("server: addon %.3f ms/tick (%.1f%% of %.1f ms)  %.1f traces/tick  Lua %.1f MB",
			sv.totalMsTick, sv.totalMsTick / math.max(sv.tickMs, 0.001) * 100, sv.tickMs, sv.tracesTick, sv.luaKB / 1024))
		out(string.format("  NW2 %.1f changes/s  net %.1f msgs/s %.0f B/s  cars %d tracked, %d running, %d driven",
			sv.nwSec, sv.netSec, sv.netBytesSec, sv.cars.tracked, sv.cars.on, sv.cars.driven))
		for _, h in ipairs(sv.hooks or {}) do
			out(string.format("  %-44s %7.4f ms (worst %.2f)", h.key, h.msTick, h.maxMs))
		end
	end
	surface.SetFont(FONT)
	local w = 0
	for _, l in ipairs(lines) do w = math.max(w, (surface.GetTextSize(l))) end
	local x, y = ScrW() - w - 24, 80
	surface.SetDrawColor(0, 0, 0, 200)
	surface.DrawRect(x - 8, y - 6, w + 16, #lines * LINE + 12)
	for i, l in ipairs(lines) do
		draw.SimpleText(l, FONT, x, y + (i - 1) * LINE, i == 1 and Color(255, 190, 60) or color_white)
	end
end
