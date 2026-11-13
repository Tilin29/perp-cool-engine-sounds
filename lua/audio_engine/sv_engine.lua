--[[
	Audio Engine - server side
	Switches the engine on/off as drivers get in and out, and networks the driver's
	throttle/brake/handbrake keys so every client can run the rpm model and sound.
]]

local AudioEngine = AUDIO_ENGINE

-- not archived: an old saved "0" (the default before) kept switching engines off; set it in server.cfg to change it
local keepRunningConVar = CreateConVar("audio_engine_keeprunning", "1", FCVAR_NONE,
	"1 = cars keep idling after the driver gets out (the driver switches them off); 0 = getting out switches the engine off")
local emotionStartConVar = CreateConVar("audio_engine_emotionstart", "1", FCVAR_ARCHIVE,
	"1 = rev flare on start-up (Rev Bench 'emotion start')")
local autoStartConVar = CreateConVar("audio_engine_autostart", "0", FCVAR_ARCHIVE + FCVAR_REPLICATED,
	"1 = the engine starts by itself when a driver gets in; 0 = the driver starts it (start key or audio_engine_toggle)")

local trackedVehicles = {}
AudioEngine.TrackedVehicles = trackedVehicles

local function isOurs(entity)
	return IsValid(entity) and entity:IsVehicle() and AudioEngine.GetCarConfig(entity) ~= nil
end

---------------------------------------------------------------------------
-- real performance: the profile's acceleration and top speed are applied to the car's
-- physics (Source vehicle params), starting from what its own vehicle script set up
---------------------------------------------------------------------------
local HU_PER_MPH = AudioEngine.HU_PER_MPH   -- GetVehicleParams speeds are inches/s (sv_handling.lua: AudioEngine.SetParams)

-- what the clients need of the car's physics (params as GetVehicleParams gives them)
function AudioEngine.RefreshCarStats(vehicle, params)
	-- the car's own top speed, for "fit gearing" and the menu
	if (params.engine.maxSpeed or 0) > 0 then
		vehicle:SetNW2Float("audio_vmax", params.engine.maxSpeed / HU_PER_MPH * 1.609344)
	end
	-- its power to weight (W/kg), for audio_engine_accel_log's model (sh_presets.lua AudioEngine.GearAccel)
	local physics = vehicle:GetPhysicsObject()
	local mass = IsValid(physics) and physics:GetMass() or 0
	if (params.engine.horsepower or 0) > 0 and mass > 0 then
		vehicle:SetNW2Float("audio_pwr", params.engine.horsepower * 745.7 / mass)
	end
end

local function captureBase(vehicle)
	if vehicle.audioBase then return vehicle.audioBase end
	local succeeded, params = pcall(vehicle.GetVehicleParams, vehicle)
	if not succeeded or not istable(params) or not istable(params.engine) then return nil end
	vehicle.audioBase = table.Copy(params)
	AudioEngine.RefreshCarStats(vehicle, params)
	return vehicle.audioBase
end

function AudioEngine.ApplyPerformance(vehicle, profile)
	local base = captureBase(vehicle)
	if not base then return end
	local accelerationScale = profile and profile.accel or 1
	local topSpeedOverride = profile and profile.vmax or 0
	local adjusted = table.Copy(base)
	-- audioLimiterPower: cruise control's power trim (sv_cruise.lua, sv_handling.lua)
	-- audioTractionPower: launch traction control's power trim; audioSteerLockScale: the lock at speed (sv_handling.lua)
	adjusted.engine.horsepower = base.engine.horsepower * accelerationScale * (vehicle.audioTractionPower or 1) * (vehicle.audioLimiterPower or 1)
	if adjusted.steering and adjusted.steering.degreesFast and vehicle.audioSteerLockScale then
		adjusted.steering.degreesFast = base.steering.degreesFast * vehicle.audioSteerLockScale
	end
	if topSpeedOverride > 0 then adjusted.engine.maxSpeed = topSpeedOverride / 1.609344 * HU_PER_MPH end
	AudioEngine.SetParams(vehicle, adjusted)
end

