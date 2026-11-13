--[[
	Audio Engine - rpm / gear model (shared, pure Lua)

	The car itself is driven by Source's vehicle physics. This model only decides what the
	engine is doing, from the car's real speed and the driver's keys: which gear an automatic
	box would be in, how far the torque converter lets it rev when pulling away, rev-matched
	downshifts, the rev limiter, and the start-up / shut-down sequence from Rev Bench.
	Its output (rpm, gear, sound throttle) feeds the sound and the HUD.
]]

AUDIO_ENGINE = AUDIO_ENGINE or {}
local Drivetrain = {}
AUDIO_ENGINE.Drivetrain = Drivetrain

local min, max, abs, cos, pi = math.min, math.max, math.abs, math.cos, math.pi
local function clamp(value, low, high) if value < low then return low elseif value > high then return high end return value end
Drivetrain.clamp = clamp

Drivetrain.TMAX = 320 -- Rev Bench reference torque (the baked limiter loops and start-ups: changing it needs a re-bake)

--[[
	Free-revving in neutral in game (the Space+W rev at a standstill), in the same torque units as
	TMAX: `rise` pushes the revs up with the throttle, `fall` is the engine's drag that brings them
	back down when you let go. At TMAX's 320 for both, a rev took ~4 s to fall back to idle, so a
	second blip had to wait for it; 500 (the starting point suggested for tuning) falls in ~2.6 s.
	Per car: config.revRise / config.revFall (sh_carlist.lua AudioEngine.CAR_REV). Runtime only: no re-bake.
]]
Drivetrain.REV = { rise = 500, fall = 500 }

-- Arcade gearbox shift points, as fractions of redline (cars can override with config.shift)
Drivetrain.SHIFT = {
	upRpm = 0.92,      -- W held: shift up here...
	lazyUpRpm = 0.68,  -- ...or as early as this when the car barely accelerates
	pullAccel = 2.5,   -- m/s2 of acceleration that counts as pulling hard (shifts at upRpm)
	lazyLand = 0.45,   -- an early upshift only if the next gear keeps the revs above this
	kickRpm = 0.60,    -- pressing W with the revs below this kicks down...
	sagRpm = 0.38,     -- ...and so does holding W while they sag below this
	kickLand = 0.88,   -- kickdown picks the lowest gear that stays under this
	-- braking: shift down once the revs fall below brakeRpm, landing under brakeLand. Low and gentle
	-- like a road automatic: at 0.80 / 0.96 with a full blip, hard braking ran a sawtooth of revs
	-- held near redline, every downshift a ~1000 rpm leap (it sounded cartoonish)
	brakeRpm = 0.45,
	brakeLand = 0.70,
	lugRpm = 0.40,     -- coasting: shift down below this (0.30 let corners sag to a near-idle drone)
	-- cornering (A/D held, or let go under cornerHold s ago): no early upshifts (the car isn't
	-- accelerating there because it turns, not because it's at top speed: it climbed through
	-- the gears to a drone), and it changes down once the revs fall below cornerRpm
	cornerRpm = 0.65,
	cornerLand = 0.88, -- ... to the lowest gear that stays under this
	cornerHold = 0.6,
	-- holding at the speed limiter (sv_cruise.lua: W held, the power trimmed): the highest gear that keeps the revs
	-- above cruiseLand, and down again only when they sag under sagRpm. Holding a speed is not
	-- you flooring it: no kickdown
	cruiseLand = 0.45,
	cruiseThr = 0.8,   -- the throttle it sounds like while holding the speed (the pedal 80% down)
}

-- a car's own shift points, any it leaves out from Drivetrain.SHIFT
local shiftCache = setmetatable({}, { __mode = "k" })
function Drivetrain.ShiftPoints(carShift)
	local points = shiftCache[carShift]
	if points then return points end
	points = {}
	for key, value in pairs(Drivetrain.SHIFT) do points[key] = value end
	for key, value in pairs(carShift) do points[key] = value end
	shiftCache[carShift] = points
	return points
end

function Drivetrain.TorqueNorm(config, rpm)
	local redlineShare = rpm / config.redline
	return clamp((0.55 + 1.1 * redlineShare - redlineShare * redlineShare) / 0.8525, 0.3, 1)
