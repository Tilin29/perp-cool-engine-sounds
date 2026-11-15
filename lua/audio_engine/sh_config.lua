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

-- the car a player sits in: driving it, or in a seat parented to it (passengers, sv_seats.lua)
function AUDIO_ENGINE.RiddenCar(player)
	local seat = player:GetVehicle()
	if not IsValid(seat) then return nil end
	local parent = seat:GetParent()
	if IsValid(parent) and parent:IsVehicle() then return parent end
	return seat
end