local function track(entity)
	if not isOurs(entity) then return end
	trackedVehicles[entity] = true
	-- PERP physics on the test script and the anti-spin setup (sv_handling.lua), before the
	-- car's physics are captured as the base the tuning menu works from
	AudioEngine.PrepareHandling(entity)
	captureBase(entity)
	-- after a lua refresh, a car that is already running stays drivable
	if entity.audioDrivable == nil then entity.audioDrivable = entity:GetNW2Bool("audio_on", false) end
	local profile = AudioEngine.DecodeProfile(entity:GetNW2String("audio_prof", ""))
	if profile then AudioEngine.ApplyPerformance(entity, profile) end
end

hook.Add("OnEntityCreated", "audio_engine", function(entity)
	timer.Simple(0, function() track(entity) end)
end)

--[[
	Ignition. With the engine off the car is silent and can't drive. Switching it on runs the
	start-up sequence (crank, catch, rev flare, settle to idle); the car only drives once that
	has finished. The server runs the same start-up model as the clients (sh_drivetrain.lua),
	so the car is released exactly when the sound reaches idle.
]]
local Drivetrain = AudioEngine.Drivetrain

-- whether Source may drive the car: engine on and the start-up sequence finished
local function setDrivable(vehicle, drivable)
	vehicle.audioDrivable = drivable
	if vehicle.EnableEngine then pcall(vehicle.EnableEngine, vehicle, drivable) end
	if vehicle.StartEngine then pcall(vehicle.StartEngine, vehicle, drivable) end
end

-- rev flare on start-up: only cars listed as high-powered (sh_carlist.lua CAR_EMOTION)
local function wantsEmotion(vehicle)
	local carConfig = AudioEngine.GetCarConfig(vehicle)
	return emotionStartConVar:GetBool() and carConfig ~= nil and carConfig.emotionStart == true
end

local function setEngine(vehicle, turnOn, instant)
	vehicle:SetNW2Bool("audio_on", turnOn)
	if turnOn then
		local emotion = wantsEmotion(vehicle)
		vehicle:SetNW2Float("audio_on_t", CurTime())
		vehicle:SetNW2Bool("audio_emo", emotion)
		if instant then
			vehicle.audioStart = nil
			setDrivable(vehicle, true)
		else
			local startState = Drivetrain.New()
			Drivetrain.Start(startState, emotion)
			vehicle.audioStart = startState
			setDrivable(vehicle, false)
		end
	else
		vehicle.audioStart = nil
		setDrivable(vehicle, false)
	end
end
AudioEngine.SetEngine = setEngine

function AudioEngine.ToggleEngine(vehicle)
	setEngine(vehicle, not vehicle:GetNW2Bool("audio_on", false))
end

hook.Add("PlayerEnteredVehicle", "audio_engine", function(player, vehicle)
	if not isOurs(vehicle) then return end
	trackedVehicles[vehicle] = true
	local running = vehicle:GetNW2Bool("audio_on", false)
	if running then
		-- still idling (audio_engine_keeprunning): drive off straight away, unless it's mid start-up
		setDrivable(vehicle, vehicle.audioStart == nil)
	elseif autoStartConVar:GetBool() then
		setEngine(vehicle, true)
	else
		setDrivable(vehicle, false)
	end
	-- Source starts the engine as you get in; switch it back off after that has happened
	timer.Simple(0, function()
		if IsValid(vehicle) then setDrivable(vehicle, vehicle.audioDrivable and true or false) end
	end)
end)

hook.Add("PlayerLeaveVehicle", "audio_engine", function(player, vehicle)
	if not trackedVehicles[vehicle] then return end
	if not keepRunningConVar:GetBool() then setEngine(vehicle, false) end
end)

-- the start key (audio_engine_startkey, read by cl_engine.lua) sends this too;
-- bindable: `bind <key> audio_engine_toggle`
-- Nothing is heard until the server's answer is back, so a second press can come in right after
-- the first: for START_LOCK s it doesn't count, or it would switch the engine straight off again
local START_LOCK = 1.5
concommand.Add("audio_engine_toggle", function(player)
	if not IsValid(player) then return end
	local vehicle = player:GetVehicle()
	if not IsValid(vehicle) or not trackedVehicles[vehicle] or vehicle:GetDriver() ~= player then return end
	if (player.audioToggleAllowedAt or 0) > CurTime() then return end
	player.audioToggleAllowedAt = CurTime() + 0.4
	if vehicle:GetNW2Bool("audio_on", false) and CurTime() - vehicle:GetNW2Float("audio_on_t", 0) < START_LOCK then return end
	AudioEngine.ToggleEngine(vehicle)
end, nil, "Switch the engine of the car you're driving on or off")

