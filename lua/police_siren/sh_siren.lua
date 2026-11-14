--[[
	Police siren: which tone a car plays. Separate from the audio engine: it only reads the
	police lights' networked state (the lightbar, the light mode and the lights' scheme, set by the
	audio engine's sv_police.lua), so it sounds on any car that has a lightbar or lights of its own.

	The lights pick the tone (CONFIG.lightTones, or the scheme's in CONFIG.schemes: fire and
	medical cars have tones of their own); the driver's tone key overrides it until the light mode
	changes (NW2 siren_tone + siren_at, the light mode it was chosen in).
]]
local PoliceSiren = POLICE_SIREN

PoliceSiren.LIGHTBAR_NW = "audio_lightbar"
PoliceSiren.LIGHTS_NW = "audio_lights"
PoliceSiren.SCHEME_NW = "audio_lightscheme"

function PoliceSiren.HasSiren(vehicle)
	return IsValid(vehicle) and IsValid(vehicle:GetNW2Entity(PoliceSiren.LIGHTBAR_NW))
end

-- the car's tone set: its scheme's lightTones and cycle, else the police ones
function PoliceSiren.Scheme(vehicle)
	local schemes = PoliceSiren.CONFIG.schemes

	return schemes and schemes[vehicle:GetNW2String(PoliceSiren.SCHEME_NW, "")] or PoliceSiren.CONFIG
end

-- the tone the lights or the driver chose: an id of CONFIG.tones, or "" for none
function PoliceSiren.ChosenTone(vehicle)
	local lightMode = vehicle:GetNW2Int(PoliceSiren.LIGHTS_NW, 0)
	if lightMode == 0 then return "" end
	if vehicle:GetNW2Int("siren_at", -1) == lightMode then return vehicle:GetNW2String("siren_tone", "") end

	return PoliceSiren.Scheme(vehicle).lightTones[lightMode] or ""
end

-- what the car sounds right now: a tone id, or nil
function PoliceSiren.SoundingTone(vehicle)
	local toneId = PoliceSiren.ChosenTone(vehicle)
	if toneId == "" or not PoliceSiren.CONFIG.tones[toneId] then return nil end

	return toneId
end

--[[
	The horn override: while the siren sounds, the car horn's key plays the scheme's honkTone instead
	(police phaser, EMS yelp, fire phaser) and the horn stays silent. The horn is its own module: it
	asks its car_horn/replace hook whether anything takes a car's honk over, and this answers. The
	key's state is the horn's networked one (HORN_NW / HORN_PRESSES_NW, read by name like the lights').
]]
PoliceSiren.HORN_NW = "horn_on"
PoliceSiren.HORN_PRESSES_NW = "horn_presses"

-- the tone the honk key plays on this car right now, or nil (no siren sounding, or no honkTone)
function PoliceSiren.HonkTone(vehicle)
	if not PoliceSiren.HasSiren(vehicle) or not PoliceSiren.SoundingTone(vehicle) then return nil end
	local toneId = PoliceSiren.Scheme(vehicle).honkTone
	if not toneId or toneId == "" or not PoliceSiren.CONFIG.tones[toneId] then return nil end

	return toneId
end

hook.Add("car_horn/replace", "police_siren", function(vehicle)
	if PoliceSiren.HonkTone(vehicle) then return true end
end)

-- the tone after `id` for the tone key: through the car's cycle, then off, then round again
function PoliceSiren.NextTone(vehicle, toneId)
	local cycle = PoliceSiren.Scheme(vehicle).cycle
	for index, cycleTone in ipairs(cycle) do
		if cycleTone == toneId then return cycle[index + 1] or "" end
	end

	return cycle[1] or ""
end
