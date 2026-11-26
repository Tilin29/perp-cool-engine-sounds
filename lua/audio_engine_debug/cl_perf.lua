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
if EngineDebug.PerfClient and IsValid(EngineDebug.PerfClient.clearButton) then EngineDebug.PerfClient.clearButton:Remove() end
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
				patches = patchCount, playing = playing,
				mode = car.overBudget and not car.outOfRange and "budget" or car.restState or "active",
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
		.. " 4x a second; far = past audio_engine_range, silent; budget = past audio_engine_maxcars, silent; dormant = out of view)")
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
--[[
	One row per figure: now, the average and the peak over the last HISTORY_SECONDS (the peak is the
	worst: the highest, or for the frame rate the lowest), its unit, and a bar per second for that
	minute, newest on the right. A client sample is taken once a second (that second's timings + a
	snapshot), a server one as its figures arrive (once a second). Figures with good / warn limits are
	coloured green / amber / red; the others (counts, memory) are drawn in their section's colour.
	Sizes are design pixels at 1080p, scaled with the screen height.
]]
local HISTORY_SECONDS = 60
local hudOn = false
local hudAcc, hudTiming, hudSnapshot, serverStats
local clientHistory, serverHistory = {}, {}
local nextHud, nextSnapshot = 0, 0
local lastPanelHeight = 0

