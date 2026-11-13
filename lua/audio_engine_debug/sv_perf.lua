--[[
	Audio Engine debug module: performance profiler (server). Not part of the final addon.

	Nothing here runs until asked: the measuring wrappers are put on only while a capture runs or a
	superadmin has the live overlay open (cl_perf.lua), and taken off again after.

	  capture (audio_engine_perf on the client): times every hook of the addon and the siren for the
	          requested seconds and prints a report to the requester's console
	  live    (audio_engine_perf_hud 1): the same figures sent to the overlay once a second
	  stress  audio_engine_perf_spawn <count> [car | mixed] [lights 0/1] [mph] [grid | race]: spawns PERP
	          cars with their engines running (and the emergency lights on, if asked). grid: in front of
	          you, driving away at mph if given (accelerating there, then holding it). race: a zig-zag
	          column with random gaps down the road, coming at you and passing on your right (drive-by).
	          audio_engine_perf_clear removes them

	Measured while on:
	  hooks   time per hook (event / name) per tick: average and worst
	  traces  util.TraceLine / TraceHull calls made inside the addon's hooks
	  NW2     changes of the addon's networked vars (audio_*, siren_*): each change is sent to the
	          players that see the car
	  net     the addon's net messages and their bytes
	  cars    tracked vehicles, engines on, drivers, lights on; Lua memory of the server
]]

local AudioEngine = AUDIO_ENGINE
local EngineDebug = AudioEngine.Debug

util.AddNetworkString("audio_dbg_perf_sub")
util.AddNetworkString("audio_dbg_perf_cap")
util.AddNetworkString("audio_dbg_perf_stats")

-- (Lua refresh: take the previous load's wrappers off before this one starts)
if EngineDebug.PerfServer and EngineDebug.PerfServer.Uninstall then EngineDebug.PerfServer.Uninstall() end
local PERF = {}
EngineDebug.PerfServer = PERF

local OUR_HOOK_PATTERNS = { "^audio_engine", "^police_siren" }
local NW_KEYS = { "^audio_", "^siren_" }
local NET_NAMES = { "^audio_", "^police_siren" }
local SEND_EVERY = 1

local function matchesAny(name, patterns)
	if not isstring(name) then return false end
	for _, pattern in ipairs(patterns) do
		if string.find(name, pattern) then return true end
	end

	return false
end

---------------------------------------------------------------------------
-- the measuring wrappers: on only while someone is measuring
---------------------------------------------------------------------------
local installed = false
local wrapped = {}    -- { event, name, original, wrapper }
local saved = {}      -- original library / meta functions
local stats           -- the figures since the last reset
local inHook = 0

local function resetStats()
	stats = { startTime = SysTime(), ticks = 0, hooks = {}, traces = 0, nw = {}, net = {}, netBytes = 0 }
end

local function addHook(key, seconds)
	local entry = stats.hooks[key]
	if not entry then
		entry = { calls = 0, total = 0, max = 0 }
		stats.hooks[key] = entry
	end
	entry.calls = entry.calls + 1
	entry.total = entry.total + seconds
	if seconds > entry.max then entry.max = seconds end
end

local function wrapHooks()
	for event, hooks in pairs(hook.GetTable()) do
		if not string.find(event, "/", 1, true) then
			for name, hookFunction in pairs(hooks) do
				if matchesAny(name, OUR_HOOK_PATTERNS) and isfunction(hookFunction) then
					local key = event .. " / " .. name
					local function wrapper(...)
						inHook = inHook + 1
						local startTime = SysTime()
						local result1, result2, result3, result4, result5, result6 = hookFunction(...)
						addHook(key, SysTime() - startTime)
						inHook = inHook - 1
						return result1, result2, result3, result4, result5, result6
					end
					hook.Add(event, name, wrapper)
					table.insert(wrapped, { event, name, hookFunction, wrapper })
				end
			end
		end
	end
end

local NW_SETTERS = { "SetNW2Int", "SetNW2Float", "SetNW2Bool", "SetNW2String", "SetNW2Entity", "SetNW2Vector", "SetNW2Angle" }
local NW_GETTERS = { SetNW2Int = "GetNW2Int", SetNW2Float = "GetNW2Float", SetNW2Bool = "GetNW2Bool", SetNW2String = "GetNW2String",
	SetNW2Entity = "GetNW2Entity", SetNW2Vector = "GetNW2Vector", SetNW2Angle = "GetNW2Angle" }

local poll

local function install()
	if installed then return end
	installed = true
	resetStats()
	wrapHooks()
	hook.Add("Tick", "audio_dbg_perf_tick", function() stats.ticks = stats.ticks + 1 end)
	timer.Create("audio_dbg_perf", 0.25, 0, function() poll() end)

	-- traces made inside the addon's hooks
	for _, functionName in ipairs({ "TraceLine", "TraceHull" }) do
		local original = util[functionName]
		saved["util." .. functionName] = original
		util[functionName] = function(...)
			if inHook > 0 then stats.traces = stats.traces + 1 end
			return original(...)
		end
	end
	-- the addon's NW2 vars: changes only (an unchanged value isn't sent)
	local entityMeta = FindMetaTable("Entity")
	for _, setter in ipairs(NW_SETTERS) do
		local original, getValue = entityMeta[setter], entityMeta[NW_GETTERS[setter]]
		saved["Entity." .. setter] = original
		entityMeta[setter] = function(entity, key, value, ...)
			if matchesAny(key, NW_KEYS) and getValue(entity, key) ~= value then
				stats.nw[key] = (stats.nw[key] or 0) + 1
			end
			return original(entity, key, value, ...)
		end
	end
	-- the addon's net messages and their size when sent
	local originalStart = net.Start
	saved["net.Start"] = originalStart
	local currentMessage
	net.Start = function(name, ...)
		currentMessage = matchesAny(name, NET_NAMES) and name or nil
		return originalStart(name, ...)
	end
	for _, functionName in ipairs({ "Send", "Broadcast", "SendPVS", "SendPAS", "SendOmit" }) do
		local original = net[functionName]
		saved["net." .. functionName] = original
		net[functionName] = function(...)
			if currentMessage then
				local bytes = net.BytesWritten() or 0
				local counts = stats.net[currentMessage] or { count = 0, bytes = 0 }
				counts.count, counts.bytes = counts.count + 1, counts.bytes + bytes
				stats.net[currentMessage] = counts
				currentMessage = nil
			end
			return original(...)
		end
	end
