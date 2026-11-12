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

local E = AUDIO_ENGINE

local cvHandling = CreateConVar("audio_engine_handling", "0", FCVAR_ARCHIVE,
	"1 = anti-spin setup on cars with the procedural engine (front brake bias, less power while steering at speed, lower centre of mass, wider lock at speed); 0 = the vehicle script's own handling. Applies at once")

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
	-- at most this much power cut while steering at speed (the scripts cut 0.5-0.9: a fast turn
	-- lost its speed and revs; spins are caught by sv_stability and the traction control's slide cut)
	throttleReduceFast = 0.2,
	powerSlide = 1.0,       -- handbrake slide push x this (1 = the script's own: lower kills drifts)
	minGravity = 1.0,       -- at least normal grip
	lowerCentre = 0.25,     -- lower the centre of mass by this many wheel radii
	steerFast = 1.5,        -- steering angle at speed x this (the scripts' 8-13 degrees turn too little; 1.3 still did)
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
	if s and s.turnThrottleReduceFast then s.turnThrottleReduceFast = math.min(s.turnThrottleReduceFast, A.throttleReduceFast) end
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

	local ok, p = pcall(veh.GetVehicleParams, veh)
	if not ok or not istable(p) or not istable(p.engine) then return end
	if veh.audioSpiked then
		veh.audioScriptParams = table.Copy(p)
		return
	end
	local changed = false
	-- the script the spawn entry asked for (a job variant's own), else the car's base script
	local want = istable(veh.VehicleTable) and veh.VehicleTable.AudioPerpScript or car.script
	local ph = want and E.PERP_PHYSICS and (E.PERP_PHYSICS[want] or E.PERP_PHYSICS[car.script])
	if ph and script == E.TEST_SCRIPT then
		perpOnto(p, ph)
		veh.audioPerpPhysics = true
		changed = true
	end
	-- the car's handling before the anti-spin setup: E.RebaseHandling starts from it
	veh.audioScriptParams = table.Copy(p)
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

--[[
	Rebuild the car's base params (what sv_engine's E.ApplyPerformance starts from) from its script
	handling (veh.audioScriptParams, or `scriptParams` to replace it, e.g. edited live by the debug
	module), with the anti-spin setup only while audio_engine_handling is on. Switching that convar
	runs this on every car, so it applies at once (it used to take effect on cars spawned after).
]]
function E.RebaseHandling(veh, scriptParams)
	if scriptParams then veh.audioScriptParams = table.Copy(scriptParams) end
	local sp = veh.audioScriptParams
	if not sp then return false end
	local p = table.Copy(sp)
	if cvHandling:GetBool() and not veh.audioSpiked then
		antiSpin(p)
		veh.audioAntiSpin = true
		veh.audioSteerFast = E.ANTI_SPIN.steerFast * (veh.audioSteerLock or 1)
	else
		-- the lock at speed (traction tick) goes with the anti-spin setup
		veh.audioAntiSpin, veh.audioSteerFast, veh.audioSteerLock, veh.audioSteerSent = nil, nil, nil, nil
	end
	veh.audioBase = p
	if E.RefreshCarStats then E.RefreshCarStats(veh, p) end
	if E.ApplyPerformance then E.ApplyPerformance(veh, E.DecodeProfile(veh:GetNW2String("audio_prof", ""))) end
	return true
end

cvars.AddChangeCallback("audio_engine_handling", function()
	for veh in pairs(E.TrackedVehicles or {}) do
		if IsValid(veh) then E.RebaseHandling(veh) end
	end
end, "audio_engine_rebase")

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
local cvTraction = CreateConVar("audio_engine_traction", "0", FCVAR_ARCHIVE,
	"1 = traction control: less power while the driven wheels spin (strong cars launch instead of spinning)")

E.TRACTION = {
	slip = 0.25,      -- wheel surface speed this much above the car's speed counts as spinning
	minSpeed = 2,     -- m/s: below this the slip is measured against this speed
	-- it works at any speed, but how much it may take away shrinks from fadeFrom to fadeTo. (A
	-- hard cut-off at 40 m/s held a car whose wheels read as slipping at the floor all the way to
	-- ~85 mph, then gave it 4x the power at once; switching it off by fadeTo let them slide.)
	fadeFrom = 6,     -- m/s (~13 mph)
	fadeTo = 16,      -- m/s (~36 mph)
	floorFast = 0.6,  -- the least power it leaves from fadeTo up (wheelspin)
	-- sliding (sv_stability.lua's veh.audioSlide: tail out or over-rotating, not in a drift):
	-- the wheel speeds can't show it, but cutting the power is what stops it
	slideCut = 4,     -- per second at full slide
	slideFloor = 0.2, -- it may take the power down to this while sliding, at any speed...
	slideTurnFloor = 0.6, -- ...but only to this when the car still turns as steered (tail out in a fast corner)
	-- a slide that lasts longer than this stops holding the power down (it comes back at `restore`)
	-- until the slide reading clears: the straight-line hold out of a turn read as sliding for
	-- seconds and kept a car at slideFloor until W was pressed again
	slideMaxTime = 1,
	cut = 2.5,        -- how fast it takes power away while spinning (per second)
	restore = 1.2,    -- ... and gives it back while gripping
	floor = 0.25,     -- never below this share of the power (at a standstill)
	step = 0.04,      -- only re-sends the params when the trim moved this much
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

--[[
	...and never wider than the tyres can use: on a keyboard every turn is full lock, and past the
	angle that gives the most cornering the front tyres only scrub. At 60 mph the curve still had
	~20 deg: with W held turns slowed the cars at ~1 g. The lock is capped at the angle a turn of
	`g` needs at this speed and wheelbase, plus the tyres' `slip` angle (deg)
]]
E.STEER_GRIP = { g = 1.5, slip = 6 }

local function gripLock(veh, mph)
	local geo = E.CarGeometry and E.CarGeometry(veh)
	local wheelbase = geo and geo.wheelbase or 2.6
	local v = math.max(mph / 2.23694, 1)
	local turn = math.deg(math.atan(wheelbase * E.STEER_GRIP.g * 9.81 / (v * v)))

	return turn + E.STEER_GRIP.slip
end

local function lockScale(veh, mph)
	local st = veh.audioBase and veh.audioBase.steering
	local S, F = st and st.degreesSlow, st and st.degreesFast
	if not (S and F and F > 0) then return steerScale(mph) end
	local C = E.STEER_CURVE
	local k = (1 - math.Clamp(mph / C.toMph, 0, 1)) ^ C.power
	local want = math.min((F + (S - F) * k) * steerScale(mph), gripLock(veh, mph))
	local frac = mph / C.blendMph
	local fast = frac >= 1 and want or (frac > 0.05 and S + (want - S) / frac or F)
	return math.Clamp(fast / F, 0.3, 4)
end

-- the fastest-turning driven wheel's surface speed (m/s), from the wheel physics objects
local function drivenWheelSpeed(veh)
	local p = veh.audioBase
	if not (p and p.axles) then return nil end
	local fastest
	for axle = 1, #p.axles do
		local a = p.axles[axle]
		if (a.torqueFactor or 0) > 0 and a.wheels_radius then
			for side = 0, 1 do
				local w = veh:GetWheel((axle - 1) * 2 + side)
				if IsValid(w) then
					-- deg/s about the axle; the steering turn is small next to a spinning wheel
					local surf = math.rad(w:GetAngleVelocity():Length()) * a.wheels_radius * 0.0254
					if not fastest or surf > fastest then fastest = surf end
				end
			end
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

-- traction control and the steering lock at speed: both change the car's params on the fly
hook.Add("Tick", "audio_engine_traction", function()
	local on = cvTraction:GetBool()
	local T, dt = E.TRACTION, engine.TickInterval()
	for veh in pairs(E.TrackedVehicles or {}) do
		-- no driver and nothing left to put back (full power, no limiter): nothing to do. The
		-- steering lock is caught up on the first tick someone drives it
		local idle = IsValid(veh) and not IsValid(veh:GetDriver()) and (veh.audioTCSent or 1) == 1
			and veh.audioCruisePowSent == nil and not veh.audioCruise and not veh.audioParamsDirty
		if IsValid(veh) and not veh.audioSpiked and veh.audioBase and not idle then
			local phys = veh:GetPhysicsObject()
			local v = IsValid(phys) and phys:GetVelocity():Length() * 0.0254 or 0
			-- steering: only on cars that got the wider lock (anti-spin setup)
			local steer = veh.audioAntiSpin and lockScale(veh, v * 2.23694) or nil
			if steer and math.abs(steer - (veh.audioSteerSent or 1)) >= 0.03 then
				veh.audioSteerLock = steer   -- (not audioSteer: sv_stability keeps the A/D input there)
				veh.audioSteerSent = steer
				veh.audioSteerFast = E.ANTI_SPIN.steerFast * steer   -- sv_stability follows the lock
				veh.audioParamsDirty = true
			end

			local tc = veh.audioTC or 1
			local want = tc
			local drv = veh:GetDriver()
			-- the lowest trim allowed at this speed: T.floor at a standstill, T.floorFast from fadeTo
			local f = math.Clamp((v - T.fadeFrom) / (T.fadeTo - T.fadeFrom), 0, 1)
			local floor = T.floor + (T.floorFast - T.floor) * f * f * (3 - 2 * f)
			if on and IsValid(drv) and IsValid(phys) and drv:KeyDown(IN_FORWARD) then
				-- (only a fresh reading: with the stability assist off nothing updates it)
				local slide = CurTime() - (veh.audioSlideT or 0) < 0.2 and veh.audioSlide or 0
				local ws = drivenWheelSpeed(veh)
				local slip = ws and (ws - v) / math.max(v, T.minSpeed) or 0
				veh.audioSlip = slip
				if slide > 0.05 then
					veh.audioSlideSince = veh.audioSlideSince or CurTime()
				else
					veh.audioSlideSince = nil
				end
				local slideCuts = slide > 0.05 and CurTime() - veh.audioSlideSince < T.slideMaxTime
				if slideCuts then
					want = tc - T.slideCut * slide * dt
					floor = math.min(floor, veh.audioSpin == false and T.slideTurnFloor or T.slideFloor)
				elseif slip > T.slip then want = tc - T.cut * dt
				else want = tc + T.restore * dt end
				want = math.Clamp(want, math.min(floor, tc), 1)
			else
				want = 1
				veh.audioSlideSince = nil
			end
			-- speed limiter (sv_cruise.lua): W held near the limit, the power trimmed to hold it;
			-- over it, off (it brakes there too)
			local cp
			if veh.audioCruise then
				local C, mph = E.CRUISE, v * 2.23694
				-- the car's acceleration (mph/s, smoothed)
				local acc = veh.audioLimLastV and (mph - veh.audioLimLastV) / dt or 0
				veh.audioLimAcc = (veh.audioLimAcc or 0) + (acc - (veh.audioLimAcc or 0)) * math.min(1, dt * 10)
				veh.audioLimLastV = mph
				if veh.audioLimBrake then
					cp = C.minPow
				elseif veh.audioLimHold then
					-- the acceleration it wants shrinks to nothing at the limit; the power follows
					local want = C.k * (veh.audioCruise - mph)
					veh.audioCruiseI = math.Clamp((veh.audioCruiseI or 1) + C.ki * (want - veh.audioLimAcc) * dt, C.minPow, 1)
					cp = veh.audioCruiseI
				end
			else
				veh.audioLimLastV, veh.audioLimAcc = nil, nil
			end
			local cstep = veh.audioCruise and E.CRUISE.powStep or T.step
			if math.abs((cp or 1) - (veh.audioCruisePowSent or 1)) >= cstep or (cp == nil and veh.audioCruisePowSent ~= nil) then
				veh.audioCruisePowSent = cp
				veh.audioParamsDirty = true
			end
			veh.audioCruisePow = cp
			-- params are re-sent only on a real change (and always when it's back to full)
			if math.abs(want - (veh.audioTCSent or 1)) >= T.step or (want == 1 and (veh.audioTCSent or 1) ~= 1) then
				veh.audioTCSent = want
				veh.audioParamsDirty = true
			end
			veh.audioTC = want
			if veh.audioParamsDirty then
				veh.audioParamsDirty = false
				E.ApplyPerformance(veh, profileOf(veh))
			end
		end
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
	local function out(s) if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, s) end end
	out("[Audio Engine] accel log: t | mph | Source gear, rpm | wheel slip | slide | power x | steer x | wheel angle deg"
		.. " | yaw off what's asked deg/s, slip angle deg")
	local id = "audio_engine_accel_log_" .. veh:EntIndex()
	-- calibration for the acceleration model (sh_presets.lua E.GEAR_ACCEL): the time to each share of the
	-- top speed, next to the model's. Start from a standstill and hold W on a straight road
	local topKmh = E.CarTopSpeed(veh, E.GetCarConfig(veh))
	local wkg = E.CarPower(veh, E.GetCarConfig(veh)) * ((E.DecodeProfile(veh:GetNW2String("audio_prof", "")) or {}).accel or 1)
	local marks, reached, tGo = { 0.25, 0.5, 0.75, 0.9, 0.95 }, {}, nil
	local function report()
		local parts = {}
		for _, m in ipairs(marks) do
			parts[#parts + 1] = string.format("%d%% %s (model %.1f)", m * 100,
				reached[m] and string.format("%.1fs", reached[m]) or "-", E.GearModelTime(topKmh, wkg, m))
		end
		out(string.format("[Audio Engine] top %.0f mph, %.0f W/kg: time to share of top speed: %s",
			topKmh / 1.609344, wkg, table.concat(parts, ", ")))
	end
	local cfg = E.GetEngineConfig(veh)
	if cfg and cfg.gears and cfg.final then
		local ends, K = {}, 60 / (2 * math.pi * (cfg.wheelRadius or 0.33))
		for i, g in ipairs(cfg.gears) do ends[i] = string.format("%.0f", cfg.redline / (K * g * cfg.final) * 2.23694) end
		out("[Audio Engine] sound gears reach redline at " .. table.concat(ends, " / ") .. " mph")
	end
	local ticks = math.floor(secs * 4)
	timer.Create(id, 0.25, ticks, function()
		if not IsValid(veh) then timer.Remove(id) return end
		local phys = veh:GetPhysicsObject()
		local mph = IsValid(phys) and phys:GetVelocity():Length() * 0.0254 * 2.23694 or 0
		if not tGo and mph > 0.5 then tGo = CurTime() - 0.125 end   -- (it set off within the last sample)
		if tGo then
			for _, m in ipairs(marks) do
				if not reached[m] and mph * 1.609344 >= topKmh * m then reached[m] = CurTime() - tGo end
			end
		end
		ticks = ticks - 1
		if ticks <= 0 or reached[0.95] then timer.Remove(id) report() end
		local okp, op = pcall(veh.GetOperatingParams, veh)
		op = okp and istable(op) and op or {}
		local hold = veh.audioLogYaw and string.format(" | %5.1f %5.1f", veh.audioLogYaw, veh.audioLogBeta) or ""
		out(string.format("  %5.2fs | %5.1f | G%s %5.0f | %5.2f | %.2f | %.2f | %.2f | %5.1f%s", CurTime() - t0, mph,
			tostring(op.gear or "?"), op.RPM or 0, veh.audioSlip or 0, veh.audioSlide or 0, veh.audioTC or 1,
			veh.audioSteerLock or 1, op.steeringAngle or 0, hold))
	end)
end, nil, "Log speed, Source gear/rpm, wheel slip and traction trim of the car you drive (admins)")

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
		out(string.format("  traction control: power x%.2f, last wheel slip %.2f", veh.audioTC or 1, veh.audioSlip or 0))
		out(string.format("  %.0f hp, top %.0f mph, mass %.0f kg, brakes %.2f/%.2f, torque %.2f/%.2f, grip x%.2f, centre %s",
			p.engine.horsepower or 0, (p.engine.maxSpeed or 0) / HU_PER_MPH, IsValid(phys) and phys:GetMass() or 0,
			f.brakeFactor or 0, r.brakeFactor or 0, f.torqueFactor or 0, r.torqueFactor or 0,
			p.body and p.body.addGravity or 0, tostring(p.body and p.body.massCenterOverride)))
	end
end, nil, "Print the handling setup of the car you're in or looking at (admins)")
