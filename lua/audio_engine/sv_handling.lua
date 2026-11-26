--[[
	Audio Engine - handling (server)

	1. On spawn, before the car's physics are captured as the base for engine tuning (sv_engine.lua):
	   PERP physics on the test script. Off the PERP server, PERP's vehicle scripts aren't mounted
	   and the spawn menu falls back to scripts/vehicles/audio_engine/test_car.txt (sh_perp.lua).
	   The car's own PERP base script values (sv_perp_physics.lua: horsepower, top speed, gearing,
	   mass, steering, suspension, torque and brake split, manual gearbox) are then put on it, so it
	   accelerates, tops out and handles like on the server. They're applied as ratios to
	   test_car.txt's own values, so Source's internal units never matter.
	2. Every tick, on every driven car: the handling model (sh_handling.lua) takes over the
	   rotation and sideways grip (audio_engine_drivemodel). Source's jeep keeps the engine, brakes,
	   suspension and all collisions, so crashes between players stay the server's alone.

	The work per car per tick is a few physics reads, four wheel contacts and the model's
	arithmetic. No vehicle params are set while driving (but Source's wheels over FastCarSpeed,
	matchSteering below).

	A car on a spiked/ tier script (tyres shot by a stinger) gets no model: it's meant to be hard
	to drive.
]]

local AudioEngine = AUDIO_ENGINE

---------------------------------------------------------------------------
-- setting vehicle params
---------------------------------------------------------------------------
local HU_PER_MPH = 17.6   -- GetVehicleParams speeds are inches/s; SetVehicleParams takes mph
local SPEED_KEYS = { "maxSpeed", "maxRevSpeed", "boostMaxSpeed" }
AudioEngine.HU_PER_MPH = HU_PER_MPH
local MPH_TO_METRES = 0.44704   -- m/s per mph

-- p is a table as GetVehicleParams returns it (speeds in its units). Sets it on the car, giving
-- SetVehicleParams the speeds it wants, and checks the unit took.
function AudioEngine.SetParams(vehicle, params)
	params = table.Copy(params)
	-- Source's wheels over FastCarSpeed matched to the model (matchSteering, below)
	local steerOverride = vehicle.audioSteerOverride
	if steerOverride and istable(params.steering) then
		params.steering.degreesFast, params.steering.speedFast = steerOverride.degreesFast, steerOverride.speedFast
	end
	for _, speedKey in ipairs(SPEED_KEYS) do
		if params.engine and params.engine[speedKey] then params.engine[speedKey] = params.engine[speedKey] / HU_PER_MPH end
	end
	if not pcall(vehicle.SetVehicleParams, vehicle, params) then return false end
	-- self-check the speed unit: if the engine took our mph as inches/s, set it again scaled
	local succeeded, applied = pcall(vehicle.GetVehicleParams, vehicle)
	if succeeded and istable(applied) and applied.engine and applied.engine.maxSpeed and params.engine and params.engine.maxSpeed then
		local expectedSpeed = params.engine.maxSpeed * HU_PER_MPH
		if math.abs(applied.engine.maxSpeed - params.engine.maxSpeed) < math.abs(applied.engine.maxSpeed - expectedSpeed) then
			for _, speedKey in ipairs(SPEED_KEYS) do
				if params.engine[speedKey] then params.engine[speedKey] = params.engine[speedKey] * HU_PER_MPH end
			end
			pcall(vehicle.SetVehicleParams, vehicle, params)
		end
	end
	return true
end

---------------------------------------------------------------------------
-- which script the car spawned with
---------------------------------------------------------------------------
AudioEngine.TEST_SCRIPT = "scripts/vehicles/audio_engine/test_car.txt"

function AudioEngine.VehicleScriptOf(vehicle)
	local keyValues = vehicle:GetKeyValues() or {}
	local script = keyValues.vehiclescript or keyValues.VehicleScript or keyValues.vehicleScript
	if (not script or script == "") and istable(vehicle.VehicleTable) and istable(vehicle.VehicleTable.KeyValues) then
		script = vehicle.VehicleTable.KeyValues.vehiclescript
	end
	if not isstring(script) or script == "" then return nil end
	return (string.lower(script):gsub("\\", "/"))