local function pushSample(history, sample)
	history[#history + 1] = sample
	if #history > HISTORY_SECONDS then table.remove(history, 1) end
end

local function clientSample(timingSummary, snap)
	local frameMs = math.max(timingSummary.frameMs, 0.001)
	local banks = snap.banks
	local sirenPlaying = snap.siren and snap.siren.playing or 0
	local sirenHeld = snap.siren and snap.siren.patches or 0
	local heard = 0
	for _, row in pairs(snap.cars) do
		if row.playing > 0 then heard = heard + 1 end
	end
	local generatedBytes = banks.genSamples * (LUA_BYTES_PER_SAMPLE + ENGINE_BYTES_PER_SAMPLE)

	return {
		fps = 1000 / frameMs, fpsLow = 1000 / math.max(timingSummary.frameMax, 0.001),
		frameMs = timingSummary.frameMs, frameWorst = timingSummary.frameMax,
		addonMs = timingSummary.totalMs, addonShare = timingSummary.totalMs / frameMs * 100, carMs = timingSummary.carMs,
		traces = timingSummary.traces, soundCommands = timingSummary.soundPerFrame,
		playing = snap.playing + sirenPlaying, enginePlaying = snap.playing, sirenPlaying = sirenPlaying,
		held = snap.patches + sirenHeld, heard = heard,
		luaMB = snap.luaKB / 1024, bankMB = (banks.bakedBytes + generatedBytes) / MB,
	}
end

local function serverSample(stats)
	return {
		serverMs = stats.totalMsTick, serverShare = stats.totalMsTick / math.max(stats.tickMs, 0.001) * 100,
		netKB = stats.netBytesSec / 1024, netMessages = stats.netSec, networkVars = stats.nwSec,
		traces = stats.tracesTick, luaMB = stats.luaKB / 1024,
	}
end

local function setHud(turnOn)
	if turnOn == hudOn then return end
	hudOn = turnOn
	if turnOn then
		hudAcc = newAccumulator()
		accumulators.hud = hudAcc
		hudTiming, hudSnapshot, serverStats = nil, nil, nil
		clientHistory, serverHistory = {}, {}
		nextHud, nextSnapshot = SysTime() + HUD_EVERY, 0
	else
		accumulators.hud, hudAcc = nil, nil
		if IsValid(PERF.clearButton) then PERF.clearButton:Remove() end
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

local clearedAt = -math.huge

-- the 60 s averages, peaks and graphs start again from now
local function clearHistory()
	clientHistory, serverHistory = {}, {}
	clearedAt = SysTime()
end

concommand.Add("audio_engine_perf_hud_clear", clearHistory, nil,
	"Clears the performance overlay's last 60 s (averages, peaks, graphs) (debug)")

net.Receive("audio_dbg_perf_stats", function()
	serverStats = net.ReadTable()
	pushSample(serverHistory, serverSample(serverStats))
end)

local HUD = {
	top = 70, right = 20, width = 560, padding = 12,
	rowHeight = 18, sectionHeight = 24, sectionGap = 6,
	-- columns: the numbers are right-aligned at these, the unit and the graph start at theirs
	nowRight = 250, averageRight = 312, peakRight = 374, unitLeft = 382, graphLeft = 428,
	graphBarGap = 1, carRows = 5, hookRows = 3, nameLength = 28, hookNameLength = 46,
	carColumns = { 0, 230, 290, 370, 450 },   -- car, distance, state, sounds, ms
}
local HUD_COLORS = {
	title = Color(255, 255, 255), dim = Color(130, 135, 145), label = Color(200, 205, 215), text = Color(240, 240, 240),
	good = Color(90, 225, 120), warn = Color(255, 195, 60), bad = Color(255, 85, 85),
	background = Color(14, 16, 22, 225), graphBase = Color(255, 255, 255, 18), rowShade = Color(255, 255, 255, 6),
}
local STATE_COLORS = {
	active = HUD_COLORS.good, parked = Color(120, 190, 255), budget = HUD_COLORS.warn,
	far = HUD_COLORS.dim, asleep = HUD_COLORS.dim, dormant = HUD_COLORS.dim,
}
local STATE_ORDER = { "active", "parked", "budget", "far", "asleep", "dormant" }
local CAR_MS_GOOD, CAR_MS_WARN = 0.05, 0.2

--[[
	key = the sample field shown; peakKey = the field the peak is taken from (the second's worst frame);
	good / warn = limits (higherIsBetter: at least them); no limits = drawn in the section's colour.
]]
local SECTIONS = {
	{
		title = "CLIENT", accent = Color(80, 165, 255), history = "client",
		metrics = {
			{ label = "Frame rate", key = "fps", peakKey = "fpsLow", format = "%.0f", unit = "fps", good = 60, warn = 30, higherIsBetter = true },
			{ label = "Frame time", key = "frameMs", peakKey = "frameWorst", format = "%.1f", unit = "ms", good = 16.7, warn = 33.3 },
			{ label = "Addon Lua", key = "addonMs", format = "%.2f", unit = "ms", good = 0.5, warn = 1.5 },
			{ label = "Addon share", key = "addonShare", format = "%.1f", unit = "%", good = 5, warn = 15 },
			{ label = "Car updates", key = "carMs", format = "%.2f", unit = "ms", good = 0.3, warn = 1 },
			{ label = "Traces", key = "traces", format = "%.1f", unit = "/frame", good = 10, warn = 30 },
		},
	},
	{
		title = "SOUND", accent = Color(205, 110, 255), history = "client",
		metrics = {
			{ label = "Sounds playing", key = "playing", format = "%d", unit = "", good = 100, warn = 200 },
			{ label = "  engines", key = "enginePlaying", format = "%d", unit = "" },
			{ label = "  sirens", key = "sirenPlaying", format = "%d", unit = "" },
			{ label = "Patches held", key = "held", format = "%d", unit = "" },
			{ label = "Cars heard", key = "heard", format = "%d", unit = "cars" },
			{ label = "Sound commands", key = "soundCommands", format = "%.0f", unit = "/frame", good = 150, warn = 400 },
		},
	},
	{
		title = "MEMORY", accent = Color(255, 150, 60), history = "client",
		metrics = {
			{ label = "Lua heap", key = "luaMB", format = "%.0f", unit = "MB" },
			{ label = "Sound banks", key = "bankMB", format = "%.1f", unit = "MB" },
		},
	},
	{
		title = "SERVER", accent = Color(50, 215, 190), history = "server",
		metrics = {
			{ label = "Addon Lua", key = "serverMs", format = "%.2f", unit = "ms/tick", good = 1, warn = 3 },
			{ label = "Addon share", key = "serverShare", format = "%.1f", unit = "%", good = 5, warn = 15 },
			{ label = "Network", key = "netKB", format = "%.1f", unit = "KB/s", good = 20, warn = 60 },
			{ label = "Net messages", key = "netMessages", format = "%.0f", unit = "/s" },
			{ label = "NW2 changes", key = "networkVars", format = "%.0f", unit = "/s" },
			{ label = "Traces", key = "traces", format = "%.1f", unit = "/tick" },
			{ label = "Lua heap", key = "luaMB", format = "%.0f", unit = "MB" },
		},
	},
}
local CARS_ACCENT = Color(255, 215, 70)
local HOOKS_ACCENT = Color(160, 170, 185)
local HUD_FONT, HUD_BOLD_FONT, HUD_SMALL_FONT = "audio_dbg_perf_body", "audio_dbg_perf_bold", "audio_dbg_perf_small"

local hudScale

local function scaled(pixels)
	return math.Round(pixels * hudScale)
end

local function updateFonts()
	local scale = ScrH() / 1080
	if scale == hudScale then return end
	hudScale = scale
	surface.CreateFont(HUD_FONT, { font = "Roboto", size = scaled(16), weight = 500 })
	surface.CreateFont(HUD_BOLD_FONT, { font = "Roboto", size = scaled(16), weight = 800 })
	surface.CreateFont(HUD_SMALL_FONT, { font = "Roboto", size = scaled(13), weight = 500 })
end

local function rate(metric, value, accent)
	if not metric.good then return accent end
	if metric.higherIsBetter then
		return value >= metric.good and HUD_COLORS.good or value >= metric.warn and HUD_COLORS.warn or HUD_COLORS.bad
	end

	return value <= metric.good and HUD_COLORS.good or value <= metric.warn and HUD_COLORS.warn or HUD_COLORS.bad
end

local function shorten(text, length)
	text = tostring(text)
	if #text <= length then return text end

	return string.sub(text, 1, length - 1) .. "~"
end

-- average of key, the worst of peakKey, and the largest value for the graph's scale
local function summarise(history, metric)
	local peakKey = metric.peakKey or metric.key
	local sum, peak, largest = 0, nil, 0
	for _, sample in ipairs(history) do
		local value, peakValue = sample[metric.key] or 0, sample[peakKey] or 0
		sum = sum + value
		if peak == nil or (metric.higherIsBetter and peakValue < peak) or (not metric.higherIsBetter and peakValue > peak) then
			peak = peakValue
		end
		largest = math.max(largest, value)
	end

	return sum / #history, peak, largest
end

local function drawGraph(history, metric, accent, left, top, width, height)
	surface.SetDrawColor(HUD_COLORS.graphBase)
	surface.DrawRect(left, top + height - 1, width, 1)
	local _, _, largest = summarise(history, metric)
	-- (scaled to the minute's largest value, at least the good limit: small noise stays small)
	local scaleTop = math.max(largest, metric.higherIsBetter and 0 or metric.good or 0, 0.0001)
	local barWidth = width / HISTORY_SECONDS
	local first = HISTORY_SECONDS - #history
	for i, sample in ipairs(history) do
		local value = sample[metric.key] or 0
		local barHeight = math.max(1, math.Round(math.min(value / scaleTop, 1) * height))
		local barLeft = left + math.floor((first + i - 1) * barWidth)
		surface.SetDrawColor(rate(metric, value, accent))
		surface.DrawRect(barLeft, top + height - barHeight, math.max(1, math.floor(barWidth) - HUD.graphBarGap), barHeight)
	end
end

local function drawSectionTitle(title, accent, left, top, width, note)
	local height = scaled(HUD.sectionHeight)
	surface.SetDrawColor(accent.r, accent.g, accent.b, 40)
	surface.DrawRect(left - scaled(HUD.padding), top, width + scaled(HUD.padding) * 2, height)
	surface.SetDrawColor(accent)
	surface.DrawRect(left - scaled(HUD.padding), top, scaled(4), height)
	draw.SimpleText(title, HUD_BOLD_FONT, left, top + height / 2, accent, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	if note then draw.SimpleText(note, HUD_SMALL_FONT, left + width, top + height / 2, HUD_COLORS.dim, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER) end

	return top + height + scaled(HUD.sectionGap) / 2
end

local function drawMetricRow(history, metric, accent, left, top, shade, width)
	local rowHeight = scaled(HUD.rowHeight)
	local middle = top + rowHeight / 2
	if shade then
		surface.SetDrawColor(HUD_COLORS.rowShade)
		surface.DrawRect(left - scaled(4), top, width + scaled(8), rowHeight)
	end
	draw.SimpleText(metric.label, HUD_FONT, left, middle, HUD_COLORS.label, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	local latest = history[#history]
	if not latest then
		draw.SimpleText("...", HUD_FONT, left + scaled(HUD.nowRight), middle, HUD_COLORS.dim, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		return top + rowHeight
	end
	local nowValue = latest[metric.key] or 0
	local average, peak = summarise(history, metric)
	draw.SimpleText(string.format(metric.format, nowValue), HUD_BOLD_FONT, left + scaled(HUD.nowRight), middle,
		rate(metric, nowValue, accent), TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
	draw.SimpleText(string.format(metric.format, average), HUD_FONT, left + scaled(HUD.averageRight), middle,
		rate(metric, average, accent), TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
	draw.SimpleText(string.format(metric.format, peak), HUD_FONT, left + scaled(HUD.peakRight), middle,
		rate(metric, peak, accent), TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
	draw.SimpleText(metric.unit, HUD_SMALL_FONT, left + scaled(HUD.unitLeft), middle, HUD_COLORS.dim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	local graphLeft = left + scaled(HUD.graphLeft)
	drawGraph(history, metric, accent, graphLeft, top + scaled(2), left + width - graphLeft, rowHeight - scaled(4))

	return top + rowHeight
end

local function drawColumnHeader(left, top, width)
	local rowHeight = scaled(HUD.rowHeight)
	local middle = top + rowHeight / 2
	draw.SimpleText("now", HUD_SMALL_FONT, left + scaled(HUD.nowRight), middle, HUD_COLORS.dim, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
	draw.SimpleText("avg", HUD_SMALL_FONT, left + scaled(HUD.averageRight), middle, HUD_COLORS.dim, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
	draw.SimpleText("peak", HUD_SMALL_FONT, left + scaled(HUD.peakRight), middle, HUD_COLORS.dim, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
	draw.SimpleText("last 60 s", HUD_SMALL_FONT, left + width, middle, HUD_COLORS.dim, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)

	return top + rowHeight
end

local function drawCars(snap, timingSummary, left, top, width)
	local rowHeight = scaled(HUD.rowHeight)
	local stateCounts, rows = {}, {}
	for entity, row in pairs(snap.cars) do
		stateCounts[row.mode] = (stateCounts[row.mode] or 0) + 1
		local carTiming = timingSummary and timingSummary.cars[entity]
		row.ms = carTiming and carTiming.total / timingSummary.frames * 1000 or 0
		table.insert(rows, row)
	end
	local note = string.format("%d cars, %d running, %d lights on", #rows, snap.running, snap.lights)
	local y = drawSectionTitle("CARS", CARS_ACCENT, left, top, width, note)
	-- the states as coloured counts on one line
	local x = left
	for _, state in ipairs(STATE_ORDER) do
		if stateCounts[state] then
			local countWidth = draw.SimpleText(tostring(stateCounts[state]), HUD_BOLD_FONT, x, y + rowHeight / 2,
				STATE_COLORS[state], TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			local nameWidth = draw.SimpleText(" " .. state, HUD_FONT, x + countWidth, y + rowHeight / 2,
				HUD_COLORS.label, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			x = x + countWidth + nameWidth + scaled(16)
		end
	end
	y = y + rowHeight
	if #rows == 0 then return y end
	table.sort(rows, function(first, second)
		if first.ms ~= second.ms then return first.ms > second.ms end

		return first.distanceMeters < second.distanceMeters
	end)
	local headers = { "costliest", "dist", "state", "sounds", "ms/frame" }
	for i, header in ipairs(headers) do
		draw.SimpleText(header, HUD_SMALL_FONT, left + scaled(HUD.carColumns[i]), y + rowHeight / 2, HUD_COLORS.dim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end
	y = y + rowHeight
	for i = 1, math.min(HUD.carRows, #rows) do
		local row = rows[i]
		local middle = y + rowHeight / 2
		local columns = {
			{ shorten(row.name, HUD.nameLength), row.on and HUD_COLORS.text or HUD_COLORS.dim },
			{ string.format("%.0f m", row.distanceMeters), HUD_COLORS.label },
			{ row.mode, STATE_COLORS[row.mode] or HUD_COLORS.text },
			{ string.format("%d / %d", row.playing, row.patches), HUD_COLORS.label },
			{ string.format("%.3f", row.ms), row.ms <= CAR_MS_GOOD and HUD_COLORS.good or row.ms <= CAR_MS_WARN and HUD_COLORS.warn or HUD_COLORS.bad },
		}
		for column, entry in ipairs(columns) do
			draw.SimpleText(entry[1], HUD_FONT, left + scaled(HUD.carColumns[column]), middle, entry[2], TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		end
		y = y + rowHeight
	end

	return y
end

local function drawHooks(timingSummary, server, left, top, width)
	local rowHeight = scaled(HUD.rowHeight)
	local y = drawSectionTitle("BUSIEST HOOKS", HOOKS_ACCENT, left, top, width, "ms per frame / tick")
	local function hookRow(side, key, ms)
		local middle = y + rowHeight / 2
		draw.SimpleText(side, HUD_SMALL_FONT, left, middle, HUD_COLORS.dim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(shorten(key, HUD.hookNameLength), HUD_FONT, left + scaled(50), middle, HUD_COLORS.label, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		draw.SimpleText(string.format("%.3f", ms), HUD_BOLD_FONT, left + width, middle, HUD_COLORS.text, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		y = y + rowHeight
	end
	for i = 1, math.min(HUD.hookRows, timingSummary and #timingSummary.hooks or 0) do
		hookRow("client", timingSummary.hooks[i].key, timingSummary.hooks[i].ms)
	end
	for i = 1, math.min(HUD.hookRows, server and #(server.hooks or {}) or 0) do
		hookRow("server", server.hooks[i].key, server.hooks[i].msTick)
	end

	return y
end

--[[
	The clear button: drawn with the overlay, clickable while the context menu (C) is open, through an
	invisible DButton on g_ContextMenu over it (a HUDPaint drawing takes no clicks; a context-menu child
	takes them only with SetMouseInputEnabled). It reads CLEARED for CLEAR_BUTTON.confirmTime after a click.
]]
local CLEAR_BUTTON = {
	width = 104, height = 22, confirmTime = 1,
	idle = Color(255, 85, 85, 45), hover = Color(255, 85, 85, 110), border = Color(255, 110, 110),
	confirmed = Color(90, 225, 120, 70),
}

local function clickableMenuOpen()
	return IsValid(g_ContextMenu) and g_ContextMenu:IsVisible()
end

local function placeClearButton(x, y, buttonWidth, buttonHeight)
	if not clickableMenuOpen() then return end
	local button = PERF.clearButton
	if not IsValid(button) then
		button = vgui.Create("DButton", g_ContextMenu)
		button:SetText("")
		button:SetMouseInputEnabled(true)
		button.Paint = function() end
		button.DoClick = clearHistory
		PERF.clearButton = button
	end
	button:SetPos(x, y)
	button:SetSize(buttonWidth, buttonHeight)
end

local function drawClearButton(x, y, buttonWidth, buttonHeight)
	placeClearButton(x, y, buttonWidth, buttonHeight)
	local button = PERF.clearButton
	local hovered = clickableMenuOpen() and IsValid(button) and button:IsHovered()
	local confirmed = SysTime() - clearedAt < CLEAR_BUTTON.confirmTime
	local fill = confirmed and CLEAR_BUTTON.confirmed or hovered and CLEAR_BUTTON.hover or CLEAR_BUTTON.idle
	draw.RoundedBox(4, x, y, buttonWidth, buttonHeight, confirmed and HUD_COLORS.good or CLEAR_BUTTON.border)
	draw.RoundedBox(4, x + 1, y + 1, buttonWidth - 2, buttonHeight - 2, HUD_COLORS.background)
	draw.RoundedBox(4, x + 1, y + 1, buttonWidth - 2, buttonHeight - 2, fill)
	local label = confirmed and "CLEARED" or "CLEAR 60 s"
	draw.SimpleText(label, HUD_BOLD_FONT, x + buttonWidth / 2, y + buttonHeight / 2, HUD_COLORS.text, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end

function PERF.Paint()
	local now = SysTime()
	if now >= nextSnapshot then
		nextSnapshot = now + SNAPSHOT_EVERY
		hudSnapshot = snapshot()
	end
	if now >= nextHud and hudAcc then
		nextHud = now + HUD_EVERY
		hudTiming = timing(hudAcc)
		hudAcc = newAccumulator()
		accumulators.hud = hudAcc
		pushSample(clientHistory, clientSample(hudTiming, hudSnapshot))
	end
	updateFonts()
	local width, padding = scaled(HUD.width), scaled(HUD.padding)
	local left, top = ScrW() - width - padding - scaled(HUD.right), scaled(HUD.top)
	-- (the height is the last frame's: the panel is drawn before its rows)
	draw.RoundedBox(6, left - padding, top - padding, width + padding * 2, lastPanelHeight, HUD_COLORS.background)
	draw.SimpleText("AUDIO ENGINE PERFORMANCE", HUD_BOLD_FONT, left, top, HUD_COLORS.title)
	local buttonWidth, buttonHeight = scaled(CLEAR_BUTTON.width), scaled(CLEAR_BUTTON.height)
	local buttonLeft, buttonTop = left + width - buttonWidth, top - scaled(2)
	drawClearButton(buttonLeft, buttonTop, buttonWidth, buttonHeight)
	local hint = clickableMenuOpen() and "perf_hud 0 closes" or "hold C to click  /  perf_hud 0 closes"
	draw.SimpleText(hint, HUD_SMALL_FONT, buttonLeft - scaled(10), top + scaled(2), HUD_COLORS.dim, TEXT_ALIGN_RIGHT)
	local y = drawColumnHeader(left, top + scaled(HUD.rowHeight), width)
	for _, section in ipairs(SECTIONS) do
		local history = section.history == "server" and serverHistory or clientHistory
		local note = section.history == "server" and not serverStats and "waiting for the server..." or nil
		y = drawSectionTitle(section.title, section.accent, left, y + scaled(HUD.sectionGap), width, note)
		for i, metric in ipairs(section.metrics) do
			y = drawMetricRow(history, metric, section.accent, left, y, i % 2 == 0, width)
		end
	end
	if hudSnapshot then y = drawCars(hudSnapshot, hudTiming, left, y + scaled(HUD.sectionGap), width) end
	y = drawHooks(hudTiming, serverStats, left, y + scaled(HUD.sectionGap), width)
	lastPanelHeight = y - top + padding * 2
end