end

local function uninstall()
	if not installed then return end
	installed = false
	for _, wrap in ipairs(wrapped) do
		local hooks = hook.GetTable()[wrap[1]]
		-- (a Lua refresh may have replaced the hook since: leave the new one alone)
		if hooks and hooks[wrap[2]] == wrap[4] then hook.Add(wrap[1], wrap[2], wrap[3]) end
	end
	wrapped = {}
	hook.Remove("Tick", "audio_dbg_perf_tick")
	timer.Remove("audio_dbg_perf")
	local entityMeta = FindMetaTable("Entity")
	for key, original in pairs(saved) do
		local library, functionName = string.match(key, "^(%w+)%.(%w+)$")
		if library == "util" then util[functionName] = original
		elseif library == "net" then net[functionName] = original
		elseif library == "Entity" then entityMeta[functionName] = original end
	end
	saved = {}
end
PERF.Uninstall = uninstall

---------------------------------------------------------------------------
-- the figures
---------------------------------------------------------------------------
local function carCounts()
	local counts = { tracked = 0, on = 0, driven = 0, lights = 0, cruise = 0, all = #ents.FindByClass("prop_vehicle_jeep*") }
	for vehicle in pairs(AudioEngine.TrackedVehicles or {}) do
		if IsValid(vehicle) then
			counts.tracked = counts.tracked + 1
			if vehicle:GetNW2Bool("audio_on", false) then counts.on = counts.on + 1 end
			if IsValid(vehicle:GetDriver()) then counts.driven = counts.driven + 1 end
			if vehicle:GetNW2Int("audio_lights", 0) > 0 then counts.lights = counts.lights + 1 end
			if vehicle:GetNW2Float("audio_cruise", 0) > 0 then counts.cruise = counts.cruise + 1 end
		end
	end

	return counts
end

-- the stats since the last reset, per tick / per second
local function summary()
	local seconds = math.max(SysTime() - stats.startTime, 0.001)
	local ticks = math.max(stats.ticks, 1)
	local hooks, total = {}, 0
	for key, hookTiming in pairs(stats.hooks) do
		table.insert(hooks, { key = key, msTick = hookTiming.total * 1000 / ticks, maxMs = hookTiming.max * 1000, calls = hookTiming.calls / ticks })
		total = total + hookTiming.total
	end
	table.sort(hooks, function(first, second) return first.msTick > second.msTick end)
	local nw, nwTotal = {}, 0
	for key, changeCount in pairs(stats.nw) do
		table.insert(nw, { key = key, perSec = changeCount / seconds })
		nwTotal = nwTotal + changeCount
	end
	table.sort(nw, function(first, second) return first.perSec > second.perSec end)
	local netList, netCount, netBytes = {}, 0, 0
	for name, counts in pairs(stats.net) do
		table.insert(netList, { name = name, perSec = counts.count / seconds, bytesSec = counts.bytes / seconds })
		netCount, netBytes = netCount + counts.count, netBytes + counts.bytes
	end

	return {
		seconds = seconds, tickMs = engine.TickInterval() * 1000, tickRate = 1 / engine.TickInterval(),
		hooks = hooks, totalMsTick = total * 1000 / ticks, tracesTick = stats.traces / ticks,
		nw = nw, nwSec = nwTotal / seconds, net = netList, netSec = netCount / seconds, netBytesSec = netBytes / seconds,
		cars = carCounts(), luaKB = collectgarbage("count"), players = player.GetCount(),
	}
end
PERF.Summary = summary

local function report(requester, summaryData)
	local function printLine(line)
		if IsValid(requester) then requester:PrintMessage(HUD_PRINTCONSOLE, line) else MsgN(line) end
	end
	local counts = summaryData.cars
	printLine(string.format("==== Audio Engine performance, SERVER: %.1f s, %d players, %.0f ticks/s (%.2f ms budget per tick) ====",
		summaryData.seconds, summaryData.players, summaryData.tickRate, summaryData.tickMs))
	printLine(string.format("Cars: %d vehicles, %d with the procedural engine, %d running, %d driven, %d lights on, %d on the speed limiter",
		counts.all, counts.tracked, counts.on, counts.driven, counts.lights, counts.cruise))
	printLine(string.format("Addon Lua: %.3f ms per tick (%.1f%% of the tick budget)%s, %.1f traces per tick",
		summaryData.totalMsTick, summaryData.totalMsTick / summaryData.tickMs * 100,
		counts.tracked > 0 and string.format(", %.4f ms per tracked car", summaryData.totalMsTick / counts.tracked) or "", summaryData.tracesTick))
	printLine("  hook (event / name)                               ms/tick   worst ms  calls/tick")
	for _, hookTiming in ipairs(summaryData.hooks) do
		printLine(string.format("  %-48s %8.4f %10.3f %10.2f", hookTiming.key, hookTiming.msTick, hookTiming.maxMs, hookTiming.calls))
	end
	printLine(string.format("NW2 changes (sent to every player who sees the car): %.1f /s", summaryData.nwSec))
	for _, entry in ipairs(summaryData.nw) do printLine(string.format("  %-28s %8.1f /s", entry.key, entry.perSec)) end
	printLine(string.format("Net messages: %.1f /s, %.0f bytes/s", summaryData.netSec, summaryData.netBytesSec))
	for _, entry in ipairs(summaryData.net) do printLine(string.format("  %-28s %8.1f /s %10.0f bytes/s", entry.name, entry.perSec, entry.bytesSec)) end
	printLine(string.format("Server Lua memory (all addons): %.1f MB", summaryData.luaKB / 1024))
end

---------------------------------------------------------------------------
-- who is measuring: a capture, and the players with the overlay open
---------------------------------------------------------------------------
local subscribers = {}
local capture   -- { ply, endsAt }

local function needed()
	if capture then return true end
	for requester in pairs(subscribers) do
		if IsValid(requester) then return true end
		subscribers[requester] = nil
	end

	return false
end

local function refresh()
	if needed() then install() else uninstall() end
end

net.Receive("audio_dbg_perf_sub", function(_, requester)
	local subscribe = net.ReadBool()
	if subscribe and not EngineDebug.Allowed(requester) then return end
	subscribers[requester] = subscribe or nil
	refresh()
end)

net.Receive("audio_dbg_perf_cap", function(_, requester)
	if not EngineDebug.Allowed(requester) then return end
	local seconds = math.Clamp(net.ReadFloat(), 1, 120)
	if capture then
		requester:PrintMessage(HUD_PRINTCONSOLE, "[Audio Engine] a server capture is already running")
		return
	end
	capture = { requester = requester, endsAt = SysTime() + seconds }
	install()
	resetStats()
end)

-- (its timer exists only while measuring: the overlay's figures once a second, the capture's report at its end)
local nextSend = 0
poll = function()
	-- (an overlay player who left: no one measuring any more)
	if not needed() then
		uninstall()
		return
	end
	local now = SysTime()
	if capture and now >= capture.endsAt then
		report(capture.requester, summary())
		capture = nil
		resetStats()
		refresh()
		return
	end
	if capture or now < nextSend then return end
	nextSend = now + SEND_EVERY
	local summaryData = summary()
	resetStats()
	local recipients = {}
	for requester in pairs(subscribers) do
		if IsValid(requester) then table.insert(recipients, requester) end
	end
	if #recipients == 0 then return end
	net.Start("audio_dbg_perf_stats")
	net.WriteTable({
		tickMs = summaryData.tickMs, totalMsTick = summaryData.totalMsTick, tracesTick = summaryData.tracesTick, nwSec = summaryData.nwSec,
		netSec = summaryData.netSec, netBytesSec = summaryData.netBytesSec, luaKB = summaryData.luaKB, cars = summaryData.cars,
		hooks = { summaryData.hooks[1], summaryData.hooks[2], summaryData.hooks[3], summaryData.hooks[4], summaryData.hooks[5] },
	})
	net.Send(recipients)
end

---------------------------------------------------------------------------
-- stress test: a grid of running PERP cars in front of you
---------------------------------------------------------------------------
local spawned = {}

local function spawnEntries(choice)
	local entries = {}
	for entryId, vehicleTable in pairs(list.Get("Vehicles")) do
		if isstring(vehicleTable.Category) and string.find(vehicleTable.Category, "(Audio Engine)", 1, true) then
			table.insert(entries, { id = entryId, vehicleTable = vehicleTable })
		end
	end
	table.sort(entries, function(first, second) return first.vehicleTable.Name < second.vehicleTable.Name end)
	if not choice or choice == "" or choice == "mixed" then return entries end
	local wanted = string.lower(choice)
	for _, entry in ipairs(entries) do
		if string.lower(entry.id) == wanted or string.lower(entry.vehicleTable.Name) == wanted then return { entry } end
	end
	local matches = {}
	for _, entry in ipairs(entries) do
		if string.find(string.lower(entry.vehicleTable.Name), wanted, 1, true) then table.insert(matches, entry) end
	end

	return matches
end

--[[
	Driving test cars: no one sits in them, so the game won't drive them. Each tick they're pushed
	along their nose, gaining DRIVE_ACCELERATION up to their speed and then held there, kept straight.
	For the sound they get what a driver holding W sends (NW2 audio_in), and at their speed the speed
	limiter's holding state (audio_limst 1: steady part throttle in a cruising gear), as on a real
	drive with the limiter set. The hook runs only while such cars exist.
]]
local DRIVE_ACCELERATION = 7 / 0.0254   -- inches/s per second (~7 m/s2: 0 to 30 mph in ~2 s)
local DRIVE_HOLD_MARGIN = 0.5 * 17.6    -- inches/s (0.5 mph) under the speed: holding it
local drivingCars = {}                  -- vehicle -> { targetSpeed (inches/s), acceleration, goAt, requester, startedAt, warned }

--[[
	The race formation: a column coming down the road at you and passing on your right, for the
	drive-by (Doppler, pass-by swell). It starts RACE.startAhead in front of you, the cars zig-zag
	RACE.zigzag either side of the lane's centre line, RACE.laneOffset to your right, with random
	gaps of RACE.gapMin..gapMax between them. Every car sets off at the same moment (once all have
	started their engines), so the gaps hold, at three times the grid's acceleration.
]]
local METRE = 1 / 0.0254   -- inches
local RACE = {
	startAhead = 60 * METRE, laneOffset = 5 * METRE, zigzag = 1.4 * METRE,
	gapMin = 8 * METRE, gapMax = 25 * METRE,
	acceleration = 3 * DRIVE_ACCELERATION,
	startUp = 4.5,   -- s the engines need to start (catch, flare, settle) before the column sets off
}
hook.Remove("Tick", "audio_dbg_perf_drive")   -- (Lua refresh: the previous load's drivers stop)

local function setDriveState(vehicle, inputBits, limiterState)
	if vehicle.audioPerfInputBits ~= inputBits then
		vehicle.audioPerfInputBits = inputBits
		vehicle:SetNW2Int("audio_in", inputBits)
	end
	if vehicle.audioPerfLimiterState ~= limiterState then
		vehicle.audioPerfLimiterState = limiterState
		vehicle:SetNW2Int("audio_limst", limiterState)
	end
end

local function noseDirection(vehicle)
	local geometry = AudioEngine.CarGeometry and AudioEngine.CarGeometry(vehicle)
	local localForward = geometry and geometry.forward or Vector(0, 1, 0)
	local direction = vehicle:LocalToWorld(localForward) - vehicle:GetPos()
	direction:Normalize()
	return direction
end

local function driveCars()
	local deltaTime = engine.TickInterval()
	for vehicle, drive in pairs(drivingCars) do
		local targetSpeed = drive.targetSpeed
		local physics = IsValid(vehicle) and vehicle:GetPhysicsObject()
		if not (physics and IsValid(physics)) then
			drivingCars[vehicle] = nil
		elseif IsValid(vehicle:GetDriver()) then
			-- someone got in: they drive it now
			drivingCars[vehicle] = nil
			setDriveState(vehicle, 0, 0)
		elseif vehicle:GetNW2Bool("audio_on", false) and vehicle.audioStart == nil and CurTime() >= drive.goAt then
			local nose = noseDirection(vehicle)
			local up = vehicle:GetUp()
			local velocity = physics:GetVelocity()
			local speed = velocity:Dot(nose)
			local holding = speed >= targetSpeed - DRIVE_HOLD_MARGIN
			local newSpeed = holding and targetSpeed or math.min(targetSpeed, speed + drive.acceleration * deltaTime)
			-- a car without a driver has its handbrake on: its locked wheels held it where it stood
			if vehicle.SetHandbrake then vehicle:SetHandbrake(false) end
			physics:Wake()
			physics:SetVelocity(nose * newSpeed + up * velocity:Dot(up))
			physics:AddAngleVelocity(Vector(0, 0, -physics:GetAngleVelocity().z))
			setDriveState(vehicle, 1, holding and 1 or 0)
			-- still standing a while after it should have set off: say so once (something holds it)
			drive.startedAt = drive.startedAt or CurTime()
			if not drive.warned and CurTime() - drive.startedAt > 3 and speed < 17.6 then
				drive.warned = true
				if IsValid(drive.requester) then
					drive.requester:PrintMessage(HUD_PRINTCONSOLE, string.format("[Audio Engine] %s isn't moving (%.1f mph after 3 s of pushing)",
						tostring(vehicle.VehicleName or vehicle:GetModel()), speed / 17.6))
				end
			end
		elseif not drive.warned and CurTime() - math.max(drive.queuedAt, drive.goAt) > 8 then
			drive.warned = true
			if IsValid(drive.requester) then
				drive.requester:PrintMessage(HUD_PRINTCONSOLE, string.format("[Audio Engine] %s hasn't started its engine after 8 s (audio_on %s, starting %s)",
					tostring(vehicle.VehicleName or vehicle:GetModel()), tostring(vehicle:GetNW2Bool("audio_on", false)), tostring(vehicle.audioStart ~= nil)))
			end
		end
	end
	if not next(drivingCars) then hook.Remove("Tick", "audio_dbg_perf_drive") end
end

local function startDriving(vehicle, mph, requester, acceleration, goAt)
	drivingCars[vehicle] = {
		targetSpeed = mph * 17.6, acceleration = acceleration or DRIVE_ACCELERATION, goAt = goAt or 0,
		requester = requester, queuedAt = CurTime(),
	}
	hook.Add("Tick", "audio_dbg_perf_drive", driveCars)
end

-- where each car of a formation stands (world position) and the yaw it faces
local function gridSpots(requester, count)
	local yaw = requester:EyeAngles().y
	local forward, right = Angle(0, yaw, 0):Forward(), Angle(0, yaw, 0):Right()
	local origin = requester:GetPos() + forward * 400
	local CARS_PER_ROW, ROW_SPACING, COLUMN_SPACING = 6, 170, 330
	local spots = {}
	for i = 1, count do
		local row, column = math.floor((i - 1) / CARS_PER_ROW), (i - 1) % CARS_PER_ROW
		spots[i] = {
			position = origin + right * (column - (CARS_PER_ROW - 1) / 2) * ROW_SPACING + forward * row * COLUMN_SPACING,
			yaw = yaw - 90,   -- (the cars' noses are +Y: facing away from you)
		}
	end
	return spots
end

local function raceSpots(requester, count)
	local yaw = requester:EyeAngles().y
	local forward, right = Angle(0, yaw, 0):Forward(), Angle(0, yaw, 0):Right()
	local spots = {}
	local distance = RACE.startAhead
	for i = 1, count do
		local side = i % 2 == 0 and 1 or -1
		spots[i] = {
			position = requester:GetPos() + forward * distance + right * (RACE.laneOffset + side * RACE.zigzag),
			yaw = yaw + 90,   -- facing you: they come down the road at you
		}
		distance = distance + RACE.gapMin + math.random() * (RACE.gapMax - RACE.gapMin)
	end
	return spots
end

concommand.Add("audio_engine_perf_spawn", function(requester, _, args)
	if not EngineDebug.Allowed(requester) then return end
	local count = math.Clamp(math.floor(tonumber(args[1]) or 10), 1, 64)
	local entries = spawnEntries(args[2])
	local lights = args[3] == "1"
	local driveMph = math.Clamp(tonumber(args[4]) or 0, 0, 120)
	local race = string.lower(args[5] or "") == "race"
	if #entries == 0 then
		requester:PrintMessage(HUD_PRINTCONSOLE, "[Audio Engine] no PERP car matches '" .. tostring(args[2]) .. "'")
		return
	end
	local spots = race and raceSpots(requester, count) or gridSpots(requester, count)
	-- the race column sets off together, once the last car's engine has started
	local raceGoAt = CurTime() + 0.5 + count * 0.05 + RACE.startUp
	for i = 1, count do
		-- mixed: spread over the list, so engines of every kind take part
		local entry = entries[#entries == 1 and 1 or (math.floor((i - 1) * #entries / count) % #entries) + 1]
		local vehicleTable = entry.vehicleTable
		local position = spots[i].position
		local trace = util.TraceLine({ start = position + Vector(0, 0, 200), endpos = position - Vector(0, 0, 400) })
		local vehicle = ents.Create(vehicleTable.Class or "prop_vehicle_jeep")
		if IsValid(vehicle) then
			vehicle:SetModel(vehicleTable.Model)
			for key, value in pairs(vehicleTable.KeyValues or {}) do vehicle:SetKeyValue(key, value) end
			vehicle.VehicleTable = vehicleTable
			vehicle.VehicleName = entry.id
			vehicle:SetPos(trace.HitPos + Vector(0, 0, 20))
			vehicle:SetAngles(Angle(0, spots[i].yaw, 0))
			vehicle:Spawn()
			vehicle:Activate()
			hook.Run("PlayerSpawnedVehicle", requester, vehicle)
			table.insert(spawned, vehicle)
			timer.Simple(0.5 + i * 0.05, function()
				if not IsValid(vehicle) then return end
				if AudioEngine.SetEngine then AudioEngine.SetEngine(vehicle, true) end
				if lights and IsValid(vehicle:GetNW2Entity("audio_lightbar")) then vehicle:SetNW2Int("audio_lights", 2) end
				if driveMph > 0 then
					if race then
						startDriving(vehicle, driveMph, requester, RACE.acceleration, raceGoAt)
					else
						startDriving(vehicle, driveMph, requester)
					end
				end
			end)
		end
	end
	local driving = ""
	if driveMph > 0 then
		driving = race and string.format(", a race column passing on your right at %g mph (sets off in %.0f s)", driveMph, raceGoAt - CurTime())
			or string.format(", driving away at %g mph", driveMph)
	elseif race then
		driving = ", lined up as a race column (give a speed to make them drive)"
	end
	requester:PrintMessage(HUD_PRINTCONSOLE, string.format("[Audio Engine] spawned %d cars (%s)%s%s; audio_engine_perf_clear removes them",
		count, #entries == 1 and entries[1].vehicleTable.Name or (#entries .. " kinds"), lights and ", lights on" or "", driving))
end, nil, "Stress test (debug): audio_engine_perf_spawn <count> [car name | mixed] [lights 0/1] [drive mph, 0 = parked] [grid | race]"
	.. " spawns running PERP cars in front of you (race: a zig-zag column with random gaps that drives past you)")

concommand.Add("audio_engine_perf_clear", function(requester)
	if IsValid(requester) and not EngineDebug.Allowed(requester) then return end
	local removedCount = 0
	for _, vehicle in ipairs(spawned) do
		if IsValid(vehicle) then
			vehicle:Remove()
			removedCount = removedCount + 1
		end
	end
	spawned = {}
	drivingCars = {}
	hook.Remove("Tick", "audio_dbg_perf_drive")
	if IsValid(requester) then requester:PrintMessage(HUD_PRINTCONSOLE, "[Audio Engine] removed " .. removedCount .. " stress-test cars") end
end, nil, "Removes the cars audio_engine_perf_spawn made")
