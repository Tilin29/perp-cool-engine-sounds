--[[
	Audio Engine - handling (server)

	Runs once on every registered car as it spawns, before its physics are captured as the
	base for engine tuning (sv_engine.lua):

	1. PERP physics on the test script. Off the PERP server, PERP's vehicle scripts aren't mounted
	   and the spawn menu falls back to scripts/vehicles/audio_engine/test_car.txt (sh_perp.lua).
	   The car's own PERP base script values (sv_perp_physics.lua: horsepower, top speed, gearing,
	   mass, steering, suspension, torque and brake split) are then put on it, so it accelerates,
	   tops out and handles like on the server. They're applied as ratios to test_car.txt's own
	   values, so Source's internal units never matter.
	2. Anti-spin setup (audio_engine_handling 1): brakes biased to the front (a locking rear
	   spins the car), less power while steering at speed, a slightly lower centre of mass, at
	   least normal grip, and more steering lock at speed. Relative changes only.
	3. Stability assist (sv_stability.lua) for the PERP cars, with each car's own steering angles.

	A car on a spiked/ tier script (tyres shot by a stinger) gets none of it: it's meant to be
	hard to drive.
]]

local E = AUDIO_ENGINE

local cvHandling = CreateConVar("audio_engine_handling", "1", FCVAR_ARCHIVE,
	"1 = anti-spin setup on cars with the procedural engine (front brake bias, less power while steering at speed, lower centre of mass); applies to cars spawned after")

---------------------------------------------------------------------------
-- setting vehicle params
---------------------------------------------------------------------------
local HU_PER_MPH = 17.6   -- GetVehicleParams speeds are inches/s; SetVehicleParams takes mph
local SPEED_KEYS = { "maxSpeed", "maxRevSpeed", "boostMaxSpeed" }
E.HU_PER_MPH = HU_PER_MPH

-- p is a table as GetVehicleParams returns it (speeds in its units). Sets it on the car, giving
-- SetVehicleParams the speeds it wants, and checks the unit took.
function E.SetParams(veh, p)
	p = table.Copy(p)
	for _, k in ipairs(SPEED_KEYS) do
		if p.engine and p.engine[k] then p.engine[k] = p.engine[k] / HU_PER_MPH end
	end
	if not pcall(veh.SetVehicleParams, veh, p) then return false end
	-- self-check the speed unit: if the engine took our mph as inches/s, set it again scaled
	local ok, chk = pcall(veh.GetVehicleParams, veh)
	if ok and istable(chk) and chk.engine and chk.engine.maxSpeed and p.engine and p.engine.maxSpeed then
		local want = p.engine.maxSpeed * HU_PER_MPH
		if math.abs(chk.engine.maxSpeed - p.engine.maxSpeed) < math.abs(chk.engine.maxSpeed - want) then
			for _, k in ipairs(SPEED_KEYS) do
				if p.engine[k] then p.engine[k] = p.engine[k] * HU_PER_MPH end
			end
			pcall(veh.SetVehicleParams, veh, p)
		end
	end
	return true
end

---------------------------------------------------------------------------
-- which script the car spawned with
---------------------------------------------------------------------------
E.TEST_SCRIPT = "scripts/vehicles/audio_engine/test_car.txt"

function E.VehicleScriptOf(veh)
	local kv = veh:GetKeyValues() or {}
	local s = kv.vehiclescript or kv.VehicleScript or kv.vehicleScript
	if (not s or s == "") and istable(veh.VehicleTable) and istable(veh.VehicleTable.KeyValues) then
		s = veh.VehicleTable.KeyValues.vehiclescript
	end
	if not isstring(s) or s == "" then return nil end
	return (string.lower(s):gsub("\\", "/"))
end

---------------------------------------------------------------------------
-- 1. PERP physics on a car that's on the test script
---------------------------------------------------------------------------
-- test_car.txt's values (keep in step with the file): the PERP value is applied as
-- current * perp / test, so whatever unit Source keeps a field in, the result is right
local TEST = {
	engine = { horsepower = 320, maxRPM = 6000, maxSpeed = 125, maxRevSpeed = 20, shiftUpRPM = 5600, shiftDownRPM = 2600 },
	body = { massOverride = 1600, maxAngularVelocity = 200, massCenterZ = -5 },
	steering = { degreesSlow = 38, degreesFast = 14, degreesBoost = 10, powerSlideAccel = 150 },
	axles = {
		{ suspension_springConstant = 110, suspension_springDamping = 0.9, suspension_springDampingCompression = 5.5,
		  suspension_stabilizerConstant = 120, suspension_maxBodyForce = 30, wheels_mass = 170 },
		{ suspension_springConstant = 105, suspension_springDamping = 0.9, suspension_springDampingCompression = 5.5,
		  suspension_stabilizerConstant = 110, suspension_maxBodyForce = 30, wheels_mass = 170 },
	},
}

