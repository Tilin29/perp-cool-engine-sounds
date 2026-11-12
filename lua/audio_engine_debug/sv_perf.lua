--[[
	Audio Engine debug module: performance profiler (server). Not part of the final addon.

	Nothing here runs until asked: the measuring wrappers are put on only while a capture runs or a
	superadmin has the live overlay open (cl_perf.lua), and taken off again after.

	  capture (audio_engine_perf on the client): times every hook of the addon and the siren for the
	          requested seconds and prints a report to the requester's console
	  live    (audio_engine_perf_hud 1): the same figures sent to the overlay once a second
	  stress  audio_engine_perf_spawn <count> [car | mixed] [lights 0/1]: spawns PERP cars in a grid
	          in front of you with their engines running (and the emergency lights on, if asked);
	          audio_engine_perf_clear removes them

	Measured while on:
	  hooks   time per hook (event / name) per tick: average and worst
	  traces  util.TraceLine / TraceHull calls made inside the addon's hooks
	  NW2     changes of the addon's networked vars (audio_*, siren_*): each change is sent to the
	          players that see the car
	  net     the addon's net messages and their bytes
	  cars    tracked vehicles, engines on, drivers, lights on; Lua memory of the server
]]

local E = AUDIO_ENGINE
local DBG = E.Debug

util.AddNetworkString("audio_dbg_perf_sub")
util.AddNetworkString("audio_dbg_perf_cap")
util.AddNetworkString("audio_dbg_perf_stats")

-- (Lua refresh: take the previous load's wrappers off before this one starts)
if DBG.PerfServer and DBG.PerfServer.Uninstall then DBG.PerfServer.Uninstall() end
local PERF = {}
DBG.PerfServer = PERF

local OURS = { "^audio_engine", "^police_siren" }
local NW_KEYS = { "^audio_", "^siren_" }
local NET_NAMES = { "^audio_", "^police_siren" }
local SEND_EVERY = 1

local function ours(name, patterns)
	if not isstring(name) then return false end
	for _, p in ipairs(patterns) do
		if string.find(name, p) then return true end
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
	stats = { t0 = SysTime(), ticks = 0, hooks = {}, traces = 0, nw = {}, net = {}, netBytes = 0 }
end

local function addHook(key, dt)
	local h = stats.hooks[key]
	if not h then
		h = { calls = 0, total = 0, max = 0 }
		stats.hooks[key] = h
	end
	h.calls = h.calls + 1
	h.total = h.total + dt
	if dt > h.max then h.max = dt end
end

local function wrapHooks()
	for event, list in pairs(hook.GetTable()) do
		if not string.find(event, "/", 1, true) then
			for name, fn in pairs(list) do
				if ours(name, OURS) and isfunction(fn) then
					local key = event .. " / " .. name
					local function wrapper(...)
						inHook = inHook + 1
						local t0 = SysTime()
						local a, b, c, d, e, f = fn(...)
						addHook(key, SysTime() - t0)
						inHook = inHook - 1
						return a, b, c, d, e, f
					end
					hook.Add(event, name, wrapper)
					table.insert(wrapped, { event, name, fn, wrapper })
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
	for _, fname in ipairs({ "TraceLine", "TraceHull" }) do
		local orig = util[fname]
		saved["util." .. fname] = orig
		util[fname] = function(...)
			if inHook > 0 then stats.traces = stats.traces + 1 end
			return orig(...)
		end
	end
	-- the addon's NW2 vars: changes only (an unchanged value isn't sent)
	local meta = FindMetaTable("Entity")
	for _, setter in ipairs(NW_SETTERS) do
		local orig, getter = meta[setter], meta[NW_GETTERS[setter]]
		saved["Entity." .. setter] = orig
		meta[setter] = function(ent, key, value, ...)
			if ours(key, NW_KEYS) and getter(ent, key) ~= value then
				stats.nw[key] = (stats.nw[key] or 0) + 1
			end
			return orig(ent, key, value, ...)
		end
	end
	-- the addon's net messages and their size when sent
	local start = net.Start
	saved["net.Start"] = start
	local current
	net.Start = function(name, ...)
		current = ours(name, NET_NAMES) and name or nil
		return start(name, ...)
	end
	for _, fname in ipairs({ "Send", "Broadcast", "SendPVS", "SendPAS", "SendOmit" }) do
		local orig = net[fname]
		saved["net." .. fname] = orig
		net[fname] = function(...)
			if current then
				local bytes = net.BytesWritten() or 0
				local n = stats.net[current] or { count = 0, bytes = 0 }
				n.count, n.bytes = n.count + 1, n.bytes + bytes
				stats.net[current] = n
				current = nil
			end
			return orig(...)
		end
	end
