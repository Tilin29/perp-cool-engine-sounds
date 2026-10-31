--[[
	Glue between the page and the addon. Not part of the addon: it plays the server's part
	(engine on/off, applying a tuned profile, the networked keys) and reports state to the page.
]]
local E = AUDIO_ENGINE
BR = {}

-- generation progress: count the top-level renders and sounds of the bank being built
local function tagRender(name)
	local fn = E.Synth[name]
	if type(fn) ~= "function" then return end
	E.Synth[name] = function(...)
		local q = E.Bank.queue[1]
		if q then q._r = (q._r or 0) + 1 end
		return fn(...)
	end
end
for _, n in ipairs({ "RenderSteadyLoop", "RenderLimiterLoop", "RenderStart", "RenderStop", "RenderBackfire",
	"RenderTurboLoop", "RenderBlowoff", "RenderRoadLoop", "RenderWindLoop" }) do tagRender(n) end
local gen = sound.Generate
sound.Generate = function(...)
	gen(...)
	local q = E.Bank.queue[1]
	if q then q._g = (q._g or 0) + 1 end
end

local CARDEF = E.Cars["models/plpd/sl65amg_rtu.mdl"]

-- what the bank at the front of the queue is, and how far along it is
function BR.progress()
	local q = E.Bank.queue[1]
	if not q then return "", 1 end
	if not q.cfg then return "road & wind", math.min(0.99, ((q._r or 0) + (q._g or 0)) / 4) end
	local cfg = q.cfg
	local jobs = 2 * #cfg.bands + 12 + (cfg.turbo and 3 or 0)
	local p = ((q._r or 0) + 0.15 * (q._g or 0)) / (jobs * 1.15)
	return cfg.engineName or "engine", math.min(0.99, p)
end

-- the server's side of audio_engine_set
function BR.apply(str)
	if str == "" then
		CAR.nw.audio_prof = ""
		return
	end
	local prof = E.DecodeProfile(str)
	if not prof then return end
	CAR.nw.audio_prof = E.EncodeProfile(prof)
end

-- the server's setEngine (sv_engine.lua)
function BR.engine(on, emotion)
	CAR.nw.audio_on = on
	if on then
		CAR.nw.audio_on_t = CurTime()
		CAR.nw.audio_emo = emotion
	end
end

-- one frame of the client: the game calls Think once per frame
function BR.tick(dt, t, f, b, h, inCar, px, py, pz, yaw, ex, ey, ez)
	SIM.dt, SIM.t = dt, t
	PLY.keys[IN_FORWARD], PLY.keys[IN_BACK], PLY.keys[IN_JUMP] = f, b, h
	PLY.inCar = inCar
	CAR.pos = Vector(px, py, pz)
	CAR.yaw = yaw
	PLY.eye = Vector(ex, ey, ez)
	-- the server networks the driver's keys (sv_engine.lua)
	CAR.nw.audio_in = (f and 1 or 0) + (b and 2 or 0) + (h and 4 or 0)
	hook.Run("Think")
	local c = E.ClientCars[CAR]
	local name, prog = BR.progress()
	local cfg = E.GetEngineConfig(CAR)
	local bank = E.Bank.list[cfg.id]
	if c then
		local st = c.st
		__state(st.rpm, st.gear, st.on and 1 or 0, st.phase or "", st.thr or 0, c.v or 0, st.limHold or 0,
			cfg.redline, (bank and bank.ready) and 1 or 0, (c.bank and c.bank.ready) and 1 or 0, name, prog,
			c.dop or 1, c.bus or 1, c.busPeak or 0, cfg.engineName or "", (CAR.pose.vehicle_guage or 0))
	else
		__state(0, 0, 0, "", 0, 0, 0, cfg.redline, (bank and bank.ready) and 1 or 0, 0, name, prog, 1, 1, 0, cfg.engineName or "", 0)
	end
end

-- the data the tuning menu needs, as JSON
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
BR.json = json

function BR.menuData()
	local presets = {}
	for _, p in ipairs(E.ENGINE_PRESETS) do presets[#presets + 1] = { id = p.id, name = p.name } end
	local layouts = {}
	for _, o in ipairs(E.LAYOUT_ORDER) do layouts[#layouts + 1] = { id = o[1], name = o[2] } end
	local gears = {}
	for _, g in ipairs(E.GEAR_PRESETS) do gears[#gears + 1] = { id = g.id, name = g.name, gears = g.gears, final = g.final } end
	return json({
		presets = presets, layouts = layouts, gearPresets = gears, cyl = E.LAYOUT_CYL,
		car = { name = CARDEF.name, preset = CARDEF.preset, wheelRadius = CARDEF.wheelRadius },
		stockTop = E.CarTopSpeed(CAR, CARDEF),
		current = E.GetEngineConfig(CAR).profile,
	})
end

function BR.presetProfile(id)
	return json(E.ProfileFromPreset(id))
end

-- what the menu's stats line shows for a profile string (cl_menu.lua refreshStats)
function BR.resolve(str)
	local carEff = {}
	for k, v in pairs(CARDEF) do carEff[k] = v end
	carEff.topSpeed = E.CarTopSpeed(CAR, CARDEF)
	local prof = E.DecodeProfile(str) or E.ProfileFromPreset(CARDEF.preset)
	local cfg = E.ResolveProfile(carEff, prof)
	local b = E.Bank.list[cfg.id]
	return json({
		final = cfg.final, bands = #cfg.bands, topSpeed = cfg.topSpeed, engineName = cfg.engineName,
		id = cfg.id, built = (b and b.ready) and true or false, profile = prof,
		accel = prof.accel, vmax = prof.vmax,
	})
end

function BR.command(name)
	local fn = concommand.cmds[name]
	if fn then fn() end
end
