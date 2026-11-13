--[[
	Audio Engine debug module: performance profiler (client). Not part of the final addon.
	Superadmins (or the host), while audio_engine_debug is 1.

	Nothing here runs until asked: the measuring wrappers (and AudioEngine.PerfCar, the core's per-car
	timing point) are put on only while a capture runs or the overlay is open, then taken off.

	  audio_engine_perf [seconds] [client | server | both]
	                                    measures for 10 s (default) and prints a report to the console
	  audio_engine_perf_hud [0/1]       live overlay, client and server figures once a second
	  audio_engine_perf_snapshot        what's loaded and playing right now (no timing)
	  audio_engine_perf_spawn <count> [car | mixed] [lights 0/1] [mph] [grid | race], audio_engine_perf_clear
	                                    stress test: running PERP cars in front of you (sv_perf.lua)

	Client figures:
	  time      the addon's hooks per frame (average, worst), each car's own update (AudioEngine.PerfCar),
	            against the frame time
	  sound     CSoundPatches the addon holds and how many play (Source mixes a limited number of
	            channels for everything: past that sounds drop out), sound commands per frame
	            (volume / pitch changes, starts, stops: each one is engine work)
	  memory    the sound banks: generated ones (samples kept in Lua tables, 8 bytes each, and in the
	            engine's buffer, ~2 bytes each), baked ones (their WAV files, loaded by the engine), the
	            env bank, the siren's tones; the client's whole Lua heap
	  other     traces (tunnel probes), dynamic lights and lens quads / glow sprites drawn per frame
]]

local AudioEngine = AUDIO_ENGINE
local EngineDebug = AudioEngine.Debug

-- (Lua refresh: take the previous load's wrappers off before this one starts)
if EngineDebug.PerfClient and EngineDebug.PerfClient.Uninstall then EngineDebug.PerfClient.Uninstall() end
local PERF = {}
EngineDebug.PerfClient = PERF

local OUR_HOOK_PATTERNS = { "^audio_engine", "^police_siren" }
local UNITS_TO_M = 0.01905
local HUD_EVERY = 1
local SNAPSHOT_EVERY = 0.5
local LUA_BYTES_PER_SAMPLE = 8
local ENGINE_BYTES_PER_SAMPLE = 2
local MB = 1024 * 1024
local SOUND_METHODS = { "ChangeVolume", "ChangePitch", "PlayEx", "Play", "Stop", "SetDSP", "SetSoundLevel", "FadeOut" }

local function isOurs(name)
	if not isstring(name) then return false end
	for _, pattern in ipairs(OUR_HOOK_PATTERNS) do
		if string.find(name, pattern) then return true end
	end

	return false
end

local function report(message)
	chat.AddText(Color(255, 190, 60), "[Audio Engine perf] ", Color(230, 230, 230), message)
end

---------------------------------------------------------------------------
-- accumulators: a capture and the overlay each keep their own
---------------------------------------------------------------------------
local accumulators = {}

local function newAccumulator()
	return { startTime = SysTime(), frames = 0, frameSum = 0, frameMax = 0, hooks = {}, cars = {}, traces = 0,
		sound = {}, creates = 0, dlights = 0, quads = 0, sprites = 0 }
end

local function forEachAccumulator(action)
	for _, accumulator in pairs(accumulators) do action(accumulator) end
end

local inHook = 0

local function addTime(timings, key, seconds)
	local entry = timings[key]
	if not entry then
		entry = { calls = 0, total = 0, max = 0 }
		timings[key] = entry
	end
	entry.calls = entry.calls + 1
	entry.total = entry.total + seconds
	if seconds > entry.max then entry.max = seconds end
end

---------------------------------------------------------------------------
-- the measuring wrappers
---------------------------------------------------------------------------
local installed = false
local wrapped = {}
local saved = {}

local function counter(counterField)
	return function(accumulator) accumulator[counterField] = accumulator[counterField] + 1 end
end
local countTrace, countCreate, countDlight = counter("traces"), counter("creates"), counter("dlights")
local countQuad, countSprite = counter("quads"), counter("sprites")

local function wrapLib(library, functionName, countFunction)
	local original = library[functionName]
	if not original then return end
	saved[#saved + 1] = { library, functionName, original }
	library[functionName] = function(...)
		if inHook > 0 then forEachAccumulator(countFunction) end
		return original(...)
	end
end

local function install()
	if installed then return end
	installed = true
	for event, hooks in pairs(hook.GetTable()) do
		if not string.find(event, "/", 1, true) then
			for name, hookFunction in pairs(hooks) do
				if isOurs(name) and isfunction(hookFunction) then
					local key = event .. " / " .. name
					local function wrapper(...)
						inHook = inHook + 1
						local startTime = SysTime()
						local result1, result2, result3, result4, result5, result6 = hookFunction(...)
						local seconds = SysTime() - startTime
						for _, accumulator in pairs(accumulators) do addTime(accumulator.hooks, key, seconds) end
						inHook = inHook - 1
						return result1, result2, result3, result4, result5, result6
					end
					hook.Add(event, name, wrapper)
					table.insert(wrapped, { event, name, hookFunction, wrapper })
				end
			end
		end
	end
	hook.Add("Think", "audio_dbg_perf_frame", function()
		local frameTime = RealFrameTime()
		for _, accumulator in pairs(accumulators) do
			accumulator.frames = accumulator.frames + 1
			accumulator.frameSum = accumulator.frameSum + frameTime
			if frameTime > accumulator.frameMax then accumulator.frameMax = frameTime end
		end
	end)
	AudioEngine.PerfCar = function(entity, seconds)
		for _, accumulator in pairs(accumulators) do addTime(accumulator.cars, entity, seconds) end
	end
	wrapLib(util, "TraceLine", countTrace)
	wrapLib(util, "TraceHull", countTrace)
	wrapLib(_G, "CreateSound", countCreate)
	wrapLib(_G, "DynamicLight", countDlight)
	wrapLib(render, "DrawQuadEasy", countQuad)
	wrapLib(render, "DrawSprite", countSprite)
	local patchMeta = FindMetaTable("CSoundPatch")
	for _, method in ipairs(SOUND_METHODS) do
		wrapLib(patchMeta, method, function(accumulator) accumulator.sound[method] = (accumulator.sound[method] or 0) + 1 end)
	end
end

local function uninstall()
	if not installed then return end
	installed = false
	for _, wrap in ipairs(wrapped) do
		local hooks = hook.GetTable()[wrap[1]]
		if hooks and hooks[wrap[2]] == wrap[4] then hook.Add(wrap[1], wrap[2], wrap[3]) end
	end
	wrapped = {}
	hook.Remove("Think", "audio_dbg_perf_frame")
	AudioEngine.PerfCar = nil
	for i = #saved, 1, -1 do
		local savedEntry = saved[i]
		savedEntry[1][savedEntry[2]] = savedEntry[3]
	end
	saved = {}
end
PERF.Uninstall = uninstall

local function refresh()
	if next(accumulators) then install() else uninstall() end
end

---------------------------------------------------------------------------
-- snapshot: what's loaded and playing (no timing)
---------------------------------------------------------------------------
local wavBytes = setmetatable({}, { __mode = "k" })

-- the bytes of a baked bank's WAV files (the engine loads them when the bank is used)
local function bakedBytes(bank)
	if wavBytes[bank] then return wavBytes[bank] end
	local total = 0
	for name in pairs(bank.peak or {}) do
		if isstring(name) and string.EndsWith(name, ".wav") then total = total + (file.Size("sound/" .. name, "GAME") or 0) end
	end
	wavBytes[bank] = total

	return total
end

local function bankMemory()
	local memory = { baked = 0, bakedBytes = 0, generated = 0, genSamples = 0, building = 0 }
	local Bank = AudioEngine.Bank
	if not Bank then return memory end
	local function addBank(bank)
		if not bank then return end
		if bank.baked then
			memory.baked = memory.baked + 1
			memory.bakedBytes = memory.bakedBytes + bakedBytes(bank)
		else
			memory.generated = memory.generated + 1
			memory.genSamples = memory.genSamples + (bank.samples or 0)
			if not bank.ready then memory.building = memory.building + 1 end
		end
	end
	for _, bank in pairs(Bank.list or {}) do addBank(bank) end
	addBank(Bank.env)
	memory.count = Bank.count or 0
	local conVar = GetConVar("audio_engine_maxsounds")
	memory.max = conVar and conVar:GetInt() or 0
	memory.queue = #(Bank.queue or {})

	return memory
end

local function snapshot()
	local snap = { cars = {}, patches = 0, playing = 0, running = 0, lights = 0, vehicles = 0 }
	local eye = LocalPlayer():EyePos()
	for _, entity in ipairs(ents.FindByClass("prop_vehicle_jeep*")) do
		snap.vehicles = snap.vehicles + 1
		local car = AudioEngine.GetClientCar and AudioEngine.GetClientCar(entity)
		if car then
			local patchCount, playing = 0, 0
			for _, patch in pairs(car.patches or {}) do
				patchCount = patchCount + 1
				if patch:IsPlaying() then playing = playing + 1 end
			end
			if car.oneShot and car.oneShot.patch then
				patchCount = patchCount + 1
				if car.oneShot.patch:IsPlaying() then playing = playing + 1 end
			end
			local carConfig = AudioEngine.GetCarConfig(entity)
			local bank = car.bank
			local engineOn = entity:GetNW2Bool("audio_on", false)
			local lights = entity:GetNW2Int("audio_lights", 0) > 0
			snap.patches, snap.playing = snap.patches + patchCount, snap.playing + playing
			if engineOn then snap.running = snap.running + 1 end
			if lights then snap.lights = snap.lights + 1 end
			snap.cars[entity] = {
				name = carConfig and carConfig.name or entity:GetModel(), distanceMeters = entity:GetPos():Distance(eye) * UNITS_TO_M, on = engineOn, lights = lights,
				patches = patchCount, playing = playing, mode = car.restState or "active",
				bank = not bank and "none" or bank.baked and "baked" or bank.ready and "generated" or "building",
			}
		end
	end
	snap.banks = bankMemory()
	snap.siren = POLICE_SIREN and POLICE_SIREN.Stats and POLICE_SIREN.Stats() or nil
	snap.luaKB = collectgarbage("count")

	return snap
end
PERF.Snapshot = snapshot

local function memoryLines(snap, printLine)
	local banks = snap.banks
	local genLua, genEngine = banks.genSamples * LUA_BYTES_PER_SAMPLE, banks.genSamples * ENGINE_BYTES_PER_SAMPLE
	printLine(string.format("Sound banks: %d baked (WAV files %.1f MB in the engine), %d generated (%.1f MB of Lua tables + ~%.1f MB in the engine)%s",
		banks.baked, banks.bakedBytes / MB, banks.generated, genLua / MB, genEngine / MB,
		banks.building > 0 and string.format(", %d still building", banks.building) or ""))
	printLine(string.format("  generated engines count %d of audio_engine_maxsounds %d; %d in the build queue", banks.count or 0, banks.max or 0, banks.queue or 0))
	local siren = snap.siren
	if siren then
		local sampleRate = (siren.sampleRate or 44100)
		printLine(string.format("Siren: %d tone versions built (%.1f s of audio: %.1f MB of Lua tables + ~%.1f MB in the engine), %d siren cars near, %d sounding, %d patches (%d playing)%s",
			siren.tonesBuilt * 2, siren.samples / sampleRate, siren.samples * LUA_BYTES_PER_SAMPLE / MB, siren.samples * ENGINE_BYTES_PER_SAMPLE / MB,
			siren.cars, siren.sounding, siren.patches, siren.playing, siren.building > 0 and string.format(", %d building", siren.building) or ""))
	end
	printLine(string.format("Client Lua memory (all addons): %.1f MB", snap.luaKB / 1024))
end

local function printSnapshot(snap, printLine, timing)
	printLine(string.format("Cars: %d vehicles, %d with the procedural engine (%d running, %d lights on)",
		snap.vehicles, table.Count(snap.cars), snap.running, snap.lights))
	printLine(string.format("Engine sound patches: %d held, %d playing (all the game's sounds share a limited number of channels)",
		snap.patches, snap.playing))
	local rows = {}
	for entity, row in pairs(snap.cars) do
		local carTiming = timing and timing[entity]
		row.ms = carTiming and carTiming.total / math.max(timing.frames, 1) * 1000 or 0
		row.max = carTiming and carTiming.max * 1000 or 0
		table.insert(rows, row)
	end
	table.sort(rows, function(first, second)
		if first.ms ~= second.ms then return first.ms > second.ms end
		return first.distanceMeters < second.distanceMeters
	end)
	printLine("  car                                     dist m  engine  state    bank        patches(playing)" .. (timing and "   ms/frame   worst ms" or ""))
	for _, row in ipairs(rows) do
		printLine(string.format("  %-38s %7.0f  %-6s  %-7s  %-10s  %3d (%d)%s", string.sub(row.name, 1, 38), row.distanceMeters, row.on and "on" or "off",
			row.mode, row.bank, row.patches, row.playing, timing and string.format("        %8.4f %10.3f", row.ms, row.max) or ""))
	end
	printLine("  (state: active = every frame; parked = idle sound only, 10x a second while you move slowly; asleep = engine off,"
		.. " 4x a second; far = past audio_engine_range, silent; dormant = out of view)")
	memoryLines(snap, printLine)
end

---------------------------------------------------------------------------
-- the timing summary of an accumulator
---------------------------------------------------------------------------
local function timing(accumulator)
	local frames = math.max(accumulator.frames, 1)
	local hooks, total = {}, 0
	for key, hookTiming in pairs(accumulator.hooks) do
		table.insert(hooks, { key = key, ms = hookTiming.total * 1000 / frames, max = hookTiming.max * 1000, calls = hookTiming.calls / frames })
		total = total + hookTiming.total
	end
	table.sort(hooks, function(first, second) return first.ms > second.ms end)
	local cars = { frames = frames }
	local carTotal = 0
	for entity, carTiming in pairs(accumulator.cars) do
		cars[entity] = carTiming
		carTotal = carTotal + carTiming.total
	end
	local sound, soundTotal = {}, 0
	for method, count in pairs(accumulator.sound) do
		table.insert(sound, string.format("%s %.1f", method, count / frames))
		soundTotal = soundTotal + count
	end
	table.sort(sound)

	return {
		seconds = SysTime() - accumulator.startTime, frames = frames, frameMs = accumulator.frameSum / frames * 1000, frameMax = accumulator.frameMax * 1000,
		hooks = hooks, totalMs = total * 1000 / frames, carMs = carTotal * 1000 / frames, cars = cars,
		traces = accumulator.traces / frames, sound = sound, soundPerFrame = soundTotal / frames, creates = accumulator.creates,
		dlights = accumulator.dlights / frames, quads = accumulator.quads / frames, sprites = accumulator.sprites / frames,
	}
end

local function printReport(timingSummary, snap, printLine)
	printLine(string.format("==== Audio Engine performance, CLIENT: %.1f s, %d frames, %.1f fps (frame %.2f ms average, %.1f ms worst) ====",
		timingSummary.seconds, timingSummary.frames, 1000 / math.max(timingSummary.frameMs, 0.001), timingSummary.frameMs, timingSummary.frameMax))
	printLine(string.format("Addon Lua: %.3f ms per frame (%.1f%% of the frame); the cars' own updates %.3f ms of it",
		timingSummary.totalMs, timingSummary.totalMs / math.max(timingSummary.frameMs, 0.001) * 100, timingSummary.carMs))
	printLine("  hook (event / name)                               ms/frame   worst ms  calls/frame")
	for _, hookTiming in ipairs(timingSummary.hooks) do
		printLine(string.format("  %-48s %8.4f %10.3f %10.2f", hookTiming.key, hookTiming.ms, hookTiming.max, hookTiming.calls))
	end
	printLine(string.format("Per frame: %.1f sound commands (%s), %.1f traces, %.1f dynamic lights, %.1f lens quads, %.1f glow sprites; %d sounds created",
		timingSummary.soundPerFrame, table.concat(timingSummary.sound, ", "), timingSummary.traces, timingSummary.dlights, timingSummary.quads, timingSummary.sprites, timingSummary.creates))
	printSnapshot(snap, printLine, timingSummary.cars)
end

---------------------------------------------------------------------------
-- commands
---------------------------------------------------------------------------
local function allowed()
	if EngineDebug.Allowed(LocalPlayer()) then return true end
	report(EngineDebug.Enabled() and "Superadmins only." or "The debug tools are off on this server (audio_engine_debug 0).")

	return false
end

local capture
concommand.Add("audio_engine_perf", function(_, _, args)
	if not allowed() then return end
	if capture then
		report("A capture is already running.")
		return
	end
	local seconds = math.Clamp(tonumber(args[1]) or 10, 1, 120)
	local realm = string.lower(args[2] or "both")
	if realm == "both" or realm == "server" then
		net.Start("audio_dbg_perf_cap")
		net.WriteFloat(seconds)
		net.SendToServer()
	end
	if realm == "both" or realm == "client" then
		capture = newAccumulator()
		accumulators.capture = capture
		refresh()
		timer.Create("audio_dbg_perf_capture", seconds, 1, function()
			local timingSummary = timing(capture)
			accumulators.capture, capture = nil, nil
			refresh()
			printReport(timingSummary, snapshot(), print)
			report("Report printed to the console.")
		end)
	end
	report(string.format("Measuring for %.0f s (%s); the report goes to the console. Play normally meanwhile.", seconds, realm))
end, nil, "Performance capture (debug): audio_engine_perf [seconds = 10] [client | server | both]")

concommand.Add("audio_engine_perf_snapshot", function()
	if not allowed() then return end
	printSnapshot(snapshot(), print)
end, nil, "What the Audio Engine has loaded and playing right now: cars, sound patches, memory (debug)")

---------------------------------------------------------------------------
-- the live overlay
---------------------------------------------------------------------------
local hudOn = false
local hudAcc, hudTiming, hudSnapshot, serverStats
local nextHud, nextSnapshot = 0, 0

local function setHud(turnOn)
	if turnOn == hudOn then return end
	hudOn = turnOn
	if turnOn then
		hudAcc = newAccumulator()
		accumulators.hud = hudAcc
		hudTiming, hudSnapshot, serverStats = nil, nil, nil
	else
		accumulators.hud, hudAcc = nil, nil
	end
	refresh()
	net.Start("audio_dbg_perf_sub")
	net.WriteBool(turnOn)
	net.SendToServer()
	if turnOn then
		hook.Add("HUDPaint", "audio_dbg_perf", PERF.Paint)
	else
		hook.Remove("HUDPaint", "audio_dbg_perf")
	end
end

concommand.Add("audio_engine_perf_hud", function(_, _, args)
	local wantOn = args[1] and args[1] ~= "0" or (not args[1] and not hudOn)
	if wantOn and not allowed() then return end
	setHud(wantOn)
end, nil, "Live performance overlay (debug): audio_engine_perf_hud [0/1]")

net.Receive("audio_dbg_perf_stats", function()
	serverStats = net.ReadTable()
end)

local HUD_FONT = "DebugFixed"
local LINE_HEIGHT = 13

function PERF.Paint()
	local now = SysTime()
	if now >= nextHud and hudAcc then
		nextHud = now + HUD_EVERY
		hudTiming = timing(hudAcc)
		hudAcc = newAccumulator()
		accumulators.hud = hudAcc
	end
	if now >= nextSnapshot then
		nextSnapshot = now + SNAPSHOT_EVERY
		hudSnapshot = snapshot()
	end
	local lines = {}
	local function printLine(line) lines[#lines + 1] = line end
	printLine("AUDIO ENGINE PERF (audio_engine_perf_hud 0 to close)")
	local timingSummary = hudTiming
	if timingSummary then
		printLine(string.format("client %.0f fps  frame %.2f ms  addon %.3f ms (%.1f%%)  cars %.3f ms",
			1000 / math.max(timingSummary.frameMs, 0.001), timingSummary.frameMs, timingSummary.totalMs, timingSummary.totalMs / math.max(timingSummary.frameMs, 0.001) * 100, timingSummary.carMs))
		for i = 1, math.min(5, #timingSummary.hooks) do
			printLine(string.format("  %-44s %7.3f ms  (worst %.2f)", timingSummary.hooks[i].key, timingSummary.hooks[i].ms, timingSummary.hooks[i].max))
		end
		printLine(string.format("per frame: %.0f sound cmds  %.1f traces  %.1f dlights  %.0f quads  %.0f sprites",
			timingSummary.soundPerFrame, timingSummary.traces, timingSummary.dlights, timingSummary.quads, timingSummary.sprites))
	end
	local snap = hudSnapshot
	if snap then
		printLine(string.format("cars %d (%d running, %d lights)  patches %d held / %d playing",
			table.Count(snap.cars), snap.running, snap.lights, snap.patches, snap.playing))
		local banks = snap.banks
		printLine(string.format("banks: %d baked %.1f MB wav, %d generated %.1f MB Lua + %.1f MB engine; Lua %.1f MB",
			banks.baked, banks.bakedBytes / MB, banks.generated, banks.genSamples * LUA_BYTES_PER_SAMPLE / MB, banks.genSamples * ENGINE_BYTES_PER_SAMPLE / MB, snap.luaKB / 1024))
		if snap.siren then
			printLine(string.format("siren: %d versions built %.1f MB Lua, %d sounding, %d patches", snap.siren.tonesBuilt * 2,
				snap.siren.samples * LUA_BYTES_PER_SAMPLE / MB, snap.siren.sounding, snap.siren.patches))
		end
		-- the costliest cars (by the last second's timing), else the nearest
		local rows = {}
		for entity, row in pairs(snap.cars) do
			local carTiming = timingSummary and timingSummary.cars[entity]
			row.ms = carTiming and carTiming.total / timingSummary.frames * 1000 or 0
			table.insert(rows, row)
		end
		table.sort(rows, function(first, second)
			if first.ms ~= second.ms then return first.ms > second.ms end
			return first.distanceMeters < second.distanceMeters
		end)
		for i = 1, math.min(8, #rows) do
			local row = rows[i]
			printLine(string.format("  %-30s %5.0f m %-3s %-9s %2d/%-2d  %.4f ms", string.sub(row.name, 1, 30), row.distanceMeters, row.on and "on" or "off",
				row.bank, row.playing, row.patches, row.ms))
		end
	end
	local server = serverStats
	if server then
		printLine(string.format("server: addon %.3f ms/tick (%.1f%% of %.1f ms)  %.1f traces/tick  Lua %.1f MB",
			server.totalMsTick, server.totalMsTick / math.max(server.tickMs, 0.001) * 100, server.tickMs, server.tracesTick, server.luaKB / 1024))
		printLine(string.format("  NW2 %.1f changes/s  net %.1f msgs/s %.0f B/s  cars %d tracked, %d running, %d driven",
			server.nwSec, server.netSec, server.netBytesSec, server.cars.tracked, server.cars.on, server.cars.driven))
		for _, hookTiming in ipairs(server.hooks or {}) do
			printLine(string.format("  %-44s %7.4f ms (worst %.2f)", hookTiming.key, hookTiming.msTick, hookTiming.maxMs))
		end
	end
	surface.SetFont(HUD_FONT)
	local width = 0
	for _, line in ipairs(lines) do width = math.max(width, (surface.GetTextSize(line))) end
	local left, top = ScrW() - width - 24, 80
	surface.SetDrawColor(0, 0, 0, 200)
	surface.DrawRect(left - 8, top - 6, width + 16, #lines * LINE_HEIGHT + 12)
	for i, line in ipairs(lines) do
		draw.SimpleText(line, HUD_FONT, left, top + (i - 1) * LINE_HEIGHT, i == 1 and Color(255, 190, 60) or color_white)
	end
end