end

local function uninstall()
	if not installed then return end
	installed = false
	for _, w in ipairs(wrapped) do
		local list = hook.GetTable()[w[1]]
		-- (a Lua refresh may have replaced the hook since: leave the new one alone)
		if list and list[w[2]] == w[4] then hook.Add(w[1], w[2], w[3]) end
	end
	wrapped = {}
	hook.Remove("Tick", "audio_dbg_perf_tick")
	timer.Remove("audio_dbg_perf")
	local meta = FindMetaTable("Entity")
	for key, orig in pairs(saved) do
		local lib, fname = string.match(key, "^(%w+)%.(%w+)$")
		if lib == "util" then util[fname] = orig
		elseif lib == "net" then net[fname] = orig
		elseif lib == "Entity" then meta[fname] = orig end
	end
	saved = {}
end
PERF.Uninstall = uninstall

---------------------------------------------------------------------------
-- the figures
---------------------------------------------------------------------------
local function carCounts()
	local c = { tracked = 0, on = 0, driven = 0, lights = 0, cruise = 0, all = #ents.FindByClass("prop_vehicle_jeep*") }
	for veh in pairs(E.TrackedVehicles or {}) do
		if IsValid(veh) then
			c.tracked = c.tracked + 1
			if veh:GetNW2Bool("audio_on", false) then c.on = c.on + 1 end
			if IsValid(veh:GetDriver()) then c.driven = c.driven + 1 end
			if veh:GetNW2Int("audio_lights", 0) > 0 then c.lights = c.lights + 1 end
			if veh:GetNW2Float("audio_cruise", 0) > 0 then c.cruise = c.cruise + 1 end
		end
	end

	return c
end

-- the stats since the last reset, per tick / per second
local function summary()
	local secs = math.max(SysTime() - stats.t0, 0.001)
	local ticks = math.max(stats.ticks, 1)
	local hooks, total = {}, 0
	for key, h in pairs(stats.hooks) do
		table.insert(hooks, { key = key, msTick = h.total * 1000 / ticks, maxMs = h.max * 1000, calls = h.calls / ticks })
		total = total + h.total
	end
	table.sort(hooks, function(a, b) return a.msTick > b.msTick end)
	local nw, nwTotal = {}, 0
	for key, n in pairs(stats.nw) do
		table.insert(nw, { key = key, perSec = n / secs })
		nwTotal = nwTotal + n
	end
	table.sort(nw, function(a, b) return a.perSec > b.perSec end)
	local netList, netCount, netBytes = {}, 0, 0
	for name, n in pairs(stats.net) do
		table.insert(netList, { name = name, perSec = n.count / secs, bytesSec = n.bytes / secs })
		netCount, netBytes = netCount + n.count, netBytes + n.bytes
	end

	return {
		secs = secs, tickMs = engine.TickInterval() * 1000, tickRate = 1 / engine.TickInterval(),
		hooks = hooks, totalMsTick = total * 1000 / ticks, tracesTick = stats.traces / ticks,
		nw = nw, nwSec = nwTotal / secs, net = netList, netSec = netCount / secs, netBytesSec = netBytes / secs,
		cars = carCounts(), luaKB = collectgarbage("count"), players = player.GetCount(),
	}
end
PERF.Summary = summary

local function report(ply, s)
	local function out(line)
		if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, line) else MsgN(line) end
	end
	local c = s.cars
	out(string.format("==== Audio Engine performance, SERVER: %.1f s, %d players, %.0f ticks/s (%.2f ms budget per tick) ====",
		s.secs, s.players, s.tickRate, s.tickMs))
	out(string.format("Cars: %d vehicles, %d with the procedural engine, %d running, %d driven, %d lights on, %d on the speed limiter",
		c.all, c.tracked, c.on, c.driven, c.lights, c.cruise))
	out(string.format("Addon Lua: %.3f ms per tick (%.1f%% of the tick budget)%s, %.1f traces per tick",
		s.totalMsTick, s.totalMsTick / s.tickMs * 100,
		c.tracked > 0 and string.format(", %.4f ms per tracked car", s.totalMsTick / c.tracked) or "", s.tracesTick))
	out("  hook (event / name)                               ms/tick   worst ms  calls/tick")
	for _, h in ipairs(s.hooks) do
		out(string.format("  %-48s %8.4f %10.3f %10.2f", h.key, h.msTick, h.maxMs, h.calls))
	end
	out(string.format("NW2 changes (sent to every player who sees the car): %.1f /s", s.nwSec))
	for _, n in ipairs(s.nw) do out(string.format("  %-28s %8.1f /s", n.key, n.perSec)) end
	out(string.format("Net messages: %.1f /s, %.0f bytes/s", s.netSec, s.netBytesSec))
	for _, n in ipairs(s.net) do out(string.format("  %-28s %8.1f /s %10.0f bytes/s", n.name, n.perSec, n.bytesSec)) end
	out(string.format("Server Lua memory (all addons): %.1f MB", s.luaKB / 1024))
