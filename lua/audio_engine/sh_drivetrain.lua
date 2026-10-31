--[[
	Audio Engine - rpm / gear model (shared, pure Lua)

	The car itself is driven by Source's vehicle physics. This model only decides what the
	engine is doing, from the car's real speed and the driver's keys: which gear an automatic
	box would be in, how far the torque converter lets it rev when pulling away, rev-matched
	downshifts, the rev limiter, and the start-up / shut-down sequence from Rev Bench.
	Its output (rpm, gear, sound throttle) feeds the sound and the HUD.
]]

AUDIO_ENGINE = AUDIO_ENGINE or {}
local DT = {}
AUDIO_ENGINE.Drivetrain = DT

local min, max, abs, cos, pi = math.min, math.max, math.abs, math.cos, math.pi
local function clamp(x, a, b) if x < a then return a elseif x > b then return b end return x end
DT.clamp = clamp

DT.TMAX = 320 -- Rev Bench reference torque, only used for free-revving

-- Arcade gearbox shift points, as fractions of redline (cars can override with cfg.shift)
DT.SHIFT = {
	upRpm = 0.92,      -- W held: shift up here...
	lazyUpRpm = 0.68,  -- ...or as early as this when the car barely accelerates
	pullAccel = 2.5,   -- m/s2 of acceleration that counts as pulling hard (shifts at upRpm)
	lazyLand = 0.45,   -- an early upshift only if the next gear keeps the revs above this
	kickRpm = 0.60,    -- pressing W with the revs below this kicks down...
	sagRpm = 0.38,     -- ...and so does holding W while they sag below this
	kickLand = 0.88,   -- kickdown picks the lowest gear that stays under this
	brakeRpm = 0.80,   -- braking: shift down once the revs fall below this...
	brakeLand = 0.96,  -- ...if the lower gear keeps them under this
	lugRpm = 0.30,     -- coasting: shift down below this
}

-- a car's own shift points, any it leaves out from DT.SHIFT
local shiftCache = setmetatable({}, { __mode = "k" })
function DT.ShiftPoints(t)
	local r = shiftCache[t]
	if r then return r end
	r = {}
	for k, v in pairs(DT.SHIFT) do r[k] = v end
	for k, v in pairs(t) do r[k] = v end
	shiftCache[t] = r
	return r
end

function DT.TorqueNorm(cfg, rpm)
	local x = rpm / cfg.redline
	return clamp((0.55 + 1.1 * x - x * x) / 0.8525, 0.3, 1)
end

function DT.EmotionFlare(cfg)
	return clamp(cfg.redline * 0.55, 3000, 8000)
end

function DT.New()
	return {
		on = false, phase = "off", phaseT = 0, emotion = false,
		settleFrom = 0, settleT = 0, settleDur = 3,
		rpm = 0, gear = 0, thr = 0, thrAvg = 0, soundThr = 0,
		cut = false, crankMode = 0, limT = 0, limHold = 0, limEvent = false,
		shiftT = 0, shiftKind = 0, holdT = 0,
		boost = 0, bovEvent = nil, lastPedal = false,
		lastV = 0, accel = 0, stallT = 0, pressT = 9,
	}
end

function DT.Start(st, emotion)
	st.on = true
	st.phase = "catch"
	st.phaseT = 0.3
	st.emotion = emotion and true or false
	st.rpm = max(st.rpm, 150)
end

-- engine was already running when we first saw the car: skip the start-up sequence
function DT.SkipStart(st, cfg)
	st.on = true
	st.phase = "run"
	st.rpm = max(st.rpm, cfg.idle)
end

function DT.Stop(st)
	st.on = false
	st.phase = "off"
end