hook.Add("Think", "audio_engine", function()
	for vehicle in pairs(trackedVehicles) do
		if not IsValid(vehicle) then
			trackedVehicles[vehicle] = nil
		else
			local driver = vehicle:GetDriver()
			local inputBits = 0
			if IsValid(driver) then
				if driver:KeyDown(IN_FORWARD) then inputBits = inputBits + 1 end
				if driver:KeyDown(IN_BACK) then inputBits = inputBits + 2 end
				if driver:KeyDown(IN_JUMP) then inputBits = inputBits + 4 end
				if driver:KeyDown(IN_MOVELEFT) ~= driver:KeyDown(IN_MOVERIGHT) then inputBits = inputBits + 8 end   -- steering
			end
			if inputBits ~= vehicle.audioInputBits then
				vehicle.audioInputBits = inputBits
				vehicle:SetNW2Int("audio_in", inputBits)
			end
			-- start-up in progress: release the car once it has settled to idle
			local startState = vehicle.audioStart
			if startState then
				local config = AudioEngine.GetEngineConfig(vehicle)
				if config then
					Drivetrain.StartSequence(startState, config, FrameTime())
					if startState.phase == "run" then
						vehicle.audioStart = nil
						setDrivable(vehicle, vehicle:GetNW2Bool("audio_on", false))
					end
				end
			end
			-- keep Source from driving a car whose engine is off or still starting
			if IsValid(driver) and vehicle.IsEngineEnabled then
				local wantEnabled = vehicle.audioDrivable and true or false
				local succeeded, engineEnabled = pcall(vehicle.IsEngineEnabled, vehicle)
				if succeeded and engineEnabled ~= wantEnabled then setDrivable(vehicle, wantEnabled) end
			end
		end
	end
end)

-- lua refresh
for _, entity in ipairs(ents.GetAll()) do track(entity) end

---------------------------------------------------------------------------
-- engine tuning (the in-game Rev Bench menu)
---------------------------------------------------------------------------
util.AddNetworkString("audio_engine_set")

local tuneAccessConVar = CreateConVar("audio_engine_tuneaccess", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED,
	"Who can retune car engines: 0 = whoever is driving, 1 = admins, 2 = superadmins")
local tuneCooldownConVar = CreateConVar("audio_engine_tunecooldown", "5", FCVAR_ARCHIVE,
	"Seconds between engine changes per player (each change makes nearby clients generate sounds)")

function AudioEngine.CanTune(player, vehicle)
	local access = tuneAccessConVar:GetInt()
	if access >= 2 then return player:IsSuperAdmin() end
	if access == 1 then return player:IsAdmin() end
	return player:GetVehicle() == vehicle
end

net.Receive("audio_engine_set", function(_, player)
	local vehicle = net.ReadEntity()
	local profileString = net.ReadString()
	if not IsValid(vehicle) or not trackedVehicles[vehicle] then return end
	if not AudioEngine.EditorEnabled() then
		player:ChatPrint("[Audio Engine] The engine editor is off on this server (audio_engine_editor 0).")
		return
	end
	if not AudioEngine.CanTune(player, vehicle) then
		player:ChatPrint("[Audio Engine] You're not allowed to retune engines.")
		return
	end
	-- must be in the car or standing next to it
	if player:GetVehicle() ~= vehicle and player:GetPos():DistToSqr(vehicle:GetPos()) > 400 * 400 then return end
	local now = CurTime()
	if (player.audioTuneAllowedAt or 0) > now then
		player:ChatPrint(string.format("[Audio Engine] Wait %.0f s before changing the engine again.", player.audioTuneAllowedAt - now))
		return
	end
	player.audioTuneAllowedAt = now + tuneCooldownConVar:GetFloat()

	if profileString == "" then
		vehicle:SetNW2String("audio_prof", "")      -- back to stock
		AudioEngine.ApplyPerformance(vehicle, nil)
		return
	end
	local profile = AudioEngine.DecodeProfile(profileString)
	if not profile then return end
	vehicle:SetNW2String("audio_prof", AudioEngine.EncodeProfile(profile))
	AudioEngine.ApplyPerformance(vehicle, profile)
end)

hook.Add("PlayerSay", "audio_engine", function(player, text)
	local message = string.lower(string.Trim(text))
	if (message == "!engine" or message == "/engine") and AudioEngine.EditorEnabled() then
		player:ConCommand("audio_engine_menu")
		return ""
	end
end)


