--[[
	Police siren: which tone a car plays. Separate from the audio engine: it only reads the
	police lights' networked state (the lightbar and the light mode, set by the audio engine's
	sv_police.lua), so it sounds on any car that has a lightbar.

	The lights pick the tone (CONFIG.lightTones); the driver's tone key overrides it until the
	light mode changes (NW2 siren_tone + siren_at, the light mode it was chosen in).
]]
local PS = POLICE_SIREN

PS.LIGHTBAR_NW = "audio_lightbar"
PS.LIGHTS_NW = "audio_lights"

function PS.HasSiren(veh)
	return IsValid(veh) and IsValid(veh:GetNW2Entity(PS.LIGHTBAR_NW))
end

-- the tone the lights or the driver chose: an id of CONFIG.tones, or "" for none
function PS.ChosenTone(veh)
	local lights = veh:GetNW2Int(PS.LIGHTS_NW, 0)
	if lights == 0 then return "" end
	if veh:GetNW2Int("siren_at", -1) == lights then return veh:GetNW2String("siren_tone", "") end

	return PS.CONFIG.lightTones[lights] or ""
end

-- what the car sounds right now: a tone id, or nil
function PS.SoundingTone(veh)
	local id = PS.ChosenTone(veh)
	if id == "" or not PS.CONFIG.tones[id] then return nil end

	return id
end

-- the tone after `id` for the tone key: through CONFIG.cycle, then off, then round again
function PS.NextTone(id)
	local cycle = PS.CONFIG.cycle
	for i, c in ipairs(cycle) do
		if c == id then return cycle[i + 1] or "" end
	end

	return cycle[1] or ""
end
