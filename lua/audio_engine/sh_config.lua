--[[
	Audio Engine - car definitions (shared)

	Every car that should use the procedural engine is registered here by model path.
	The engine itself (layout, pitch, tone, idle, redline, gears...) is a profile: the car
	starts on its stock `preset` (see sh_presets.lua) and can be retuned in game with the
	tuning menu (!engine in chat, or right-click the car in the context menu) when the server has
	turned it on (audio_engine_editor 1; off by default).

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
	  gearing      the car's own shift speeds per gear (sh_presets.lua AudioEngine.ApplyGearing)
	  rev          { rise, fall }: how quickly it revs in neutral (sh_drivetrain.lua Drivetrain.REV)
]]

AUDIO_ENGINE = AUDIO_ENGINE or {}
AUDIO_ENGINE.Cars = AUDIO_ENGINE.Cars or {}

-- the in-game engine editor (the Rev Bench tuning menu): off unless the server turns it on
AUDIO_ENGINE.editorConVar = CreateConVar("audio_engine_editor", "0", FCVAR_ARCHIVE + FCVAR_REPLICATED,
	"1 = the in-game engine editor (Rev Bench menu: !engine, audio_engine_menu, context menu) is available; 0 = off")
function AUDIO_ENGINE.EditorEnabled() return AUDIO_ENGINE.editorConVar:GetBool() end

function AUDIO_ENGINE.RegisterCar(model, carConfig)
	carConfig.model = string.lower(model)
	AUDIO_ENGINE.Cars[carConfig.model] = carConfig
	return carConfig
end

-- model path -> lower case, kept: this runs for every car every tick / frame, and lowering the
-- same few paths again each time was most of its cost
local lowered = {}
function AUDIO_ENGINE.GetCarConfig(entity)
	if not entity or not entity.GetModel then return nil end
	local modelPath = entity:GetModel()
	if not modelPath then return nil end
	local lowerModel = lowered[modelPath]
	if not lowerModel then
		lowerModel = string.lower(modelPath)
		lowered[modelPath] = lowerModel
	end
	return AUDIO_ENGINE.Cars[lowerModel]
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
		brakeRpm = 0.45,   -- braking: shift down once the revs fall below 2,700...
		brakeLand = 0.70,  -- ...if the lower gear keeps them under 4,200
		lugRpm = 0.40,     -- coasting: shift down below 2,400
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
		turnHelp = 4,          -- how much turn-in it adds when the car pushes wide (0 = none)
		driftAngle = 30,       -- last-resort guard: tail-out slide angle (degrees)
		handbrakeAngle = 70,   -- ... while drifting (started with the handbrake)
		driftHold = 8,         -- a drift lasts while the car slides at least this many degrees
		minSpeed = 8,          -- km/h
	},
})