end

function Drivetrain.EmotionFlare(config)
	return clamp(config.redline * 0.55, 3000, 8000)
end

function Drivetrain.New()
	return {
		on = false, phase = "off", phaseTimer = 0, emotion = false,
		settleFromRpm = 0, settleElapsed = 0, settleDuration = 3,
		rpm = 0, gear = 0, throttle = 0, throttleAverage = 0, soundThrottle = 0,
		fuelCut = false, crankMode = 0, limiterCutTimer = 0, limiterHoldTimer = 0, limiterEvent = false,
		shiftTimer = 0, shiftDirection = 0, gearHoldTimer = 0,
		boost = 0, blowOffEvent = nil, lastPedal = false,
		lastSpeed = 0, acceleration = 0, stallTimer = 0, throttleHeldFor = 9, timeSinceSteering = 9,
	}
end

function Drivetrain.Start(engineState, emotion)
	engineState.on = true
	engineState.phase = "catch"
	engineState.phaseTimer = 0.3
	engineState.emotion = emotion and true or false
	engineState.rpm = max(engineState.rpm, 150)
end

-- engine was already running when we first saw the car: skip the start-up sequence
function Drivetrain.SkipStart(engineState, config)
	engineState.on = true
	engineState.phase = "run"
	engineState.rpm = max(engineState.rpm, config.idle)
end

function Drivetrain.Stop(engineState)
	engineState.on = false
	engineState.phase = "off"
end

-- Rev Bench start-up: catch -> rev flare -> eased settle to idle
function Drivetrain.StartSequence(engineState, config, deltaTime)
	engineState.fuelCut = false
	engineState.crankMode = 0
	if config.electric then
		-- an electric car just powers up: a short hum, then it's ready
		engineState.rpm = engineState.rpm + (config.idle - engineState.rpm) * min(1, deltaTime * 8)
		engineState.soundThrottle = 0.15
		engineState.phaseTimer = engineState.phaseTimer - deltaTime
		if engineState.phaseTimer <= -0.3 then engineState.phase = "run" end
		return
	end
	if engineState.phase == "catch" then
		engineState.crankMode = 2
		engineState.soundThrottle = 0.35
		engineState.rpm = engineState.rpm + (500 - engineState.rpm) * min(1, deltaTime * 7)
		engineState.phaseTimer = engineState.phaseTimer - deltaTime
		if engineState.phaseTimer <= 0 then engineState.phase = "flare"; engineState.phaseTimer = 0.6 end
	elseif engineState.phase == "flare" then
		local flareRpm = engineState.emotion and Drivetrain.EmotionFlare(config) or (config.idle + 700)
		engineState.soundThrottle = engineState.emotion and 1 or 0.6
		engineState.rpm = engineState.rpm + (flareRpm * 1.04 - engineState.rpm) * min(1, deltaTime * (engineState.emotion and 10 or 8))
		engineState.phaseTimer = engineState.phaseTimer - deltaTime
		if engineState.rpm >= flareRpm or engineState.phaseTimer <= 0 then
			engineState.phase = "settle"
			engineState.settleFromRpm = engineState.rpm
			engineState.settleElapsed = 0
			engineState.settleDuration = engineState.emotion and 3 or 1.5
		end
	elseif engineState.phase == "settle" then
		engineState.settleElapsed = engineState.settleElapsed + deltaTime
		local settleProgress = min(1, engineState.settleElapsed / engineState.settleDuration)
		local ease = (1 + cos(pi * settleProgress)) / 2
		engineState.rpm = config.idle + (engineState.settleFromRpm - config.idle) * ease
		engineState.soundThrottle = 0.12 + 0.15 * ease
		if settleProgress >= 1 then engineState.phase = "run" end
	end
end

-- Free-spinning engine (neutral), from Rev Bench, with the game's own rise and fall (Drivetrain.REV)
function Drivetrain.FreeSpinRate(config, rpm, engineThrottle)
	local rise, fall = config.revRise or Drivetrain.REV.rise, config.revFall or Drivetrain.REV.fall
	local netTorque = engineThrottle * rise * Drivetrain.TorqueNorm(config, rpm) - fall * (0.05 + 0.12 * rpm / config.redline)
	return netTorque * 42 * (config.redline / 7000)