end

---------------------------------------------------------------------------
-- who is measuring: a capture, and the players with the overlay open
---------------------------------------------------------------------------
local subscribers = {}
local capture   -- { ply, untilT }

local function needed()
	if capture then return true end
	for ply in pairs(subscribers) do
		if IsValid(ply) then return true end
		subscribers[ply] = nil
	end

	return false
end

local function refresh()
	if needed() then install() else uninstall() end
end

net.Receive("audio_dbg_perf_sub", function(_, ply)
	local on = net.ReadBool()
	if on and not DBG.Allowed(ply) then return end
	subscribers[ply] = on or nil
	refresh()
end)

net.Receive("audio_dbg_perf_cap", function(_, ply)
	if not DBG.Allowed(ply) then return end
	local secs = math.Clamp(net.ReadFloat(), 1, 120)
	if capture then
		ply:PrintMessage(HUD_PRINTCONSOLE, "[Audio Engine] a server capture is already running")
		return
	end
	capture = { ply = ply, untilT = SysTime() + secs }
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
	if capture and now >= capture.untilT then
		report(capture.ply, summary())
		capture = nil
		resetStats()
		refresh()
		return
	end
	if capture or now < nextSend then return end
	nextSend = now + SEND_EVERY
	local s = summary()
	resetStats()
	local to = {}
	for ply in pairs(subscribers) do
		if IsValid(ply) then table.insert(to, ply) end
	end
	if #to == 0 then return end
	net.Start("audio_dbg_perf_stats")
	net.WriteTable({
		tickMs = s.tickMs, totalMsTick = s.totalMsTick, tracesTick = s.tracesTick, nwSec = s.nwSec,
		netSec = s.netSec, netBytesSec = s.netBytesSec, luaKB = s.luaKB, cars = s.cars,
		hooks = { s.hooks[1], s.hooks[2], s.hooks[3], s.hooks[4], s.hooks[5] },
	})
	net.Send(to)
end

---------------------------------------------------------------------------
-- stress test: a grid of running PERP cars in front of you
---------------------------------------------------------------------------
local spawned = {}

local function spawnEntries(which)
	local all = {}
	for id, vt in pairs(list.Get("Vehicles")) do
		if isstring(vt.Category) and string.find(vt.Category, "(Audio Engine)", 1, true) then
			table.insert(all, { id = id, vt = vt })
		end
	end
	table.sort(all, function(a, b) return a.vt.Name < b.vt.Name end)
	if not which or which == "" or which == "mixed" then return all end
	local want = string.lower(which)
	for _, e in ipairs(all) do
		if string.lower(e.id) == want or string.lower(e.vt.Name) == want then return { e } end
	end
	local found = {}
	for _, e in ipairs(all) do
		if string.find(string.lower(e.vt.Name), want, 1, true) then table.insert(found, e) end
	end

	return found
end

concommand.Add("audio_engine_perf_spawn", function(ply, _, args)
	if not DBG.Allowed(ply) then return end
	local count = math.Clamp(math.floor(tonumber(args[1]) or 10), 1, 64)
	local entries = spawnEntries(args[2])
	local lights = args[3] == "1"
	if #entries == 0 then
		ply:PrintMessage(HUD_PRINTCONSOLE, "[Audio Engine] no PERP car matches '" .. tostring(args[2]) .. "'")
		return
	end
	local yaw = ply:EyeAngles().y
	local fwd, right = Angle(0, yaw, 0):Forward(), Angle(0, yaw, 0):Right()
	local origin = ply:GetPos() + fwd * 400
	local PER_ROW, SIDE, DEPTH = 6, 170, 330
	for i = 1, count do
		-- mixed: spread over the list, so engines of every kind take part
		local e = entries[#entries == 1 and 1 or (math.floor((i - 1) * #entries / count) % #entries) + 1]
		local vt = e.vt
		local row, col = math.floor((i - 1) / PER_ROW), (i - 1) % PER_ROW
		local pos = origin + right * (col - (PER_ROW - 1) / 2) * SIDE + fwd * row * DEPTH
		local tr = util.TraceLine({ start = pos + Vector(0, 0, 200), endpos = pos - Vector(0, 0, 400) })
		local veh = ents.Create(vt.Class or "prop_vehicle_jeep")
		if IsValid(veh) then
			veh:SetModel(vt.Model)
			for k, v in pairs(vt.KeyValues or {}) do veh:SetKeyValue(k, v) end
			veh.VehicleTable = vt
			veh.VehicleName = e.id
			veh:SetPos(tr.HitPos + Vector(0, 0, 20))
			veh:SetAngles(Angle(0, yaw - 90, 0))   -- (the cars' noses are +Y: facing away from you)
			veh:Spawn()
			veh:Activate()
			hook.Run("PlayerSpawnedVehicle", ply, veh)
			table.insert(spawned, veh)
			timer.Simple(0.5 + i * 0.05, function()
				if not IsValid(veh) then return end
				if E.SetEngine then E.SetEngine(veh, true) end
				if lights and IsValid(veh:GetNW2Entity("audio_lightbar")) then veh:SetNW2Int("audio_lights", 2) end
			end)
		end
	end
	ply:PrintMessage(HUD_PRINTCONSOLE, string.format("[Audio Engine] spawned %d cars (%s)%s; audio_engine_perf_clear removes them",
		count, #entries == 1 and entries[1].vt.Name or (#entries .. " kinds"), lights and ", lights on" or ""))
end, nil, "Stress test (debug): audio_engine_perf_spawn <count> [car name | mixed] [lights 0/1] spawns running PERP cars in front of you")

concommand.Add("audio_engine_perf_clear", function(ply)
	if IsValid(ply) and not DBG.Allowed(ply) then return end
	local n = 0
	for _, veh in ipairs(spawned) do
		if IsValid(veh) then
			veh:Remove()
			n = n + 1
		end
	end
	spawned = {}
	if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, "[Audio Engine] removed " .. n .. " stress-test cars") end
end, nil, "Removes the cars audio_engine_perf_spawn made")