--[[
	Wings and vents (AudioEngine.GAUGE_PARTS cars): their parts hang off the vehicle_guage pose, which
	Source sets from speed / the script's top speed in the driver's move (the Murcielago's vents
	opened from half its top speed, the R8 Plus folded its wing away near the top). That pose can't
	be held from here: on a real server Source's write and ours both reached the clients and the
	parts stuttered. So the server only picks the position, in steps so it's sent a few times a
	second at most, and cl_engine sets the pose right before the car is drawn, like the tach needle.
	Brake wings (AudioEngine.BRAKE_WINGS: P1, SLR) are moved here too, through bone manipulation.
]]
local function glide(current, target, maxUp, maxDown)
	return current + math.Clamp(target - current, -maxDown, maxUp)
end

local function toVector(values) return values and Vector(values[1], values[2], values[3]) or nil end
local function toAngle(values) return values and Angle(values[1], values[2], values[3]) or nil end

-- bone manipulations scaled by frac, re-sent only when frac moved enough to see (they're networked)
local function manipulateBone(vehicle, manipulationKey, boneName, fraction, position, angles)
	local boneId = vehicle:LookupBone(boneName)
	if not boneId then return end
	vehicle.audioSentBoneManipulations = vehicle.audioSentBoneManipulations or {}
	local sentFraction = vehicle.audioSentBoneManipulations[manipulationKey]
	if sentFraction and math.abs(fraction - sentFraction) < 0.01 and (fraction > 0 or sentFraction == 0) then return end
	vehicle.audioSentBoneManipulations[manipulationKey] = fraction
	if position then vehicle:ManipulateBonePosition(boneId, toVector(position) * fraction) end
	if angles then vehicle:ManipulateBoneAngles(boneId, toAngle(angles) * fraction) end
end

local function updateBrakeWing(vehicle, brakeWingConfig, speedKmh, topSpeed, deltaTime, braking)
	local wingUp = AudioEngine.WingSpeedUp(vehicle, speedKmh, topSpeed)
	vehicle.audioBrakeHeldTime = braking and (vehicle.audioBrakeHeldTime or 0) + deltaTime or 0
	local flapOn = vehicle.audioBrakeHeldTime >= AudioEngine.WING_BRAKE_HOLD or (vehicle.audioFlapShow or 0) > CurTime()   -- (wingflap preview)
	if brakeWingConfig.tuck then
		-- the wing rises out of its tucked place (speed rules, or the flap needs it up)
		local mainFraction = glide(vehicle.audioWingRaise or 0, (wingUp or flapOn) and 1 or 0, deltaTime * AudioEngine.WING_MAIN_RATE, deltaTime * AudioEngine.WING_MAIN_RATE)
		vehicle.audioWingRaise = mainFraction
		for i, tuck in ipairs(brakeWingConfig.tuck) do manipulateBone(vehicle, "tuck" .. i, tuck.bone, 1 - mainFraction, tuck.pos, tuck.ang) end
	end
	local flapFraction = glide(vehicle.audioFlapRaise or 0, flapOn and 1 or 0, deltaTime * AudioEngine.WING_FLAP_RATE, deltaTime * AudioEngine.WING_FLAP_RATE * 0.5)
	vehicle.audioFlapRaise = flapFraction
	if brakeWingConfig.flapPose then
		vehicle:SetPoseParameter(brakeWingConfig.flapPose, flapFraction)
	elseif brakeWingConfig.flapBone then
		manipulateBone(vehicle, "flap", brakeWingConfig.flapBone, flapFraction, nil, brakeWingConfig.flapAng)
	end
end

local WING_STEP = 0.02

hook.Add("Tick", "audio_engine_wings", function()
	local deltaTime = engine.TickInterval()
	for vehicle in pairs(trackedVehicles) do
		if IsValid(vehicle) then
			local carConfig = AudioEngine.GetCarConfig(vehicle)
			local gaugeParts, brakeWingConfig = carConfig and carConfig.gaugeParts, carConfig and carConfig.brakeWing
			local physics = (gaugeParts or brakeWingConfig) and vehicle:GetPhysicsObject()
			-- parked (physics asleep, no driver) with its wings settled: nothing moves until it's woken
			local asleep = physics and IsValid(physics) and physics:IsAsleep() and not IsValid(vehicle:GetDriver())
			if (gaugeParts or brakeWingConfig) and not (asleep and vehicle.audioWingsSettled) then
				local speedKmh = IsValid(physics) and physics:GetVelocity():Length() * 0.09144 or 0   -- in/s -> km/h
				local topSpeed = AudioEngine.CarTopSpeed(vehicle, carConfig)
				if gaugeParts then
					-- (set only when it moved: the NW2 setter compares too, but that's a call into the engine every tick)
					local pose = math.Round(AudioEngine.WingPose(vehicle, gaugeParts, speedKmh, topSpeed) / WING_STEP) * WING_STEP
					if pose ~= vehicle.audioWingSent then
						vehicle.audioWingSent = pose
						vehicle:SetNW2Float("audio_wing", pose)
					end
				end
				if brakeWingConfig then
					local driver = vehicle:GetDriver()
					local braking = IsValid(driver) and driver:KeyDown(IN_BACK) and not driver:KeyDown(IN_FORWARD)
						and speedKmh > AudioEngine.WING_BRAKE_MPH * 1.609344
					updateBrakeWing(vehicle, brakeWingConfig, speedKmh, topSpeed, deltaTime, braking)
				end
				vehicle.audioWingsSettled = asleep and (vehicle.audioFlapRaise or 0) == 0 and (vehicle.audioWingRaise or 0) == 0
					and (vehicle.audioFlapShow or 0) <= CurTime()
			end
		end
	end
end)

--[[
	Tuning wings in game (superadmin, or the host in single player), on the car you sit in or look at:
	  audio_engine_wingflap      shows the brake flap for 10 s
	  audio_engine_bonedump      the car's bone manipulations (e.g. from the sandbox bone editor),
	                             printed and written to data/audio_engine_bones.txt
	To place a tucked wing: park the car, move the bones with the bone editor, run bonedump and put
	the values into AudioEngine.BRAKE_WINGS (tuck = { bone, pos, ang }).
]]
local function tuneTarget(player)
	if IsValid(player) and not player:IsSuperAdmin() and not (game.SinglePlayer() or player:IsListenServerHost()) then return end
	if not IsValid(player) then return end
	local vehicle = player:GetVehicle()
	if not (IsValid(vehicle) and AudioEngine.GetCarConfig(vehicle)) then vehicle = player:GetEyeTrace().Entity end
	return IsValid(vehicle) and vehicle or nil
end

concommand.Add("audio_engine_wingflap", function(player)
	local vehicle = tuneTarget(player)
	local carConfig = vehicle and AudioEngine.GetCarConfig(vehicle)
	if not (carConfig and carConfig.brakeWing) then
		if IsValid(player) then player:PrintMessage(HUD_PRINTTALK, "[Audio Engine] sit in or look at a brake-wing car (P1, SLR)") end
		return
	end
	vehicle.audioFlapShow = CurTime() + 10
	vehicle.audioWingsSettled = false   -- (a parked car's wings are otherwise left alone)
end)

concommand.Add("audio_engine_bonedump", function(player)
	local vehicle = tuneTarget(player)
	if not vehicle then return end
	local carConfig = AudioEngine.GetCarConfig(vehicle)
	local lines = { string.format("%s  %s", carConfig and carConfig.name or vehicle:GetClass(), vehicle:GetModel()) }
	for boneId = 0, vehicle:GetBoneCount() - 1 do
		local positionOffset, angleOffset = vehicle:GetManipulateBonePosition(boneId), vehicle:GetManipulateBoneAngles(boneId)
		if not positionOffset:IsZero() or not angleOffset:IsZero() then
			lines[#lines + 1] = string.format('{ bone = "%s", pos = { %g, %g, %g }, ang = { %g, %g, %g } },', vehicle:GetBoneName(boneId),
				math.Round(positionOffset.x, 2), math.Round(positionOffset.y, 2), math.Round(positionOffset.z, 2),
				math.Round(angleOffset.p, 2), math.Round(angleOffset.y, 2), math.Round(angleOffset.r, 2))
		end
	end
	if #lines == 1 then lines[2] = "(no bone manipulations)" end
	file.Write("audio_engine_bones.txt", table.concat(lines, "\n") .. "\n")
	for _, line in ipairs(lines) do player:PrintMessage(HUD_PRINTCONSOLE, line .. "\n") end
	player:PrintMessage(HUD_PRINTTALK, "[Audio Engine] bones written to data/audio_engine_bones.txt")
end)