end
local function freeSpin(engineState, config, deltaTime, engineThrottle)
	engineState.rpm = engineState.rpm + Drivetrain.FreeSpinRate(config, engineState.rpm, engineThrottle) * deltaTime
end

local function gearRatio(config, gear)
	if gear == -1 then return config.reverse * config.final end
	if gear >= 1 then return config.gears[gear] * config.final end
	return 0
end
Drivetrain.GearRatio = gearRatio

--[[
	controls.forward, controls.backward, controls.handbrake : driver keys (W, S, Space)
	controls.steering            : A or D held (the gearbox holds its gear through corners)
	controls.holdingSpeedLimit   : holding at the speed limiter (sv_cruise.lua): steady throttle, 80%
	controls.speed               : speed along the car's nose, m/s (negative when rolling back)

	config.shiftPlan (a car's own gearing, sh_presets.lua AudioEngine.ApplyGearing) moves the shift points per gear:
	  up[g]    rpm where gear g changes up with W held (gentler pulling changes up earlier, by
	           the same lazyUpRpm / upRpm share as the default points)
	  down[g]  m/s under which gear g changes down coasting or braking (nil: the default points)
]]
function Drivetrain.Step(engineState, config, deltaTime, controls)
	local speed = controls.speed or 0
	local absoluteSpeed = abs(speed)
	engineState.limiterEvent = false
	-- smoothed acceleration, to notice when the car has stopped pulling at full throttle
	engineState.acceleration = engineState.acceleration + ((absoluteSpeed - engineState.lastSpeed) / deltaTime - engineState.acceleration) * min(1, deltaTime * 2)
	engineState.lastSpeed = absoluteSpeed

	-- which way the driver wants to go, and which pedal is the "throttle"
	local mode, pedal
	if controls.handbrake and absoluteSpeed < 1.0 then
		mode, pedal = "N", controls.forward         -- handbrake at a standstill: rev it in neutral
	elseif engineState.gear == 0 and absoluteSpeed < 1.0 and not controls.forward and not controls.backward then
		mode, pedal = "N", false           -- stays in neutral until W (or S) is pressed
	elseif speed < -0.6 or (controls.backward and not controls.forward and speed < 0.6) then
		mode, pedal = "R", controls.backward
	else
		mode, pedal = "D", controls.forward
	end
	-- S while rolling forward is the brake
	local braking = mode == "D" and controls.backward and not controls.forward and speed > 0.6

	local targetThrottle = pedal and (controls.holdingSpeedLimit and (config.shift and Drivetrain.ShiftPoints(config.shift) or Drivetrain.SHIFT).cruiseThr or 1) or 0
	engineState.throttle = engineState.throttle + clamp(targetThrottle - engineState.throttle, -deltaTime * (controls.holdingSpeedLimit and 1.5 or 7), deltaTime * 5)
	engineState.throttleAverage = engineState.throttleAverage + (engineState.throttle - engineState.throttleAverage) * min(1, deltaTime * 2.5)

	-- turbo boost: builds with load above ~1600 rpm with some lag, dumps through the
	-- blow-off valve when the throttle snaps shut
	engineState.blowOffEvent = nil
	if config.turbo then
		local targetBoost = (engineState.on and engineState.phase == "run") and engineState.soundThrottle * clamp((engineState.rpm - 1600) / 2000, 0, 1) or 0
		if targetBoost > engineState.boost then
			engineState.boost = engineState.boost + (targetBoost - engineState.boost) * min(1, deltaTime * 1.8)
		else
			engineState.boost = engineState.boost + (targetBoost - engineState.boost) * min(1, deltaTime * 5)
		end
		-- only a proper lift on boost vents audibly; a gentle lift stays quiet
		if engineState.lastPedal and not pedal and engineState.boost > 0.6 then
			engineState.blowOffEvent = engineState.boost
			engineState.boost = engineState.boost * 0.4
		end
	end
	if pedal and not engineState.lastPedal then
		engineState.throttleHeldFor = 0
	elseif pedal then
		engineState.throttleHeldFor = engineState.throttleHeldFor + deltaTime
	end
	engineState.timeSinceSteering = controls.steering and 0 or (engineState.timeSinceSteering or 9) + deltaTime
	engineState.lastPedal = pedal

	if not engineState.on then
		-- ignition off: spin down, with a few compression thumps at the end
		engineState.rpm = max(0, engineState.rpm - (500 + engineState.rpm * 1.6) * deltaTime)
		engineState.soundThrottle = 0
		engineState.fuelCut = true
		engineState.crankMode = engineState.rpm < 450 and 1 or 0
		engineState.gear = 0
		return
	end

	if engineState.phase ~= "run" then
		-- the start-up sequence always plays out; the car can't drive until it reaches idle
		-- (the server holds the car until then too)
		Drivetrain.StartSequence(engineState, config, deltaTime)
		return
	end

	engineState.fuelCut = false
	engineState.crankMode = 0

	-- put it in the right range
	if mode == "N" then
		engineState.gear = 0
	elseif mode == "R" then
		if engineState.gear ~= -1 then engineState.gear = -1; engineState.shiftTimer = 0.15; engineState.shiftDirection = 0 end
	elseif engineState.gear <= 0 then
		engineState.gear = 1; engineState.shiftTimer = 0.15; engineState.shiftDirection = 0; engineState.gearHoldTimer = 0.5
	end

	local throttle = engineState.throttle
	if engineState.shiftTimer > 0 then engineState.shiftTimer = engineState.shiftTimer - deltaTime end
	if engineState.rpm >= config.redline then
		if engineState.limiterCutTimer <= 0 then engineState.limiterEvent = true end
		engineState.limiterCutTimer = 0.07
		engineState.limiterHoldTimer = 0.25
	end
	if engineState.limiterHoldTimer > 0 then engineState.limiterHoldTimer = engineState.limiterHoldTimer - deltaTime end
	if engineState.limiterCutTimer > 0 then
		engineState.limiterCutTimer = engineState.limiterCutTimer - deltaTime
		throttle = 0
		engineState.fuelCut = true
	end

	local idleThrottle = clamp((config.idle - engineState.rpm) / 400, 0, 0.3)
	local engineThrottle = engineState.fuelCut and 0 or max(throttle, idleThrottle)

	if engineState.gear == 0 and config.electric then
		-- an electric motor doesn't rev on its own
		engineState.rpm = engineState.rpm + (config.idle - engineState.rpm) * min(1, deltaTime * 4)
		engineState.soundThrottle = throttle * 0.2
	elseif engineState.gear == 0 then
		freeSpin(engineState, config, deltaTime, engineThrottle)
		engineState.soundThrottle = engineThrottle
	else
		local rpmPerSpeed = 60 / (2 * pi * config.wheelRadius)  -- engine rpm per m/s at 1:1
		local wheelRpm = absoluteSpeed * rpmPerSpeed * gearRatio(config, engineState.gear)

		--[[
			Arcade automatic. The keys are on/off, so the box reads intent from them:
			  W held    hold each gear to near redline; kick down (skipping gears if needed)
			            when the revs are low
			  coasting  keep the gear and let the revs fall with the car; only change if it
			            would over-rev or lug
			  braking   cascade down through the gears, each one rev-matched with a blip
		]]
		if engineState.gear > 0 then
			local gearCount = #config.gears
			local redline = config.redline
			local shiftPoints = config.shift and Drivetrain.ShiftPoints(config.shift) or Drivetrain.SHIFT
			local rpm = engineState.rpm  -- the engine's actual revs
			local cornering = engineState.timeSinceSteering < shiftPoints.cornerHold
			local shiftPlan = config.shiftPlan
			local function rpmInGear(gear) return absoluteSpeed * rpmPerSpeed * gearRatio(config, gear) end
			-- where this gear changes up flat out, and the share of it a lazy upshift comes at
			local fullThrottleUpshiftRpm = shiftPlan and shiftPlan.up[engineState.gear] or redline * shiftPoints.upRpm
			local lazyUpshiftShare = shiftPoints.lazyUpRpm / shiftPoints.upRpm
			-- may the box land in gear g? (under `frac` of redline, and under that gear's own upshift)
			local function gearFits(gear, redlineShare)
				local gearRpm = rpmInGear(gear)
				return gearRpm < redline * redlineShare and not (shiftPlan and shiftPlan.up[gear] and gearRpm > shiftPlan.up[gear] * 0.97)
			end
			local plannedDownshiftSpeed = shiftPlan and shiftPlan.down[engineState.gear]
			-- soft: a braking / coasting downshift (a small blip and a slower rise, not a racing one)
			local function shiftTo(gear, direction, holdTime, soft)
				engineState.gear = gear
				engineState.shiftDirection = direction
				engineState.gearHoldTimer = holdTime
				engineState.stallTimer = 0
				engineState.softShift = soft or false
				engineState.shiftTimer = direction == 1 and 0.32 or 0.22
			end
			engineState.gearHoldTimer = engineState.gearHoldTimer - deltaTime
			-- about to hit the limiter: change up now, even inside the hold or the shift before
			-- (close gearing on a car that pulls hard reached redline before the hold ran out,
			-- and the limiter kept cutting the sound)
			if engineState.gearHoldTimer > 0 and engineState.gear < gearCount and wheelRpm > (pedal and fullThrottleUpshiftRpm or redline * 0.97) then
				shiftTo(engineState.gear + 1, 1, 0.8)
				wheelRpm = rpmInGear(engineState.gear)
			end
			if engineState.gearHoldTimer <= 0 and engineState.shiftTimer <= 0 then
				-- flat out but no longer accelerating (top speed / drag limit); slowing down
				-- (a turn scrubbing speed) is not that
				if pedal and not cornering and abs(engineState.acceleration) < 0.35 and wheelRpm > redline * 0.55 then
					engineState.stallTimer = engineState.stallTimer + deltaTime
				else
					engineState.stallTimer = 0
				end
				if pedal then
					-- kickdown when you get on it with the revs low, or if they sag while you hold it.
					-- Judged on the wheels' revs: the engine's include converter slip, which with W
					-- held never falls under ~0.47 x redline, so a car slowed by a turn stayed in its gear
					local kickdown = (engineState.throttleHeldFor < 0.6 and wheelRpm < redline * shiftPoints.kickRpm) or wheelRpm < redline * shiftPoints.sagRpm
					local cornerKickdown = cornering and wheelRpm < redline * shiftPoints.cornerRpm
					-- the shift point follows how hard the car pulls: flat out on a quick car it
					-- holds each gear to upRpm, a car that only creeps faster (heavy, or near its
					-- top speed) changes up early, so it still climbs into its last gear
					local pullStrength = clamp(engineState.acceleration / shiftPoints.pullAccel, 0, 1)
					local lazyUpshiftRpm = fullThrottleUpshiftRpm * (lazyUpshiftShare + (1 - lazyUpshiftShare) * pullStrength)
					-- (not into the top gear: it changes up into that near the top speed, at upRpm
					-- or once it stops gaining speed, then settles at lower revs)
					-- (only while it still gains speed: slowing through a turn it changed up and stuck)
					local lazyUpshift = not cornering and engineState.acceleration > 0 and engineState.gear + 1 < gearCount
						and wheelRpm > lazyUpshiftRpm and rpmInGear(engineState.gear + 1) > redline * shiftPoints.lazyLand
					if controls.holdingSpeedLimit then
						kickdown, cornerKickdown = wheelRpm < redline * shiftPoints.sagRpm, false
						lazyUpshift = engineState.gear < gearCount and rpmInGear(engineState.gear + 1) > redline * shiftPoints.cruiseLand
					end
					local stalledInGear = engineState.gear < gearCount and engineState.stallTimer > 1.2
						and rpmInGear(engineState.gear + 1) > config.idle * 1.6
					if engineState.gear < gearCount and (wheelRpm > fullThrottleUpshiftRpm or lazyUpshift or stalledInGear) then
						shiftTo(engineState.gear + 1, 1, 0.8)
					elseif engineState.gear > 1 and (kickdown or cornerKickdown) then
						-- the lowest gear that keeps the revs under kickLand (skips gears if needed;
						-- under cruise just one, back above cruiseLand)
						local landingShare = controls.holdingSpeedLimit and shiftPoints.cruiseLand / 0.8 or kickdown and shiftPoints.kickLand or shiftPoints.cornerLand
						local targetGear = engineState.gear
						while targetGear > 1 and gearFits(targetGear - 1, landingShare) do targetGear = targetGear - 1 end
						if targetGear < engineState.gear then shiftTo(targetGear, -1, 0.8) end
					end
				elseif braking then
					-- down one gear once the revs fall below brakeRpm, as long as the lower gear
					-- lands under brakeLand: the revs fall with the car, each downshift a small blip
					-- (a car's own gearing: under its downshift speed, as long as the lower gear doesn't over-rev)
					if plannedDownshiftSpeed then
						if engineState.gear > 1 and absoluteSpeed < plannedDownshiftSpeed and rpmInGear(engineState.gear - 1) < redline * 0.97 then
							shiftTo(engineState.gear - 1, -1, 0.3, true)
						end
					elseif engineState.gear > 1 and rpm < redline * shiftPoints.brakeRpm and rpmInGear(engineState.gear - 1) < redline * shiftPoints.brakeLand then
						shiftTo(engineState.gear - 1, -1, 0.3, true)
					end
				else
					if engineState.gear < gearCount and wheelRpm > redline * 0.97 then
						shiftTo(engineState.gear + 1, 1, 0.8)                       -- rolling downhill: don't over-rev
					elseif engineState.gear > 1 and not controls.holdingSpeedLimit and plannedDownshiftSpeed and not cornering then
						if absoluteSpeed < plannedDownshiftSpeed and rpmInGear(engineState.gear - 1) < redline * 0.97 then
							shiftTo(engineState.gear - 1, -1, 0.6, true)
						end
					elseif engineState.gear > 1 and not controls.holdingSpeedLimit and rpm < redline * (cornering and shiftPoints.cornerRpm or shiftPoints.lugRpm)
						and rpmInGear(engineState.gear - 1) < redline * (cornering and shiftPoints.cornerLand or 0.75) then
						shiftTo(engineState.gear - 1, -1, 0.6, true)                -- don't let it lug (or drone through a corner)
					end
				end
				wheelRpm = rpmInGear(engineState.gear)
			end
		end

		-- torque converter: flares to stall speed when pulling away, then the revs climb with
		-- the car until it couples up; a little slip remains under load
		local converterRpm = config.idle + engineThrottle * (config.stallRpm - config.idle)
		local targetRpm = max(wheelRpm * (1 + 0.05 * engineThrottle), converterRpm + 0.35 * wheelRpm * engineThrottle)
		-- top gear and faster than the gearing expects: sit just under redline, don't bounce
		if engineState.gear > 0 and engineState.gear == #config.gears then targetRpm = min(targetRpm, config.redline * 0.985) end
		local followRate
		if engineState.shiftTimer > 0 then followRate = engineState.shiftDirection == -1 and (engineState.softShift and 8 or 16) or 7   -- downshifts snap up to the new revs
		elseif targetRpm > engineState.rpm then followRate = 5 + 5 * engineThrottle
		else followRate = 6 end
		engineState.rpm = engineState.rpm + (targetRpm - engineState.rpm) * min(1, deltaTime * followRate)

		if engineState.shiftTimer > 0 and engineState.shiftDirection == 1 then
			-- upshift: the gearbox briefly pulls torque, it doesn't cut it
			local upshiftProgress = 1 - engineState.shiftTimer / 0.32
			engineState.soundThrottle = engineThrottle * (0.3 + 0.7 * upshiftProgress * upshiftProgress)
		elseif engineState.shiftTimer > 0 and engineState.shiftDirection == -1 then
			engineState.soundThrottle = max(engineThrottle, engineState.softShift and 0.25 or 0.6)   -- downshift: rev-matching throttle blip
		else
			engineState.soundThrottle = engineThrottle
		end
	end

	engineState.rpm = clamp(engineState.rpm, 0, config.redline + 150)
end

return Drivetrain