-- scale a field by perp / test, if the car has it and both values are usable
local function ratio(t, key, perp, test)
	if not (t and t[key] and perp and test and test ~= 0) then return end
	t[key] = t[key] * perp / test
end
-- a unitless field (fractions, ratios, multipliers): set it straight
local function set(t, key, v)
	if t and t[key] ~= nil and v ~= nil then t[key] = v end
end

local function perpOnto(p, ph)
	local e, b, s = p.engine, p.body, p.steering
	local pe, pb, ps = ph.engine or {}, ph.body or {}, ph.steering or {}
	ratio(e, "horsepower", pe.horsepower, TEST.engine.horsepower)
	ratio(e, "maxRPM", pe.maxrpm, TEST.engine.maxRPM)
	ratio(e, "maxSpeed", pe.maxspeed, TEST.engine.maxSpeed)
	ratio(e, "maxRevSpeed", pe.maxreversespeed, TEST.engine.maxRevSpeed)
	ratio(e, "shiftUpRPM", pe.shiftuprpm, TEST.engine.shiftUpRPM)
	ratio(e, "shiftDownRPM", pe.shiftdownrpm, TEST.engine.shiftDownRPM)
	set(e, "axleRatio", pe.axleratio)
	if e and istable(e.gearRatio) and pe.gears and #pe.gears > 0 then
		e.gearRatio = table.Copy(pe.gears)
		set(e, "gearCount", #pe.gears)
	end

	ratio(b, "massOverride", pb.massoverride, TEST.body.massOverride)
	ratio(b, "maxAngularVelocity", pb.maxangularvelocity, TEST.body.maxAngularVelocity)
	set(b, "addGravity", pb.addgravity)
	set(b, "counterTorqueFactor", pb.countertorquefactor)
	if b and isvector(b.massCenterOverride) and pb.masscenter and b.massCenterOverride.z ~= 0 then
		-- the test script's centre is (0, 0, -5): that tells the unit
		local k = b.massCenterOverride.z / TEST.body.massCenterZ
		b.massCenterOverride = Vector(pb.masscenter[1] * k, pb.masscenter[2] * k, pb.masscenter[3] * k)
	end

	ratio(s, "degreesSlow", ps.degreesslow, TEST.steering.degreesSlow)
	ratio(s, "degreesFast", ps.degreesfast, TEST.steering.degreesFast)
	ratio(s, "degreesBoost", ps.degreesboost, TEST.steering.degreesBoost)
	ratio(s, "powerSlideAccel", ps.powerslideaccel, TEST.steering.powerSlideAccel)
	set(s, "turnThrottleReduceSlow", ps.turnthrottlereduceslow)
	set(s, "turnThrottleReduceFast", ps.turnthrottlereducefast)

	for i, a in ipairs(p.axles or {}) do
		local pa, ta = ph.axles and ph.axles[i], TEST.axles[i]
		if pa and ta then
			ratio(a, "suspension_springConstant", pa.springconstant, ta.suspension_springConstant)
			ratio(a, "suspension_springDamping", pa.springdamping, ta.suspension_springDamping)
			ratio(a, "suspension_springDampingCompression", pa.springdampingcompression, ta.suspension_springDampingCompression)
			ratio(a, "suspension_stabilizerConstant", pa.stabilizerconstant, ta.suspension_stabilizerConstant)
			ratio(a, "suspension_maxBodyForce", pa.maxbodyforce, ta.suspension_maxBodyForce)
			ratio(a, "wheels_mass", pa.mass, ta.wheels_mass)
			set(a, "torqueFactor", pa.torquefactor)
			set(a, "brakeFactor", pa.brakefactor)
		end
	end
end

---------------------------------------------------------------------------
-- 2. anti-spin setup (relative changes, any car, any script)
---------------------------------------------------------------------------
E.ANTI_SPIN = {
	frontBrake = 0.6,       -- at least this share of the braking on the front axle
	throttleReduceFast = 0.5, -- at least this much power cut while steering at speed
	powerSlide = 1.0,       -- handbrake slide push x this (1 = the script's own: lower kills drifts)
	minGravity = 1.0,       -- at least normal grip
	lowerCentre = 0.25,     -- lower the centre of mass by this many wheel radii
	steerFast = 1.3,        -- steering angle at speed x this (the scripts' 8-13 degrees turn too little)
}

local function antiSpin(p)
	local A = E.ANTI_SPIN
	local f, r = p.axles and p.axles[1], p.axles and p.axles[2]
	if f and r and f.brakeFactor and r.brakeFactor then
		local sum = f.brakeFactor + r.brakeFactor
		if sum > 0 and f.brakeFactor / sum < A.frontBrake then
			f.brakeFactor, r.brakeFactor = sum * A.frontBrake, sum * (1 - A.frontBrake)
		end
	end
	local s, b = p.steering, p.body
	if s and s.turnThrottleReduceFast then s.turnThrottleReduceFast = math.max(s.turnThrottleReduceFast, A.throttleReduceFast) end
	if s and s.powerSlideAccel then s.powerSlideAccel = s.powerSlideAccel * A.powerSlide end
	if s and s.degreesFast then s.degreesFast = s.degreesFast * A.steerFast end
	if b and b.addGravity then b.addGravity = math.max(b.addGravity, A.minGravity) end
	-- only when the script set a centre (a zero vector means "none": moving it would shift the car)
	if b and isvector(b.massCenterOverride) and b.massCenterOverride:LengthSqr() > 0 and f and f.wheels_radius then
		b.massCenterOverride = b.massCenterOverride - Vector(0, 0, f.wheels_radius * A.lowerCentre)
	end
end

---------------------------------------------------------------------------
-- on spawn
---------------------------------------------------------------------------
function E.PrepareHandling(veh)
	if veh.audioPrepared then return end
	veh.audioPrepared = true
	local car = E.GetCarConfig(veh)
	if not car then return end
	local script = E.VehicleScriptOf(veh)
	veh.audioScript = script
	veh.audioSpiked = script ~= nil and script:find("/spiked/", 1, true) ~= nil
	if veh.audioSpiked then return end

	local ok, p = pcall(veh.GetVehicleParams, veh)
	if not ok or not istable(p) or not istable(p.engine) then return end
	local changed = false
	local ph = car.script and E.PERP_PHYSICS and E.PERP_PHYSICS[car.script]
	if ph and script == E.TEST_SCRIPT then
		perpOnto(p, ph)
		veh.audioPerpPhysics = true
		changed = true
	end
	if cvHandling:GetBool() then
		antiSpin(p)
		veh.audioAntiSpin = true
		veh.audioSteerFast = E.ANTI_SPIN.steerFast   -- sv_stability expects the wider lock
		changed = true
	end
	if changed then
		E.SetParams(veh, p)
		-- the chassis mass, in case the params don't move the physics object
		local phys = veh:GetPhysicsObject()
		if veh.audioPerpPhysics and IsValid(phys) and ph.body and ph.body.massoverride then
			phys:SetMass(ph.body.massoverride)
		end
	end
end

---------------------------------------------------------------------------
-- 3. stability assist for the PERP cars, with their own steering angles
---------------------------------------------------------------------------
for _, car in pairs(E.Cars) do
	local ph = car.perp and car.script and E.PERP_PHYSICS and E.PERP_PHYSICS[car.script]
	if ph and car.stability == nil and ph.steering and ph.steering.degreesslow then
		car.stability = {
			steerSlow = ph.steering.degreesslow,
			steerFast = ph.steering.degreesfast or 12,
		}
	end
end

-- what the car you look at got: audio_engine_handling_info
concommand.Add("audio_engine_handling_info", function(ply)
	if IsValid(ply) and not ply:IsAdmin() then return end
	local veh = IsValid(ply) and ply:GetVehicle()
	if IsValid(ply) and not IsValid(veh) then veh = ply:GetEyeTrace().Entity end
	local function out(s) if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, s) else print(s) end end
	if not IsValid(veh) or not veh:IsVehicle() then out("[Audio Engine] look at or sit in a car") return end
	local car = E.GetCarConfig(veh)
	local ok, p = pcall(veh.GetVehicleParams, veh)
	out(string.format("[Audio Engine] %s | script %s | PERP physics %s | anti-spin %s | spiked %s | stability %s",
		car and car.name or veh:GetModel(), tostring(veh.audioScript), tostring(veh.audioPerpPhysics or false),
		tostring(veh.audioAntiSpin or false), tostring(veh.audioSpiked or false),
		tostring(car ~= nil and car.stability ~= false and not veh.audioSpiked)))
	if ok and istable(p) and p.engine then
		local f, r = p.axles and p.axles[1] or {}, p.axles and p.axles[2] or {}
		local phys = veh:GetPhysicsObject()
		out(string.format("  %.0f hp, top %.0f mph, mass %.0f kg, brakes %.2f/%.2f, torque %.2f/%.2f, grip x%.2f, centre %s",
			p.engine.horsepower or 0, (p.engine.maxSpeed or 0) / HU_PER_MPH, IsValid(phys) and phys:GetMass() or 0,
			f.brakeFactor or 0, r.brakeFactor or 0, f.torqueFactor or 0, r.torqueFactor or 0,
			p.body and p.body.addGravity or 0, tostring(p.body and p.body.massCenterOverride)))
	end
end, nil, "Print the handling setup of the car you're in or looking at (admins)")