end

---------------------------------------------------------------------------
-- PERP physics on a car that's on the test script
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
local function scaleByRatio(section, key, perp, test)
	if not (section and section[key] and perp and test and test ~= 0) then return end
	section[key] = section[key] * perp / test
end
-- a unitless field (fractions, ratios, multipliers): set it straight
local function setValue(section, key, value)
	if section and section[key] ~= nil and value ~= nil then section[key] = value end
end

local function applyPerpPhysics(params, perpPhysics)
	local engineParams, bodyParams, steeringParams = params.engine, params.body, params.steering
	local perpEngine, perpBody, perpSteering = perpPhysics.engine or {}, perpPhysics.body or {}, perpPhysics.steering or {}
	scaleByRatio(engineParams, "horsepower", perpEngine.horsepower, TEST.engine.horsepower)
	scaleByRatio(engineParams, "maxRPM", perpEngine.maxrpm, TEST.engine.maxRPM)
	scaleByRatio(engineParams, "maxSpeed", perpEngine.maxspeed, TEST.engine.maxSpeed)
	scaleByRatio(engineParams, "maxRevSpeed", perpEngine.maxreversespeed, TEST.engine.maxRevSpeed)
	scaleByRatio(engineParams, "shiftUpRPM", perpEngine.shiftuprpm, TEST.engine.shiftUpRPM)
	scaleByRatio(engineParams, "shiftDownRPM", perpEngine.shiftdownrpm, TEST.engine.shiftDownRPM)
	setValue(engineParams, "axleRatio", perpEngine.axleratio)
	-- PERP's scripts are manual (autotransmission 0): Source keeps one ratio up to top speed.
	-- The test script is automatic, and its box sat in top gear (slow) until the revs passed
	-- maxRPM, then dropped into 1st and rocketed: the Veyron crawled to 70 mph, then flew
	if perpEngine.autotransmission ~= nil then setValue(engineParams, "isAutoTransmission", perpEngine.autotransmission ~= 0) end
	if engineParams and istable(engineParams.gearRatio) and perpEngine.gears and #perpEngine.gears > 0 then
		engineParams.gearRatio = table.Copy(perpEngine.gears)
		setValue(engineParams, "gearCount", #perpEngine.gears)
	end

	scaleByRatio(bodyParams, "massOverride", perpBody.massoverride, TEST.body.massOverride)
	scaleByRatio(bodyParams, "maxAngularVelocity", perpBody.maxangularvelocity, TEST.body.maxAngularVelocity)
	setValue(bodyParams, "addGravity", perpBody.addgravity)
	setValue(bodyParams, "counterTorqueFactor", perpBody.countertorquefactor)
	if bodyParams and isvector(bodyParams.massCenterOverride) and perpBody.masscenter and bodyParams.massCenterOverride.z ~= 0 then
		-- the test script's centre is (0, 0, -5): that tells the unit
		local centreScale = bodyParams.massCenterOverride.z / TEST.body.massCenterZ
		bodyParams.massCenterOverride = Vector(perpBody.masscenter[1] * centreScale, perpBody.masscenter[2] * centreScale, perpBody.masscenter[3] * centreScale)
	end

	scaleByRatio(steeringParams, "degreesSlow", perpSteering.degreesslow, TEST.steering.degreesSlow)
	scaleByRatio(steeringParams, "degreesFast", perpSteering.degreesfast, TEST.steering.degreesFast)
	scaleByRatio(steeringParams, "degreesBoost", perpSteering.degreesboost, TEST.steering.degreesBoost)
	scaleByRatio(steeringParams, "powerSlideAccel", perpSteering.powerslideaccel, TEST.steering.powerSlideAccel)
	setValue(steeringParams, "turnThrottleReduceSlow", perpSteering.turnthrottlereduceslow)
	setValue(steeringParams, "turnThrottleReduceFast", perpSteering.turnthrottlereducefast)

	for axleIndex, axle in ipairs(params.axles or {}) do
		local perpAxle, testAxle = perpPhysics.axles and perpPhysics.axles[axleIndex], TEST.axles[axleIndex]
		if perpAxle and testAxle then
			scaleByRatio(axle, "suspension_springConstant", perpAxle.springconstant, testAxle.suspension_springConstant)
			scaleByRatio(axle, "suspension_springDamping", perpAxle.springdamping, testAxle.suspension_springDamping)
			scaleByRatio(axle, "suspension_springDampingCompression", perpAxle.springdampingcompression, testAxle.suspension_springDampingCompression)
			scaleByRatio(axle, "suspension_stabilizerConstant", perpAxle.stabilizerconstant, testAxle.suspension_stabilizerConstant)
			scaleByRatio(axle, "suspension_maxBodyForce", perpAxle.maxbodyforce, testAxle.suspension_maxBodyForce)
			scaleByRatio(axle, "wheels_mass", perpAxle.mass, testAxle.wheels_mass)
			setValue(axle, "torqueFactor", perpAxle.torquefactor)
			setValue(axle, "brakeFactor", perpAxle.brakefactor)
		end
	end
end

---------------------------------------------------------------------------
-- on spawn
---------------------------------------------------------------------------
local Handling = AudioEngine.Handling

local driveModelConVar = Handling.driveModelConVar   -- audio_engine_drivemodel (sh_handling.lua)

-- a collision that changed the car's velocity a lot: the model lets go while the crash plays out
local function onCollide(vehicle, data)
	if not data.HitNormal or math.abs(data.HitNormal.z) > 0.7 then return end   -- landing, bottoming out
	-- any touch from the side (a wall, a car): the model's obstructed check only runs then
	vehicle.audioContactAt = CurTime()
	if not (data.OurNewVelocity and data.OurOldVelocity) then return end
	local settings = vehicle.audioHandlingSpec and vehicle.audioHandlingSpec.settings or AudioEngine.HANDLING
	if (data.OurNewVelocity - data.OurOldVelocity):LengthSqr() < settings.impactSpeed * settings.impactSpeed then return end
	vehicle.audioImpactAt = CurTime()
end

-- whether the handling model runs on this car (with audio_engine_drivemodel on)
local function modelAllowed(vehicle, carConfig)
	return not vehicle.audioSpiked and not (carConfig and carConfig.stability == false)
end

--[[
	Source's steering under the model. The model owns the rotation and sideways grip, but Source
	still steers its front wheels and still runs the scripts' throttle cut while steering, and
	both slowed every car in a turn:
	  * turnThrottleReduceSlow/Fast (PERP: up to 0.9 at speed) cut the throttle while a key is held,
	    so a car couldn't pull through a corner. Off: the throttle is the driver's.
	  * Source turns the wheels to degreesFast (PERP: ~11) at speed, where the model's grip-capped turn
	    is only a few degrees (25 m/s: ~3): the front tyres stood across the car's path and scrubbed
	    it down like a brake. degreesFast becomes the model's angle at the script's FastCarSpeed
	    (35 mph on nearly every PERP script), where Source's line from degreesSlow (at a standstill)
	    reaches it and stays. Fitted at 25 m/s instead (~3 deg), Source held 3 deg from 35 mph on
	    where the model asks ~7: its front tyres pushed the car straight, and with the throttle on
	    (no cut any more) cars hardly turned at 35-55 mph. Fitted here, Source's wheels never point
	    less than the model's turn; over FastCarSpeed a little more (7 vs 3 deg at 25 m/s, PERP 11).
	    degreesSlow (parking) is kept.
	Changes `params` (GetVehicleParams layout) and returns true if the model runs on this car.
]]
local STEER_FIT_MPH = 35   -- FastCarSpeed when a script has none (params: mph, as Source compares it)
-- Source's wheels point this much past the model's turn (x share + degrees): never less than it
local STEER_MATCH_SHARE, STEER_MATCH_EXTRA = 1.1, 0.5

local function steerForModel(vehicle, params)
	local carConfig = AudioEngine.GetCarConfig(vehicle)
	if not (driveModelConVar:GetBool() and carConfig and modelAllowed(vehicle, carConfig)) then return false end
	local steering = params.steering
	if not istable(steering) then return false end
	setValue(steering, "turnThrottleReduceSlow", 0)
	setValue(steering, "turnThrottleReduceFast", 0)
	-- Source's wheels turn as the model's steering does (its rates are -1..1 a second): at a
	-- script's own (~2-3, x2 with throttle on the way back) they were still turned ~0.3 s after the
	-- key was let go and kept rotating the car between ticks, which the client's replay can't know:
	-- the drawn car turned too little holding a key and snapped round on letting go (the user;
	-- the 24th's log: the server's car kept turning ~0.2 s longer than predicted)
	local settings = Handling.SettingsFor(carConfig.name)
	setValue(steering, "steeringRateSlow", settings.steerRate)
	setValue(steering, "steeringRateFast", settings.steerRate)
	setValue(steering, "steeringRestRateSlow", settings.steerReturn)
	setValue(steering, "steeringRestRateFast", settings.steerReturn)
	setValue(steering, "brakeSteeringRateFactor", 1)
	setValue(steering, "throttleSteeringRestRateFactor", 1)
	setValue(steering, "boostSteeringRateFactor", 1)
	setValue(steering, "boostSteeringRestRateFactor", 1)
	if steering.degreesFast then
		local spec = Handling.SpecFor(vehicle)
		-- (the model's turn there, a touch more as over it (matchSteering); at most the script's lock.
		-- It was at most the script's DegreesFast: with corner grip the model asks more at 35 mph than
		-- some scripts give, and Source's front tyres pushed those cars straight)
		local fitMph = (steering.speedFast or 0) > 0 and steering.speedFast or STEER_FIT_MPH
		local wanted = Handling.TurnAngle(spec.settings, spec.wheelbase, fitMph * MPH_TO_METRES) * STEER_MATCH_SHARE + STEER_MATCH_EXTRA
		steering.degreesFast = math.min(steering.degreesSlow or wanted, wanted)
	end
	return true
end

function AudioEngine.PrepareHandling(vehicle)
	if vehicle.audioPrepared then return end
	vehicle.audioPrepared = true
	local carConfig = AudioEngine.GetCarConfig(vehicle)
	if not carConfig then return end
	local script = AudioEngine.VehicleScriptOf(vehicle)
	vehicle.audioScript = script
	vehicle.audioSpiked = script ~= nil and script:find("/spiked/", 1, true) ~= nil
	vehicle:AddCallback("PhysicsCollide", onCollide)

	local succeeded, params = pcall(vehicle.GetVehicleParams, vehicle)
	if not succeeded or not istable(params) or not istable(params.engine) then return end
	-- the script the spawn entry asked for (a job variant's own), else the car's base script
	local wantedScript = istable(vehicle.VehicleTable) and vehicle.VehicleTable.AudioPerpScript or carConfig.script
	local perpPhysics = wantedScript and AudioEngine.PERP_PHYSICS and (AudioEngine.PERP_PHYSICS[wantedScript] or AudioEngine.PERP_PHYSICS[carConfig.script])
	if perpPhysics and script == AudioEngine.TEST_SCRIPT and not vehicle.audioSpiked then
		applyPerpPhysics(params, perpPhysics)
		vehicle.audioPerpPhysics = true
		AudioEngine.SetParams(vehicle, params)
		-- the chassis mass, in case the params don't move the physics object
		local physics = vehicle:GetPhysicsObject()
		if IsValid(physics) and perpPhysics.body and perpPhysics.body.massoverride then physics:SetMass(perpPhysics.body.massoverride) end
	end
	-- the car's script handling: AudioEngine.RebaseHandling starts from it
	vehicle.audioScriptParams = table.Copy(params)
	if steerForModel(vehicle, params) then AudioEngine.SetParams(vehicle, params) end
end

--[[
	Rebuild the car's base params (what sv_engine's AudioEngine.ApplyPerformance starts from) from its
	script handling (vehicle.audioScriptParams, or `scriptParams` to replace it, e.g. edited live by the
	debug module), refresh what the clients know of it and re-apply the tuning.
]]
function AudioEngine.RebaseHandling(vehicle, scriptParams)
	if scriptParams then vehicle.audioScriptParams = table.Copy(scriptParams) end
	local savedParams = vehicle.audioScriptParams
	if not savedParams then return false end
	local params = table.Copy(savedParams)
	steerForModel(vehicle, params)
	vehicle.audioBase = params
	if AudioEngine.RefreshCarStats then AudioEngine.RefreshCarStats(vehicle, params) end
	if AudioEngine.ApplyPerformance then AudioEngine.ApplyPerformance(vehicle, AudioEngine.DecodeProfile(vehicle:GetNW2String("audio_prof", ""))) end
	return true
end

-- the model switched on or off: Source's steering goes back to the scripts' own, or the model's
cvars.AddChangeCallback("audio_engine_drivemodel", function()
	for vehicle in pairs(AudioEngine.TrackedVehicles or {}) do
		if IsValid(vehicle) and vehicle.audioScriptParams then AudioEngine.RebaseHandling(vehicle) end
	end
end, "audio_engine_handling")

---------------------------------------------------------------------------
-- every tick: the model on the driven cars
---------------------------------------------------------------------------
-- the driver's keys as Source has them (the newest command)
local function keyDown(player, key) return player:KeyDown(key) end

-- how much of the car is on its wheels: 0 (in the air, or 1 wheel) .. 1 (3 of 4 or more)
local function groundShareOf(vehicle)
	if vehicle.GetWheelContactPoint then
		local wheelCount = vehicle.GetWheelCount and vehicle:GetWheelCount() or 4
		if wheelCount and wheelCount > 0 then
			local contacts = 0
			for wheel = 0, wheelCount - 1 do
				local _, _, inContact = vehicle:GetWheelContactPoint(wheel)
				if inContact then contacts = contacts + 1 end
			end
			return Handling.Clamp((contacts / wheelCount - 0.25) / 0.5, 0, 1)
		end
	end
	-- (no wheel contacts: a short trace down from its floor)
	local upDirection = vehicle:GetUp()
	local start = vehicle:GetPos() + upDirection * 12
	local trace = util.TraceLine({ start = start, endpos = start - upDirection * 40, filter = vehicle, mask = MASK_SOLID })
	return trace.Hit and 1 or 0
end

-- 1 normally; 0 right after a crash, easing back
local function impactShareOf(vehicle, settings, now)
	local impactAt = vehicle.audioImpactAt
	if not impactAt then return 1 end
	local share = (now - impactAt - settings.impactHold) / settings.impactEase
	if share >= 1 then vehicle.audioImpactAt = nil return 1 end
	return math.max(0, share)
end

--[[
	Source's front wheels over FastCarSpeed, matched to the model's turn. Source steers them on a
	straight line from DegreesSlow at SlowCarSpeed to DegreesFast at FastCarSpeed (both mph: Source
	compares them with the car's speed in mph) and holds DegreesFast over it. DegreesFast is fitted to
	the model at FastCarSpeed (steerForModel), but the model's grip-capped turn keeps shrinking with
	speed (~1.2 deg at 112 mph): the front tyres stood ~7 deg across the car's path and braked fast
	cars in a turn (the user, after downforce: "slows down too much when turning").
	So over FastCarSpeed the car's params get DegreesFast = the model's angle at its speed
	(x STEER_MATCH_SHARE + STEER_MATCH_EXTRA: never less than the model, as the fit; at most
	DegreesSlow) and FastCarSpeed = that speed: Source's line then reaches that angle
	there and holds it. DegreesSlow and everything under FastCarSpeed stay the script's own.
	Re-sent (ApplyPerformance, the whole params: AudioEngine.SetParams puts vehicle.audioSteerOverride
	on them) every STEER_MATCH_STEP_MPH / STEER_MATCH_STEP_DEGREES; back under FastCarSpeed (with
	STEER_MATCH_HYSTERESIS_MPH), getting out or the model off: the plain params again.
	(SetSteeringDegrees, tried first, sets DegreesSlow too: Source draws the wheels' turn as a share of
	DegreesSlow, so they showed full lock at any speed, and read as in/s the line was wrong everywhere.)
]]
local STEER_MATCH_STEP_MPH, STEER_MATCH_STEP_DEGREES, STEER_MATCH_HYSTERESIS_MPH = 2, 0.2, 1

-- the steering override for a car at `mph` ({ degreesFast, speedFast } or nil = its own line):
-- `steering` = its base params' steering (fitted), `spec` = Handling.SpecFor
function AudioEngine.MatchedSteering(steering, spec, mph)
	local fastSpeed = steering.speedFast or 0
	if fastSpeed <= 0 or not steering.degreesFast or mph <= fastSpeed then return nil end
	local angle = Handling.TurnAngle(spec.settings, spec.wheelbase, mph * MPH_TO_METRES) * STEER_MATCH_SHARE + STEER_MATCH_EXTRA
	return { degreesFast = math.min(steering.degreesSlow or angle, angle), speedFast = mph }
end

-- the wheel angle Source steers to at `mph` with full lock (its line: RemapValClamped)
function AudioEngine.SourceSteerAngle(steering, mph)
	local slow, fast = steering.degreesSlow or 0, steering.degreesFast or steering.degreesSlow or 0
	local speedSlow, speedFast = steering.speedSlow or 0, steering.speedFast or 0
	if speedFast <= speedSlow then return mph < speedSlow and slow or fast end
	local share = math.max(0, math.min(1, (mph - speedSlow) / (speedFast - speedSlow)))
	return slow + (fast - slow) * share
end

local function reapplyParams(vehicle)
	if AudioEngine.ApplyPerformance then
		AudioEngine.ApplyPerformance(vehicle, AudioEngine.DecodeProfile(vehicle:GetNW2String("audio_prof", "")))
	elseif vehicle.audioBase then
		AudioEngine.SetParams(vehicle, vehicle.audioBase)
	end
end

local function clearSteering(vehicle)
	if not vehicle.audioSteerOverride then return end
	vehicle.audioSteerOverride = nil
	reapplyParams(vehicle)
end

local function matchSteering(vehicle, spec, velocity, modelHere)
	local steering = vehicle.audioBase and vehicle.audioBase.steering
	if not modelHere or not istable(steering) then return clearSteering(vehicle) end
	local mph = velocity:Length() / HU_PER_MPH
	local current = vehicle.audioSteerOverride
	-- (hysteresis: on over FastCarSpeed + 1 mph, off under it)
	local wanted = AudioEngine.MatchedSteering(steering, spec, current and mph or mph - STEER_MATCH_HYSTERESIS_MPH)
	if wanted and not current then wanted.speedFast = mph end
	if not wanted then return clearSteering(vehicle) end
	if current and math.abs(current.speedFast - wanted.speedFast) < STEER_MATCH_STEP_MPH
		and math.abs(current.degreesFast - wanted.degreesFast) < STEER_MATCH_STEP_DEGREES then return end
	vehicle.audioSteerOverride = wanted
	reapplyParams(vehicle)
end

hook.Add("PlayerLeaveVehicle", "audio_engine_handling_steer", function(_, vehicle)
	if IsValid(vehicle) then clearSteering(vehicle) end
end)

local function drive(vehicle, driver, buttons, modelHere, deltaTime, now)
	local physics = vehicle:GetPhysicsObject()
	if not IsValid(physics) or not physics:IsMotionEnabled() then return end
	-- the model's numbers for this car (its shape is read once; settings read through)
	local spec = vehicle.audioHandlingSpec
	if not spec or vehicle.audioHandlingModel ~= vehicle:GetModel() then
		spec = Handling.SpecFor(vehicle)
		vehicle.audioHandlingSpec, vehicle.audioHandlingModel = spec, vehicle:GetModel()
	end
	-- the steering state starts again with each driver
	local state = vehicle.audioHandlingState
	if not state or vehicle.audioHandlingDriver ~= driver then
		state = { steer = 0, drift = false }
		vehicle.audioHandlingState, vehicle.audioHandlingDriver = state, driver
	end

	local body = vehicle.audioHandlingBody or {}
	vehicle.audioHandlingBody = body
	local position, velocity = vehicle:GetPos(), physics:GetVelocity()
	body.px, body.py, body.pz = position.x, position.y, position.z
	body.vx, body.vy, body.vz = velocity.x, velocity.y, velocity.z
	Handling.SetAxes(body, vehicle:GetAngles())
	body.yawRate = physics:GetAngleVelocity().z     -- local, deg/s: the car's up
	body.groundShare = groundShareOf(vehicle)
	local contactAt = vehicle.audioContactAt
	body.touching = contactAt ~= nil and now - contactAt < spec.settings.contactHold
	local impactShare = impactShareOf(vehicle, spec.settings, now)
	body.controlShare = modelHere and impactShare or 0

	matchSteering(vehicle, spec, velocity, modelHere)
	local yawChange, sideChange, asked, forwardChange = Handling.Control(body, state, buttons, spec, deltaTime)
	forwardChange = forwardChange or 0
	if yawChange ~= 0 then physics:AddAngleVelocity(Vector(0, 0, yawChange)) end
	if sideChange ~= 0 or forwardChange ~= 0 then
		local noseX, noseY, noseZ, rightX, rightY, rightZ = Handling.NoseOf(body, spec)
		physics:AddVelocity(Vector(rightX * sideChange + noseX * forwardChange, rightY * sideChange + noseY * forwardChange,
			rightZ * sideChange + noseZ * forwardChange))
	end
	vehicle.audioLogAsked = asked
end

hook.Add("Tick", "audio_engine_handling", function()
	local deltaTime = engine.TickInterval()
	local modelOn, now = driveModelConVar:GetBool(), CurTime()
	for vehicle in pairs(AudioEngine.TrackedVehicles or {}) do
		if IsValid(vehicle) then
			local driver = vehicle:GetDriver()
			if IsValid(driver) then
				-- (carConfig.stability = false: a car registered without the model)
				local modelHere = modelOn and modelAllowed(vehicle, AudioEngine.GetCarConfig(vehicle))
				drive(vehicle, driver, Handling.ButtonsFrom(keyDown, driver), modelHere, deltaTime, now)
			end
		end
	end
end)

---------------------------------------------------------------------------
-- logs (admins)
---------------------------------------------------------------------------
-- audio_engine_accel_log [seconds]: the car you drive, 4x a second: Source's own gear and rpm
-- (GetOperatingParams), speed, the model's steering and rotation asked vs what the car does
concommand.Add("audio_engine_accel_log", function(player, _, args)
	if IsValid(player) and not player:IsAdmin() then return end
	local vehicle = IsValid(player) and player:GetVehicle()
	if not IsValid(vehicle) then return end
	local seconds = math.Clamp(tonumber(args[1]) or 12, 1, 60)
	local startTime = CurTime()
	local function printLine(line) if IsValid(player) then player:PrintMessage(HUD_PRINTCONSOLE, line) end end
	printLine("[Audio Engine] accel log: t | mph | Source gear, rpm | steer | yaw asked, yaw deg/s | slip angle deg | ground, control")
	local timerId = "audio_engine_accel_log_" .. vehicle:EntIndex()
	-- calibration for the acceleration model (sh_presets.lua AudioEngine.GEAR_ACCEL): the time to each share of the
	-- top speed, next to the model's. Start from a standstill and hold W on a straight road
	local topKmh = AudioEngine.CarTopSpeed(vehicle, AudioEngine.GetCarConfig(vehicle))
	local powerToWeight = AudioEngine.CarPower(vehicle, AudioEngine.GetCarConfig(vehicle)) * ((AudioEngine.DecodeProfile(vehicle:GetNW2String("audio_prof", "")) or {}).accel or 1)
	local marks, reached, setOffTime = { 0.25, 0.5, 0.75, 0.9, 0.95 }, {}, nil
	local function report()
		local parts = {}
		for _, mark in ipairs(marks) do
			parts[#parts + 1] = string.format("%d%% %s (model %.1f)", mark * 100,
				reached[mark] and string.format("%.1fs", reached[mark]) or "-", AudioEngine.GearModelTime(topKmh, powerToWeight, mark))
		end
		printLine(string.format("[Audio Engine] top %.0f mph, %.0f W/kg: time to share of top speed: %s",
			topKmh / 1.609344, powerToWeight, table.concat(parts, ", ")))
	end
	local ticks = math.floor(seconds * 4)
	timer.Create(timerId, 0.25, ticks, function()
		if not IsValid(vehicle) then timer.Remove(timerId) return end
		local physics = vehicle:GetPhysicsObject()
		local mph = IsValid(physics) and physics:GetVelocity():Length() * 0.0254 * 2.23694 or 0
		if not setOffTime and mph > 0.5 then setOffTime = CurTime() - 0.125 end   -- (it set off within the last sample)
		if setOffTime then
			for _, mark in ipairs(marks) do
				if not reached[mark] and mph * 1.609344 >= topKmh * mark then reached[mark] = CurTime() - setOffTime end
			end
		end
		ticks = ticks - 1
		if ticks <= 0 or reached[0.95] then timer.Remove(timerId) report() end
		local gotParams, operatingParams = pcall(vehicle.GetOperatingParams, vehicle)
		operatingParams = gotParams and istable(operatingParams) and operatingParams or {}
		local body, spec, state = vehicle.audioHandlingBody, vehicle.audioHandlingSpec, vehicle.audioHandlingState
		local slipAngle = 0
		if body and spec then
			local noseX, noseY, noseZ, rightX, rightY, rightZ = Handling.NoseOf(body, spec)
			local forwardSpeed = body.vx * noseX + body.vy * noseY + body.vz * noseZ
			local sideSpeed = body.vx * rightX + body.vy * rightY + body.vz * rightZ
			if forwardSpeed * forwardSpeed + sideSpeed * sideSpeed > 400 then slipAngle = math.deg(math.atan2(sideSpeed, math.abs(forwardSpeed))) end
		end
		printLine(string.format("  %5.2fs | %5.1f | G%s %5.0f | %5.2f | %6.1f %6.1f | %5.1f | %.2f %.2f", CurTime() - startTime, mph,
			tostring(operatingParams.gear or "?"), operatingParams.RPM or 0, state and state.steer or 0, vehicle.audioLogAsked or 0,
			body and body.yawRate or 0, slipAngle, body and body.groundShare or 0, body and body.controlShare or 0))
	end)
end, nil, "Log speed, Source gear/rpm, steering and rotation of the car you drive (admins)")

-- what the car you look at got: audio_engine_handling_info
concommand.Add("audio_engine_handling_info", function(player)
	if IsValid(player) and not player:IsAdmin() then return end
	local vehicle = IsValid(player) and player:GetVehicle()
	if IsValid(player) and not IsValid(vehicle) then vehicle = player:GetEyeTrace().Entity end
	local function printLine(line) if IsValid(player) then player:PrintMessage(HUD_PRINTCONSOLE, line) else print(line) end end
	if not IsValid(vehicle) or not vehicle:IsVehicle() then printLine("[Audio Engine] look at or sit in a car") return end
	local carConfig = AudioEngine.GetCarConfig(vehicle)
	local spec = Handling.SpecFor(vehicle)
	local succeeded, params = pcall(vehicle.GetVehicleParams, vehicle)
	printLine(string.format("[Audio Engine] %s | script %s | PERP physics %s | spiked %s | handling model %s",
		carConfig and carConfig.name or vehicle:GetModel(), tostring(vehicle.audioScript), tostring(vehicle.audioPerpPhysics or false),
		tostring(vehicle.audioSpiked or false), tostring(driveModelConVar:GetBool() and not vehicle.audioSpiked)))
	printLine(string.format("  model: grip %.2f g, wheelbase %.2f m, lock %.0f..%.0f deg, yaw follow %.1f/s",
		spec.settings.grip, spec.wheelbase, spec.settings.lockSlow, spec.settings.lockFast, spec.settings.yawFollow))
	if succeeded and istable(params) and params.engine then
		local frontAxle, rearAxle = params.axles and params.axles[1] or {}, params.axles and params.axles[2] or {}
		local physics = vehicle:GetPhysicsObject()
		printLine(string.format("  %.0f hp, top %.0f mph, mass %.0f kg, brakes %.2f/%.2f, torque %.2f/%.2f, gravity x%.2f, centre %s",
			params.engine.horsepower or 0, (params.engine.maxSpeed or 0) / HU_PER_MPH, IsValid(physics) and physics:GetMass() or 0,
			frontAxle.brakeFactor or 0, rearAxle.brakeFactor or 0, frontAxle.torqueFactor or 0, rearAxle.torqueFactor or 0,
			params.body and params.body.addGravity or 0, tostring(params.body and params.body.massCenterOverride)))
	end
end, nil, "Print the handling setup of the car you're in or looking at (admins)")
