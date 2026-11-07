--[[
	Audio Engine - handling (server)

	Runs once on every registered car as it spawns, before its physics are captured as the
	base for engine tuning (sv_engine.lua):

	1. PERP physics on the test script. Off the PERP server, PERP's vehicle scripts aren't mounted
	   and the spawn menu falls back to scripts/vehicles/audio_engine/test_car.txt (sh_perp.lua).
	   The car's own PERP base script values (sv_perp_physics.lua: horsepower, top speed, gearing,
	   mass, steering, suspension, torque and brake split, manual gearbox) are then put on it, so it accelerates,
	   tops out and handles like on the server. They're applied as ratios to test_car.txt's own
	   values, so Source's internal units never matter.
	2. Anti-spin setup (audio_engine_handling 1): brakes biased to the front (a locking rear
	   spins the car), at most a 20% power cut while steering at speed, a slightly lower centre of mass, at
	   least normal grip, and more steering lock at speed. Relative changes only.
	3. Stability assist (sv_stability.lua) for the PERP cars, with each car's own steering angles.
	4. Launch traction control (audio_engine_traction 1). Source turns horsepower into wheel torque
	   that is biggest at low wheel speed, so a strong, light car (Veyron 490 hp, SLR 420 hp at
	   1700 kg) just spins its tyres off the line, barely moving, then hooks up and rockets once
	   it's fast. While the driven wheels turn faster than the car moves, the horsepower is
	   trimmed until they grip, and given back as they do. Off the line it may cut to 1/4 of the
	   power; from ~36 mph to no less than 60%, so it catches slides without holding the car back.
	   When the car slides (tail out or over-rotating, from sv_stability.lua; not in a handbrake
	   drift) it cuts the power quickly, down to 20% at any speed, until it straightens up.
	5. High-speed steering: the wider lock of step 2 tightens to 0.9 between ~45 and
	   90 mph (E.HIGH_SPEED_STEER), so the car turns well at town speeds and holds its speed in fast turns.

	A car on a spiked/ tier script (tyres shot by a stinger) gets none of it: it's meant to be
	hard to drive.
]]

local E = PerpAudioEngine

local cvHandling = CreateConVar(
	"audio_engine_handling",
	"1",
	FCVAR_ARCHIVE,
	"1 = anti-spin setup on cars with the procedural engine (front brake bias, less power while steering "
		.. "at speed, lower centre of mass); applies to cars spawned after"
)

---------------------------------------------------------------------------
-- setting vehicle params
---------------------------------------------------------------------------
local HU_PER_MPH = 17.6 -- GetVehicleParams speeds are inches/s; SetVehicleParams takes mph
local SPEED_KEYS = { "maxSpeed", "maxRevSpeed", "boostMaxSpeed" }
E.HU_PER_MPH = HU_PER_MPH

-- the driven (or settling) cars: what the per-tick hooks loop over. sv_engine.lua keeps it
E.ActiveVehicles = E.ActiveVehicles or {}