-- Rev Bench start-up: catch -> rev flare -> eased settle to idle
function DT.StartSequence(st, cfg, dt)
	st.cut = false
	st.crankMode = 0
	if cfg.electric then
		-- an electric car just powers up: a short hum, then it's ready
		st.rpm = st.rpm + (cfg.idle - st.rpm) * min(1, dt * 8)
		st.soundThr = 0.15
		st.phaseT = st.phaseT - dt
		if st.phaseT <= -0.3 then st.phase = "run" end
		return
	end
	if st.phase == "catch" then
		st.crankMode = 2
		st.soundThr = 0.35
		st.rpm = st.rpm + (500 - st.rpm) * min(1, dt * 7)
		st.phaseT = st.phaseT - dt
		if st.phaseT <= 0 then st.phase = "flare"; st.phaseT = 0.6 end
	elseif st.phase == "flare" then
		local target = st.emotion and DT.EmotionFlare(cfg) or (cfg.idle + 700)
		st.soundThr = st.emotion and 1 or 0.6
		st.rpm = st.rpm + (target * 1.04 - st.rpm) * min(1, dt * (st.emotion and 10 or 8))
		st.phaseT = st.phaseT - dt
		if st.rpm >= target or st.phaseT <= 0 then
			st.phase = "settle"
			st.settleFrom = st.rpm
			st.settleT = 0
			st.settleDur = st.emotion and 3 or 1.5
		end
	elseif st.phase == "settle" then
		st.settleT = st.settleT + dt
		local p = min(1, st.settleT / st.settleDur)
		local ease = (1 + cos(pi * p)) / 2
		st.rpm = cfg.idle + (st.settleFrom - cfg.idle) * ease
		st.soundThr = 0.12 + 0.15 * ease
		if p >= 1 then st.phase = "run" end
	end
end

-- Free-spinning engine (neutral), straight from Rev Bench
local function freeSpin(st, cfg, dt, engThr)
	local Te = engThr * DT.TMAX * DT.TorqueNorm(cfg, st.rpm) - DT.TMAX * (0.05 + 0.12 * st.rpm / cfg.redline)
	st.rpm = st.rpm + Te * 42 * (cfg.redline / 7000) * dt
end

local function gearRatio(cfg, gear)
	if gear == -1 then return cfg.reverse * cfg.final end
	if gear >= 1 then return cfg.gears[gear] * cfg.final end
	return 0
end
DT.GearRatio = gearRatio

