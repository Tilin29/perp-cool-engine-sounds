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
	  stability    false = no handling model (sh_handling.lua) on this car: Source's tyres alone
	  gearing      the car's own shift speeds per gear (sh_presets.lua AudioEngine.ApplyGearing)
	  rev          { rise, fall }: how quickly it revs in neutral (sh_drivetrain.lua Drivetrain.REV)
]]

AUDIO_ENGINE = AUDIO_ENGINE or {}
AUDIO_ENGINE.Cars = AUDIO_ENGINE.Cars or {}

-- the in-game engine editor (the Rev Bench tuning menu): off unless the server turns it on
AUDIO_ENGINE.editorConVar = CreateConVar("audio_engine_editor", "0", FCVAR_ARCHIVE + FCVAR_REPLICATED,
	"1 = the in-game engine editor (Rev Bench menu: !engine, audio_engine_menu, context menu) is available; 0 = off")
function AUDIO_ENGINE.EditorEnabled() return AUDIO_ENGINE.editorConVar:GetBool() end

--[[ The engine's convars by name, for audio_engine_settings (below) and audio_engine_reset_settings (cl_engine).
	PLAYER_SETTINGS: client convars, made in cl_engine, cl_hud, cl_handling, cl_soundbank and cl_police.
	SERVER_SETTINGS: made in sh_config, sh_perp, sh_handling, sv_engine, sv_cruise and sv_seats; a client can
	read only the replicated ones. A new convar goes in one of these lists. ]]
AUDIO_ENGINE.PLAYER_SETTINGS = {
	"audio_engine_volume", "audio_engine_startkey", "audio_engine_roadnoise", "audio_engine_windnoise",
	"audio_engine_doppler", "audio_engine_passby", "audio_engine_tunnel", "audio_engine_maxcars", "audio_engine_range",
	"audio_engine_hud", "audio_engine_units", "audio_engine_hud_scale", "audio_engine_cluster",
	"audio_engine_predict", "audio_engine_predict_amount", "audio_engine_predict_others", "audio_engine_predict_debug", "audio_engine_predict_sound",
	"audio_engine_samplerate", "audio_engine_genbudget", "audio_engine_maxsounds", "audio_engine_baked",
	"audio_engine_lightkey", "audio_engine_indicator_volume",
}
AUDIO_ENGINE.SERVER_SETTINGS = {
	"audio_engine_editor", "audio_engine_tuneaccess", "audio_engine_tunecooldown",
	"audio_engine_mutestock", "audio_engine_muteskid", "audio_engine_mutetyrescrape",
	"audio_engine_drivemodel", "audio_engine_autostart", "audio_engine_keeprunning", "audio_engine_emotionstart",
	"audio_engine_cruise", "audio_engine_seats",
}

local function printSettingList(heading, names)
	print("  " .. heading .. ":")
	for _, name in ipairs(names) do
		local conVar = GetConVar(name)
		if conVar then
			local value, default = conVar:GetString(), conVar:GetDefault()
			print(string.format("    %-30s %s%s", name, value, value ~= default and ("   (default " .. default .. ")") or ""))
		elseif CLIENT then
			print(string.format("    %-30s (only the server can read it)", name))
		end
	end
end

--[[ audio_engine_settings: every convar of the addon with its value (and its default where it differs).
	In your own console: your settings and the server's you can see; in the server console (or rcon): the
	server's. Other modules (siren, horn, debug) add theirs through the "audio_engine/settings" hook, appending
	{ title, player = { names }, server = { names } } to the list it's given. ]]
concommand.Add("audio_engine_settings", function()
	local groups = { { title = "Audio engine", player = AUDIO_ENGINE.PLAYER_SETTINGS, server = AUDIO_ENGINE.SERVER_SETTINGS } }
	hook.Run("audio_engine/settings", groups)
	for _, group in ipairs(groups) do
		print(group.title)
		if CLIENT and group.player then printSettingList("your settings", group.player) end
		if group.server then printSettingList("server", group.server) end
	end
end, nil, "Print every setting (convar) of the audio engine, siren and horn with its value")

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