-- GetVehicleParams, or nil on a vehicle that has none (a seat on a car's model)
function E.ReadParams(veh)
	local ok, p = pcall(veh.GetVehicleParams, veh)
	if not ok then
		ErrorNoHalt("[Audio Engine] GetVehicleParams failed: " .. tostring(p) .. "\n")
		return nil
	end
	if istable(p) and istable(p.engine) then return p end
end

-- what the speeds are divided by for SetVehicleParams; proved on the first car (E.SetParams)
local speedDivisor = HU_PER_MPH
local speedUnitChecked = false

-- sets p on the car with its speeds divided by divisor, leaving p as it was
local function sendParams(veh, p, divisor)
	local engineParams = p.engine
	local maxSpeed, maxRevSpeed, boostMaxSpeed
	if engineParams then
		maxSpeed, maxRevSpeed, boostMaxSpeed =
			engineParams.maxSpeed, engineParams.maxRevSpeed, engineParams.boostMaxSpeed
		for _, k in ipairs(SPEED_KEYS) do
			if engineParams[k] then engineParams[k] = engineParams[k] / divisor end
		end
	end
	local ok, err = pcall(veh.SetVehicleParams, veh, p)
	if engineParams then
		engineParams.maxSpeed, engineParams.maxRevSpeed = maxSpeed, maxRevSpeed
		engineParams.boostMaxSpeed = boostMaxSpeed
	end
	if not ok then ErrorNoHalt("[Audio Engine] SetVehicleParams failed: " .. tostring(err) .. "\n") end

	return ok
end

-- p is a table as GetVehicleParams returns it (speeds in its units). Sets it on the car, giving
-- SetVehicleParams the speeds it wants. Reading back a whole params table on every traction
-- change is too dear, and the unit is the engine's, not the car's: it's checked the first time.
function E.SetParams(veh, p)
	if not sendParams(veh, p, speedDivisor) then return false end
	if speedUnitChecked or not (p.engine and p.engine.maxSpeed) then return true end
	local chk = E.ReadParams(veh)
	if not (chk and chk.engine.maxSpeed) then return true end
	speedUnitChecked = true
	-- self-check the speed unit: if the engine took our mph as inches/s, set it again scaled
	local sent = p.engine.maxSpeed / HU_PER_MPH
	if math.abs(chk.engine.maxSpeed - sent) < math.abs(chk.engine.maxSpeed - p.engine.maxSpeed) then
		speedDivisor = 1
		sendParams(veh, p, speedDivisor)
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
	engine = {
		horsepower = 320,
		maxRPM = 6000,
		maxSpeed = 125,
		maxRevSpeed = 20,
		shiftUpRPM = 5600,
		shiftDownRPM = 2600,
	},
	body = { massOverride = 1600, maxAngularVelocity = 200, massCenterZ = -5 },
	steering = { degreesSlow = 38, degreesFast = 14, degreesBoost = 10, powerSlideAccel = 150 },
	axles = {
		{
			suspension_springConstant = 110,
			suspension_springDamping = 0.9,
			suspension_springDampingCompression = 5.5,
			suspension_stabilizerConstant = 120,
			suspension_maxBodyForce = 30,
			wheels_mass = 170,
		},
		{
			suspension_springConstant = 105,
			suspension_springDamping = 0.9,
			suspension_springDampingCompression = 5.5,
			suspension_stabilizerConstant = 110,
			suspension_maxBodyForce = 30,
			wheels_mass = 170,
		},
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
	-- PERP's scripts are manual (autotransmission 0): Source keeps one ratio up to top speed.
	-- The test script is automatic, and its box sat in top gear (slow) until the revs passed
	-- maxRPM, then dropped into 1st and rocketed: the Veyron crawled to 70 mph, then flew
	if pe.autotransmission ~= nil then set(e, "isAutoTransmission", pe.autotransmission ~= 0) end
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
			ratio(
				a,
				"suspension_springDampingCompression",
				pa.springdampingcompression,
				ta.suspension_springDampingCompression
			)
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
	frontBrake = 0.6, -- at least this share of the braking on the front axle
	-- at most this much power cut while steering at speed (the scripts cut 0.5-0.9: a fast turn
	-- lost its speed and revs; spins are caught by sv_stability and the traction control's slide cut)
	throttleReduceFast = 0.2,
	powerSlide = 1.0, -- handbrake slide push x this (1 = the script's own: lower kills drifts)
	minGravity = 1.0, -- at least normal grip
	lowerCentre = 0.25, -- lower the centre of mass by this many wheel radii
	steerFast = 1.5, -- steering angle at speed x this (the scripts' 8-13 degrees turn too little; 1.3 still did)
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
	if s and s.turnThrottleReduceFast then
		s.turnThrottleReduceFast = math.min(s.turnThrottleReduceFast, A.throttleReduceFast)
	end
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

	local p = E.ReadParams(veh)
	if not p then return end
	local changed = false
	-- the script the spawn entry asked for (a job variant's own), else the car's base script
	local want = istable(veh.VehicleTable) and veh.VehicleTable.AudioPerpScript or car.script
	local ph = want and E.PERP_PHYSICS and (E.PERP_PHYSICS[want] or E.PERP_PHYSICS[car.script])
	if ph and script == E.TEST_SCRIPT then
		perpOnto(p, ph)
		veh.audioPerpPhysics = true
		changed = true
	end
	if cvHandling:GetBool() then
		antiSpin(p)
		veh.audioAntiSpin = true
		veh.audioSteerFast = E.ANTI_SPIN.steerFast -- sv_stability expects the wider lock
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

---------------------------------------------------------------------------
-- 4. launch traction control
---------------------------------------------------------------------------
local INCH_TO_M = 0.0254
local MPH_PER_MS = 2.23694

local cvTraction = CreateConVar(
	"audio_engine_traction",
	"1",
	FCVAR_ARCHIVE,
	"1 = traction control: less power while the driven wheels spin (strong cars launch instead of spinning)"
)

E.TRACTION = {
	slip = 0.25, -- wheel surface speed this much above the car's speed counts as spinning
	minSpeed = 2, -- m/s: below this the slip is measured against this speed
	-- it works at any speed, but how much it may take away shrinks from fadeFrom to fadeTo. (A
	-- hard cut-off at 40 m/s held a car whose wheels read as slipping at the floor all the way to
	-- ~85 mph, then gave it 4x the power at once; switching it off by fadeTo let them slide.)
	fadeFrom = 6, -- m/s (~13 mph)
	fadeTo = 16, -- m/s (~36 mph)
	floorFast = 0.6, -- the least power it leaves from fadeTo up (wheelspin)
	-- sliding (sv_stability.lua's veh.audioSlide: tail out or over-rotating, not in a drift):
	-- the wheel speeds can't show it, but cutting the power is what stops it
	slideCut = 4, -- per second at full slide
	slideFloor = 0.2, -- it may take the power down to this while sliding, at any speed
	cut = 2.5, -- how fast it takes power away while spinning (per second)
	restore = 1.2, -- ... and gives it back while gripping
	floor = 0.25, -- never below this share of the power (at a standstill)
	step = 0.04, -- only re-sends the params when the trim moved this much
	-- ...and no more often than this (s): at 2.5/s the 0.04 step came round on every tick, and
	-- SetVehicleParams with a whole params table is the dearest thing a driven car does
	applyInterval = 0.05,
}

-- steering lock at speed, x the (already widened) degreesFast: 1 up to fromMph, `scale` from toMph.
-- Tightens from town speeds on: a fast turn on the wide lock scrubbed off speed and revs
-- (11 deg script x 1.5 x 0.9 = ~14.9 deg at 90 mph; 1.3 x 0.65 by 80 mph, then 1.3 x 0.8, turned too little)
E.HIGH_SPEED_STEER = { fromMph = 45, toMph = 90, scale = 0.9 }

local function steerScale(mph)
	local H = E.HIGH_SPEED_STEER
	local t = math.Clamp((mph - H.fromMph) / (H.toMph - H.fromMph), 0, 1)
	t = t * t * (3 - 2 * t)
	return 1 + (H.scale - 1) * t
end

--[[
	The scripts blend DegreesSlow (~38) into DegreesFast (~11) by 35 mph (FastCarSpeed), so at
	30 mph the wheels were nearly at the high-speed lock already. The lock we want instead fades
	from the slow lock to the (widened) fast one over E.STEER_CURVE.toMph, (1 - mph/toMph)^power:
	the SL65 (38.5 / 16.5) gets ~28 deg at 30 mph and ~23 at 50 (was ~20 and ~16).
	Source keeps blending below blendMph, so degreesFast is set to what makes its blend land there.
	Returns the multiplier on the car's degreesFast (veh.audioSteerLock).
]]
E.STEER_CURVE = { toMph = 90, power = 1.5, blendMph = 35 }

local function lockScale(veh, mph)
	local st = veh.audioBase and veh.audioBase.steering
	local S, F = st and st.degreesSlow, st and st.degreesFast
	if not (S and F and F > 0) then return steerScale(mph) end
	local C = E.STEER_CURVE
	local k = (1 - math.Clamp(mph / C.toMph, 0, 1)) ^ C.power
	local want = (F + (S - F) * k) * steerScale(mph)
	local frac = mph / C.blendMph
	local fast = frac >= 1 and want or (frac > 0.05 and S + (want - S) / frac or F)
	return math.Clamp(fast / F, 0.3, 4)
end

-- a wheel's surface speed (m/s), or nil if it has no physics object
local function wheelSurfaceSpeed(veh, index, radius)
	local w = veh:GetWheel(index)
	if not IsValid(w) then return nil end

	-- deg/s about the axle; the steering turn is small next to a spinning wheel
	return math.rad(w:GetAngleVelocity():Length()) * radius * INCH_TO_M
end

-- the fastest-turning driven wheel's surface speed (m/s), from the wheel physics objects
local function drivenWheelSpeed(veh)
	local p = veh.audioBase
	if not (p and p.axles) then return nil end
	local fastest
	for axle = 1, #p.axles do
		local a = p.axles[axle]
		if (a.torqueFactor or 0) > 0 and a.wheels_radius then
			local left = wheelSurfaceSpeed(veh, (axle - 1) * 2, a.wheels_radius)
			local right = wheelSurfaceSpeed(veh, (axle - 1) * 2 + 1, a.wheels_radius)
			if left and (not fastest or left > fastest) then fastest = left end
			if right and (not fastest or right > fastest) then fastest = right end
		end
	end

	return fastest
end

local profCache = setmetatable({}, { __mode = "k" })
local function profileOf(veh)
	local s = veh:GetNW2String("audio_prof", "")
	local c = profCache[veh]
	if c and c.s == s then return c.p end
	local prof = E.DecodeProfile(s)
	profCache[veh] = { s = s, p = prof }
	return prof
end

-- the steering lock at speed: only on cars that got the wider lock (anti-spin setup)
local function updateSteerLock(veh, v)
	if not veh.audioAntiSpin then return end
	local steer = lockScale(veh, v * MPH_PER_MS)
	if math.abs(steer - (veh.audioSteerSent or 1)) < 0.03 then return end
	veh.audioSteerLock = steer -- (not audioSteer: sv_stability keeps the A/D input there)
	veh.audioSteerSent = steer
	veh.audioSteerFast = E.ANTI_SPIN.steerFast * steer -- sv_stability follows the lock
	veh.audioParamsDirty = true
end

-- the power share traction control wants now
local function tractionTrim(veh, phys, v, on, dt)
	local T = E.TRACTION
	local drv = veh:GetDriver()
	if not (on and IsValid(drv) and IsValid(phys) and drv:KeyDown(IN_FORWARD)) then return 1 end
	local tc = veh.audioTC or 1
	-- the lowest trim allowed at this speed: T.floor at a standstill, T.floorFast from fadeTo
	local f = math.Clamp((v - T.fadeFrom) / (T.fadeTo - T.fadeFrom), 0, 1)
	local floor = T.floor + (T.floorFast - T.floor) * f * f * (3 - 2 * f)
	-- (only a fresh reading: with the stability assist off nothing updates it)
	local slide = CurTime() - (veh.audioSlideT or 0) < 0.2 and veh.audioSlide or 0
	local ws = drivenWheelSpeed(veh)
	local slip = ws and (ws - v) / math.max(v, T.minSpeed) or 0
	veh.audioSlip = slip
	local want
	if slide > 0.05 then
		want = tc - T.slideCut * slide * dt
		floor = math.min(floor, T.slideFloor)
	elseif slip > T.slip then
		want = tc - T.cut * dt
	else
		want = tc + T.restore * dt
	end

	return math.Clamp(want, math.min(floor, tc), 1)
end

-- speed limiter (sv_cruise.lua): W held near the limit, the power trimmed to hold it;
-- over it, off (it brakes there too). nil = no limit on the power
local function limiterPower(veh, v, dt)
	if not veh.audioCruise then
		veh.audioLimLastV, veh.audioLimAcc = nil, nil
		return nil
	end
	local C, mph = E.CRUISE, v * MPH_PER_MS
	-- the car's acceleration (mph/s, smoothed)
	local acc = veh.audioLimLastV and (mph - veh.audioLimLastV) / dt or 0
	veh.audioLimAcc = (veh.audioLimAcc or 0) + (acc - (veh.audioLimAcc or 0)) * math.min(1, dt * 10)
	veh.audioLimLastV = mph
	if veh.audioLimBrake then return C.minPow end
	if not veh.audioLimHold then return nil end
	-- the acceleration it wants shrinks to nothing at the limit; the power follows
	local want = C.k * (veh.audioCruise - mph)
	local power = (veh.audioCruiseI or 1) + C.ki * (want - veh.audioLimAcc) * dt
	veh.audioCruiseI = math.Clamp(power, C.minPow, 1)

	return veh.audioCruiseI
end

-- params are re-sent only on a real change (and always when it's back to full)
local function noteTrims(veh, tc, cruisePow)
	local T = E.TRACTION
	local step = veh.audioCruise and E.CRUISE.powStep or T.step
	local sentPow = veh.audioCruisePowSent
	if math.abs((cruisePow or 1) - (sentPow or 1)) >= step or (cruisePow == nil and sentPow ~= nil) then
		veh.audioCruisePowSent = cruisePow
		veh.audioParamsDirty = true
	end
	veh.audioCruisePow = cruisePow
	local sentTc = veh.audioTCSent or 1
	if math.abs(tc - sentTc) >= T.step or (tc == 1 and sentTc ~= 1) then
		veh.audioTCSent = tc
		veh.audioParamsDirty = true
	end
	veh.audioTC = tc
end

local function updateCarPower(veh, on, dt, now)
	local phys = veh:GetPhysicsObject()
	local v = IsValid(phys) and phys:GetVelocity():Length() * INCH_TO_M or 0
	updateSteerLock(veh, v)
	local tc = tractionTrim(veh, phys, v, on, dt)
	noteTrims(veh, tc, limiterPower(veh, v, dt))
	if not veh.audioParamsDirty or now < (veh.audioParamsNext or 0) then return end
	veh.audioParamsDirty = false
	veh.audioParamsNext = now + E.TRACTION.applyInterval
	E.ApplyPerformance(veh, profileOf(veh))
end

-- traction control and the steering lock at speed: both change the car's params on the fly
hook.Add("Tick", "perpheads/audio-engine/traction", function()
	local on = cvTraction:GetBool()
	local dt, now = engine.TickInterval(), CurTime()
	for veh in pairs(E.ActiveVehicles) do
		if IsValid(veh) and not veh.audioSpiked and veh.audioBase then updateCarPower(veh, on, dt, now) end
	end
end)

-- audio_engine_accel_log [seconds]: logs the car you drive to the console 4x a second (admins).
-- Source's own gear and rpm (GetOperatingParams) next to speed, wheel slip, traction trim and the
-- steering scale: shows where a car's acceleration goes during a launch.
concommand.Add("audio_engine_accel_log", function(ply, _, args)
	if IsValid(ply) and not ply:IsAdmin() then return end
	local veh = IsValid(ply) and ply:GetVehicle()
	if not IsValid(veh) then return end
	local secs = math.Clamp(tonumber(args[1]) or 12, 1, 60)
	local t0 = CurTime()
	local function out(s)
		if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, s) end
	end
	out("[Audio Engine] accel log: t | mph | Source gear, rpm | wheel slip | slide | power x | steer x")
	local id = "audio_engine_accel_log_" .. veh:EntIndex()
	timer.Create(id, 0.25, math.floor(secs * 4), function()
		if not IsValid(veh) then
			timer.Remove(id)
			return
		end
		local phys = veh:GetPhysicsObject()
		local mph = IsValid(phys) and phys:GetVelocity():Length() * 0.0254 * 2.23694 or 0
		local okp, op = pcall(veh.GetOperatingParams, veh)
		op = okp and istable(op) and op or {}
		out(
			string.format(
				"  %5.2fs | %5.1f | G%s %5.0f | %5.2f | %.2f | %.2f | %.2f",
				CurTime() - t0,
				mph,
				tostring(op.gear or "?"),
				op.RPM or 0,
				veh.audioSlip or 0,
				veh.audioSlide or 0,
				veh.audioTC or 1,
				veh.audioSteerLock or 1
			)
		)
	end)
end, nil, "Log speed, Source gear/rpm, wheel slip and traction trim of the car you drive (admins)")

-- what the car you look at got: audio_engine_handling_info
concommand.Add("audio_engine_handling_info", function(ply)
	if IsValid(ply) and not ply:IsAdmin() then return end
	local veh = IsValid(ply) and ply:GetVehicle()
	if IsValid(ply) and not IsValid(veh) then veh = ply:GetEyeTrace().Entity end
	local function out(s)
		if IsValid(ply) then
			ply:PrintMessage(HUD_PRINTCONSOLE, s)
		else
			print(s)
		end
	end
	if not IsValid(veh) or not veh:IsVehicle() then
		out("[Audio Engine] look at or sit in a car")
		return
	end
	local car = E.GetCarConfig(veh)
	local ok, p = pcall(veh.GetVehicleParams, veh)
	out(
		string.format(
			"[Audio Engine] %s | script %s | PERP physics %s | anti-spin %s | spiked %s | stability %s",
			car and car.name or veh:GetModel(),
			tostring(veh.audioScript),
			tostring(veh.audioPerpPhysics or false),
			tostring(veh.audioAntiSpin or false),
			tostring(veh.audioSpiked or false),
			tostring(car ~= nil and car.stability ~= false and not veh.audioSpiked)
		)
	)
	if ok and istable(p) and p.engine then
		local f, r = p.axles and p.axles[1] or {}, p.axles and p.axles[2] or {}
		local phys = veh:GetPhysicsObject()
		out(
			string.format("  traction control: power x%.2f, last wheel slip %.2f", veh.audioTC or 1, veh.audioSlip or 0)
		)
		out(
			string.format(
				"  %.0f hp, top %.0f mph, mass %.0f kg, brakes %.2f/%.2f, torque %.2f/%.2f, grip x%.2f, centre %s",
				p.engine.horsepower or 0,
				(p.engine.maxSpeed or 0) / HU_PER_MPH,
				IsValid(phys) and phys:GetMass() or 0,
				f.brakeFactor or 0,
				r.brakeFactor or 0,
				f.torqueFactor or 0,
				r.torqueFactor or 0,
				p.body and p.body.addGravity or 0,
				tostring(p.body and p.body.massCenterOverride)
			)
		)
	end
end, nil, "Print the handling setup of the car you're in or looking at (admins)")