--[[
	inp.fwd, inp.back, inp.hand : driver keys (W, S, Space)
	inp.v                       : speed along the car's nose, m/s (negative when rolling back)
]]
function DT.Step(st, cfg, dt, inp)
	local v = inp.v or 0
	local av = abs(v)
	st.limEvent = false
	-- smoothed acceleration, to notice when the car has stopped pulling at full throttle
	st.accel = st.accel + ((av - st.lastV) / dt - st.accel) * min(1, dt * 2)
	st.lastV = av

	-- which way the driver wants to go, and which pedal is the "throttle"
	local mode, pedal
	if inp.hand and av < 1.0 then
		mode, pedal = "N", inp.fwd         -- handbrake at a standstill: rev it in neutral
	elseif st.gear == 0 and av < 1.0 and not inp.fwd and not inp.back then
		mode, pedal = "N", false           -- stays in neutral until W (or S) is pressed
	elseif v < -0.6 or (inp.back and not inp.fwd and v < 0.6) then
		mode, pedal = "R", inp.back
	else
		mode, pedal = "D", inp.fwd
	end
	-- S while rolling forward is the brake
	local braking = mode == "D" and inp.back and not inp.fwd and v > 0.6

	st.thr = st.thr + clamp((pedal and 1 or 0) - st.thr, -dt * 7, dt * 5)
	st.thrAvg = st.thrAvg + (st.thr - st.thrAvg) * min(1, dt * 2.5)

	-- turbo boost: builds with load above ~1600 rpm with some lag, dumps through the
	-- blow-off valve when the throttle snaps shut
	st.bovEvent = nil
	if cfg.turbo then
		local want = (st.on and st.phase == "run") and st.soundThr * clamp((st.rpm - 1600) / 2000, 0, 1) or 0
		if want > st.boost then
			st.boost = st.boost + (want - st.boost) * min(1, dt * 1.8)
		else
			st.boost = st.boost + (want - st.boost) * min(1, dt * 5)
		end
		-- only a proper lift on boost vents audibly; a gentle lift stays quiet
		if st.lastPedal and not pedal and st.boost > 0.6 then
			st.bovEvent = st.boost
			st.boost = st.boost * 0.4
		end
	end
	if pedal and not st.lastPedal then st.pressT = 0 elseif pedal then st.pressT = st.pressT + dt end
	st.lastPedal = pedal

	if not st.on then
		-- ignition off: spin down, with a few compression thumps at the end
		st.rpm = max(0, st.rpm - (500 + st.rpm * 1.6) * dt)
		st.soundThr = 0
		st.cut = true
		st.crankMode = st.rpm < 450 and 1 or 0
		st.gear = 0
		return
	end

	if st.phase ~= "run" then
		-- the start-up sequence always plays out; the car can't drive until it reaches idle
		-- (the server holds the car until then too)
		DT.StartSequence(st, cfg, dt)
		return
	end

	st.cut = false
	st.crankMode = 0

	-- put it in the right range
	if mode == "N" then
		st.gear = 0
	elseif mode == "R" then
		if st.gear ~= -1 then st.gear = -1; st.shiftT = 0.15; st.shiftKind = 0 end
	elseif st.gear <= 0 then
		st.gear = 1; st.shiftT = 0.15; st.shiftKind = 0; st.holdT = 0.5
	end

	local thr = st.thr
	if st.shiftT > 0 then st.shiftT = st.shiftT - dt end
	if st.rpm >= cfg.redline then
		if st.limT <= 0 then st.limEvent = true end
		st.limT = 0.07
		st.limHold = 0.25
	end
	if st.limHold > 0 then st.limHold = st.limHold - dt end
	if st.limT > 0 then st.limT = st.limT - dt; thr = 0; st.cut = true end

	local idleThr = clamp((cfg.idle - st.rpm) / 400, 0, 0.3)
	local engThr = st.cut and 0 or max(thr, idleThr)

	if st.gear == 0 and cfg.electric then
		-- an electric motor doesn't rev on its own
		st.rpm = st.rpm + (cfg.idle - st.rpm) * min(1, dt * 4)
		st.soundThr = thr * 0.2
	elseif st.gear == 0 then
		freeSpin(st, cfg, dt, engThr)
		st.soundThr = engThr
	else
		local K = 60 / (2 * pi * cfg.wheelRadius)  -- engine rpm per m/s at 1:1
		local wheelRpm = av * K * gearRatio(cfg, st.gear)

		--[[
			Arcade automatic. The keys are on/off, so the box reads intent from them:
			  W held    hold each gear to near redline; kick down (skipping gears if needed)
			            when the revs are low
			  coasting  keep the gear and let the revs fall with the car; only change if it
			            would over-rev or lug
			  braking   cascade down through the gears, each one rev-matched with a blip
		]]
		if st.gear > 0 then
			local n = #cfg.gears
			local red = cfg.redline
			local SH = cfg.shift and DT.ShiftPoints(cfg.shift) or DT.SHIFT
			local rpm = st.rpm  -- the engine's actual revs
			local function rpmIn(g) return av * K * gearRatio(cfg, g) end
			local function shift(g, kind, hold)
				st.gear = g; st.shiftKind = kind; st.holdT = hold; st.stallT = 0
				st.shiftT = kind == 1 and 0.32 or 0.22
			end
			st.holdT = st.holdT - dt
			-- about to hit the limiter: change up now, even inside the hold or the shift before
			-- (close gearing on a car that pulls hard reached redline before the hold ran out,
			-- and the limiter kept cutting the sound)
			if st.holdT > 0 and st.gear < n and wheelRpm > red * (pedal and SH.upRpm or 0.97) then
				shift(st.gear + 1, 1, 0.8)
				wheelRpm = rpmIn(st.gear)
			end
			if st.holdT <= 0 and st.shiftT <= 0 then
				-- flat out but no longer accelerating (top speed / drag limit)
				if pedal and st.accel < 0.35 and wheelRpm > red * 0.55 then
					st.stallT = st.stallT + dt
				else
					st.stallT = 0
				end
				if pedal then
					-- kickdown when you get on it with the revs low, or if they sag while you hold it
					local kick = (st.pressT < 0.6 and rpm < red * SH.kickRpm) or rpm < red * SH.sagRpm
					-- the shift point follows how hard the car pulls: flat out on a quick car it
					-- holds each gear to upRpm, a car that only creeps faster (heavy, or near its
					-- top speed) changes up early, so it still climbs into its last gear
					local pull = clamp(st.accel / SH.pullAccel, 0, 1)
					local upAt = red * (SH.lazyUpRpm + (SH.upRpm - SH.lazyUpRpm) * pull)
					local lazy = st.gear < n and wheelRpm > upAt and rpmIn(st.gear + 1) > red * SH.lazyLand
					if st.gear < n and (wheelRpm > red * SH.upRpm or lazy or (st.stallT > 1.2 and rpmIn(st.gear + 1) > cfg.idle * 1.6)) then
						shift(st.gear + 1, 1, 0.8)
					elseif st.gear > 1 and kick then
						-- the lowest gear that keeps the revs under kickLand (skips gears if needed)
						local g = st.gear
						while g > 1 and rpmIn(g - 1) < red * SH.kickLand do g = g - 1 end
						if g < st.gear then shift(g, -1, 0.8) end
					end
				elseif braking then
					-- down one gear once the revs fall below brakeRpm, as long as the lower gear
					-- lands under brakeLand: revs stay high, every downshift is a rev-matched blip
					if st.gear > 1 and rpm < red * SH.brakeRpm and rpmIn(st.gear - 1) < red * SH.brakeLand then
						shift(st.gear - 1, -1, 0.3)
					end
				else
					if st.gear < n and wheelRpm > red * 0.97 then
						shift(st.gear + 1, 1, 0.8)                       -- rolling downhill: don't over-rev
					elseif st.gear > 1 and rpm < red * SH.lugRpm and rpmIn(st.gear - 1) < red * 0.75 then
						shift(st.gear - 1, -1, 0.6)                      -- don't let it lug
					end
				end
				wheelRpm = rpmIn(st.gear)
			end
		end

		-- torque converter: flares to stall speed when pulling away, then the revs climb with
		-- the car until it couples up; a little slip remains under load
		local conv = cfg.idle + engThr * (cfg.stallRpm - cfg.idle)
		local target = max(wheelRpm * (1 + 0.05 * engThr), conv + 0.35 * wheelRpm * engThr)
		-- top gear and faster than the gearing expects: sit just under redline, don't bounce
		if st.gear > 0 and st.gear == #cfg.gears then target = min(target, cfg.redline * 0.985) end
		local rate
		if st.shiftT > 0 then rate = st.shiftKind == -1 and 16 or 7   -- downshifts snap up to the new revs
		elseif target > st.rpm then rate = 5 + 5 * engThr
		else rate = 6 end
		st.rpm = st.rpm + (target - st.rpm) * min(1, dt * rate)

		if st.shiftT > 0 and st.shiftKind == 1 then
			-- upshift: the gearbox briefly pulls torque, it doesn't cut it
			local p = 1 - st.shiftT / 0.32
			st.soundThr = engThr * (0.3 + 0.7 * p * p)
		elseif st.shiftT > 0 and st.shiftKind == -1 then
			st.soundThr = max(engThr, 0.6)      -- downshift: rev-matching throttle blip
		else
			st.soundThr = engThr
		end
	end

	st.rpm = clamp(st.rpm, 0, cfg.redline + 150)
end

return DT
