--[[
	Audio Engine - car definitions (shared)

	Every car that should use the procedural engine is registered here by model path.
	The engine itself (layout, pitch, tone, idle, redline, gears...) is a profile: the car
	starts on its stock `preset` (see sh_presets.lua) and can be retuned in game with the
	tuning menu (!engine in chat, or right-click the car in the context menu).

	Car settings
	  preset       stock engine preset id from sh_presets.lua
	  topSpeed     km/h the car reaches, or "auto" to read MaxSpeed from its vehicle script.
	               With "fit gearing" on (the default), top gear is geared to reach redline
	               there, so every gear gets used
	  shift        arcade gearbox shift points (fractions of redline)
	  wheelRadius  metres
	  soundLevel   dB, how far the engine carries
	  volume       overall loudness for this car
	  stability    the drift-friendly handling assist (false = off for this car)
]]

AUDIO_ENGINE = AUDIO_ENGINE or {}
AUDIO_ENGINE.Cars = AUDIO_ENGINE.Cars or {}

function AUDIO_ENGINE.RegisterCar(model, cfg)
	cfg.model = string.lower(model)
	AUDIO_ENGINE.Cars[cfg.model] = cfg
	return cfg
end

function AUDIO_ENGINE.GetCarConfig(ent)
	if not ent or not ent.GetModel then return nil end
	local mdl = ent:GetModel()
	if not mdl then return nil end
	return AUDIO_ENGINE.Cars[string.lower(mdl)]
end

-- Mercedes-Benz SL65 AMG (R230): 6.0 L twin-turbo V12, 5-speed automatic.
AUDIO_ENGINE.RegisterCar("models/plpd/sl65amg_rtu.mdl", {
	carId = "sl65",
	name = "SL65 AMG",
	preset = "sl65",
	-- stock pops & bangs and blow-off, as for the PERP cars (sh_carlist.lua CAR_POPS / CAR_BOV):
	-- the AMG biturbo crackles now and then and recirculates its blow-off (no "pssh")
	stockPops = 0.15,
	stockPopVol = 0.7,
	stockBov = false,
	stockBovVol = 0.6,
	emotionStart = true,   -- rev flare on start-up (sh_carlist.lua CAR_EMOTION)
	topSpeed = "auto",     -- "auto" = MaxSpeed from the car's vehicle script, or a number in km/h

	-- arcade gearbox shift points as fractions of redline (remove to use the defaults).
	-- For the SL65's 6,000 rpm redline:
	shift = {
		upRpm = 0.92,      -- W held: shift up at 5,520 rpm
		kickRpm = 0.60,    -- pressing W below 3,600 rpm kicks down...
		sagRpm = 0.38,     -- ...and so does holding W while the revs sag under 2,280
		kickLand = 0.88,   -- kickdown picks the lowest gear that stays under 5,280
		brakeRpm = 0.80,   -- braking: shift down once the revs fall below 4,800...
		brakeLand = 0.96,  -- ...if the lower gear keeps them under 5,760
		lugRpm = 0.30,     -- coasting: shift down below 1,800
	},
	wheelRadius = 0.376,
	soundLevel = 85,
	volume = 1.0,

	-- stability control (server): follows your steering, catches spins, helps the car turn in.
	-- Remove a line to use the default; set stability = false to turn it off for this car.
	stability = {
		steerSlow = 35,        -- front wheel angle at full lock at parking speeds (degrees)
		steerFast = 10,        -- ... at 100+ km/h
		grip = 1.5,            -- cornering (g) the car may pull before it counts as sliding
		yawAllow = 10,         -- extra rotation (deg/s) allowed before it steps in
		driftYaw = 70,         -- ... with the handbrake held (drifting)
		overDamp = 9,          -- how firmly it catches oversteer
		turnHelp = 2.5,        -- how much turn-in it adds when the car pushes wide (0 = none)
		driftAngle = 30,       -- last-resort guard: tail-out slide angle (degrees)
		handbrakeAngle = 70,   -- ... while drifting (started with the handbrake)
		driftHold = 8,         -- a drift lasts while the car slides at least this many degrees
		minSpeed = 8,          -- km/h
	},
})
