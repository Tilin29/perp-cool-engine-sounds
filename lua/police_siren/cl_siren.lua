--[[
	Police siren, client side: builds the tones of POLICE_SIREN.CONFIG with the synth
	(cl_siren_synth.lua, a few frames' work, the first time a nearby car sounds each one) in two
	versions, as heard outside and inside the car (muffled, CONFIG.cabin), plays the tone each siren car sounds
	(sh_siren.lua) as a looping sound on the car, and reads the driver's tone key.
]]
local PoliceSiren = POLICE_SIREN
local Synth = PoliceSiren.Synth

local volumeConVar = CreateClientConVar("police_siren_volume", "1", true, false, "Police siren volume (0-1)", 0, 1)
local maxSirensConVar = CreateClientConVar("police_siren_maxcars", "12", true, false,
	"How many sirens you hear at once, the nearest ones (0 = all): the game mixes only so many sounds", 0, 64)
-- (named with the engine's settings, where players look for it, but it belongs to the siren)
local dopplerConVar = CreateClientConVar("audio_engine_police_doppler", "1", true, false,
	"Doppler pitch shift of passing police sirens, x the siren's own setting (0 = off, 1 = default, 2 = double)", 0, 2)
local toneKeyConVar = CreateClientConVar("police_siren_tonekey", PoliceSiren.CONFIG.keys.tone, true, false,
	"Key that steps the police siren of the car you drive to the next tone (a key name such as q; none = off)")

local LIST_REFRESH = 0.5
-- a siren past the nearest police_siren_maxcars is let go (with its release); it comes back once it's
-- SIREN_BUDGET_MARGIN places inside, so two cars at the edge don't take turns
local SIREN_BUDGET_MARGIN = 2
local BUILD_BUDGET = 0.005
local SWAP_FADE = 0.15
-- Doppler: speeds from positions sampled at least SPEED_SAMPLE s apart (a frame-to-frame
-- reading jumps on every stutter), gaps over SPEED_GAP or speeds over SPEED_MAX (a teleport)
-- dropped, smoothed by SPEED_SMOOTH; the pitch follows its target at DOPPLER_RATE per second
local SPEED_OF_SOUND = 13504   -- units/s (343 m/s)
local SPEED_SAMPLE = 0.05
local SPEED_GAP = 0.3
local SPEED_MAX = 6000
local SPEED_SMOOTH = 0.5
local DOPPLER_RATE = 14
-- Source sets pitch in whole percent: on a near-pure tone a Doppler bend came out in audible
-- steps. The tones are generated an octave low and played at BASE_PITCH, which halves the step
-- (and caps the pitch at PITCH_MAX / BASE_PITCH, +4 semitones)
local BASE_PITCH = 200
local PITCH_MIN, PITCH_MAX = 150, 255
local PITCH_GLIDE = 0.05
local REVIVE_EVERY = 1   -- s between checks that the game still plays a siren

-- sound.Generate names can't be reused: a lua refresh builds under a new serial
PoliceSiren.Serial = (PoliceSiren.Serial or 0) + 1
local soundNames = {}   -- id -> { out = name, inside = name }
local queued = {}       -- ids waiting to be built, the one being built first
local failed = {}       -- ids whose build failed (not tried again)
local builtSamples = 0  -- samples held by the built tones (both versions)
local builder

local function generate(tone, toneId, inside)
	local config = PoliceSiren.CONFIG
	local samples, sampleRate, sampleCount = Synth.Render(tone, config, coroutine.yield, inside)
	local keyName = string.format("police_siren_%d_%s_%s", PoliceSiren.Serial, toneId, inside and "in" or "out")
	local playbackRate = sampleRate / 2   -- an octave low (BASE_PITCH)
	-- the game loops from sample 1, never 0 (as the engine's loops, cl_soundbank.lua): one pre-roll
	-- sample (the loop's last), then the loop, [y_L, y_1 .. y_L]. Without it every pass skipped y_1:
	-- a tick at the seam, plain to hear on a near-pure tone
	local storedCount = sampleCount + 1
	sound.Generate(keyName, playbackRate, storedCount / playbackRate, function(sampleIndex)
		local index = sampleIndex % storedCount
		return samples[index == 0 and sampleCount or index] or 0
	end, 1)
	builtSamples = builtSamples + storedCount
	coroutine.yield()

	return keyName
end

local function buildQueued()
	while #queued > 0 do
		local toneId = queued[1]
		local tone = PoliceSiren.CONFIG.tones[toneId]
		local outsideName = generate(tone, toneId, false)
		soundNames[toneId] = { out = outsideName, inside = generate(tone, toneId, true) }
		table.remove(queued, 1)
	end
end

local function requestTone(toneId)
	if failed[toneId] or table.HasValue(queued, toneId) then return end
	table.insert(queued, toneId)
	if not builder or coroutine.status(builder) == "dead" then builder = coroutine.create(buildQueued) end
end

local function stepBuilder()
	if not builder or coroutine.status(builder) == "dead" then return end
	local startTime = SysTime()
	repeat
		local resumed, message = coroutine.resume(builder)
		if not resumed then
			ErrorNoHalt("[Police siren] building tone " .. tostring(queued[1]) .. " failed: " .. tostring(message) .. "\n")
			failed[table.remove(queued, 1) or ""] = true
			builder = nil
			return
		end
	until coroutine.status(builder) == "dead" or SysTime() - startTime > BUILD_BUDGET
end

-- does the local player hear this car from inside: sitting in it (driver, or a passenger seat
-- parented to it) and looking from their own eyes? Watching through a camera (the view on
-- another entity) they hear it from outside like anyone else, Doppler included, as the engine does
local function insideOf(vehicle)
	local player = LocalPlayer()
	local seat = player:GetVehicle()
	if not IsValid(seat) or GetViewEntity() ~= player then return false end

	return seat == vehicle or seat:GetParent() == vehicle
end

local cars = {}
local fading = {}
local overBudget = {}   -- vehicle -> true: past the nearest police_siren_maxcars sounding cars (rankSirens)

--[[
	The horn override (sh_siren.lua's HonkTone): held honk key = the scheme's honkTone. Other cars'
	key is their networked horn state; a press always overrides at least HONK_MIN_OVERRIDE s (a tap's
	press and release can arrive together: the press count still changed). Your own car follows the
	horn's car_horn/held hook, so the override starts at once rather than after the server's echo
]]
local HONK_MIN_OVERRIDE = 0.15
local honkSeen = setmetatable({}, { __mode = "k" })   -- vehicle -> { presses, untilTime }
local ownHonkCar, ownHonkUntil = nil, 0

hook.Add("car_horn/held", "police_siren", function(vehicle, held)
	if held then
		ownHonkCar, ownHonkUntil = vehicle, RealTime() + HONK_MIN_OVERRIDE
	else
		ownHonkCar = nil
	end
end)

local function honkHeld(vehicle, now)
	local seen = honkSeen[vehicle]
	local presses = vehicle:GetNW2Int(PoliceSiren.HORN_PRESSES_NW, 0)
	if not seen then
		seen = { presses = presses, untilTime = 0 }
		honkSeen[vehicle] = seen
	elseif presses ~= seen.presses then
		seen.presses, seen.untilTime = presses, now + HONK_MIN_OVERRIDE
	end
	local seat = LocalPlayer():GetVehicle()
	if seat == vehicle then
		-- (your own car: your key, not the server's echo of it)
		return ownHonkCar == vehicle or now < ownHonkUntil
	end

	return vehicle:GetNW2Bool(PoliceSiren.HORN_NW, false) or now < seen.untilTime
end

-- what the car plays: its siren tone, or the honk tone while the honk key overrides it. The honk
-- tone is built as soon as the siren sounds (a first tap would otherwise go by while it's built)
local function playingTone(vehicle, now)
	local toneId = PoliceSiren.SoundingTone(vehicle)
	if not toneId then return nil end
	local honkTone = PoliceSiren.HonkTone(vehicle)
	if not honkTone then return toneId end
	if not soundNames[honkTone] then
		requestTone(honkTone)
		return toneId
	end

	return honkHeld(vehicle, now) and honkTone or toneId
end

-- a moving point's velocity, from its position now and then
local function trackVelocity(track, position, now)
	if not track.time then
		track.position, track.time, track.velocity = position, now, Vector(0, 0, 0)
		return track.velocity
	end
	local elapsed = now - track.time
	if elapsed < SPEED_SAMPLE then return track.velocity end
	local measured = (position - track.position) / elapsed
	if elapsed <= SPEED_GAP and measured:Length() < SPEED_MAX then track.velocity = track.velocity + (measured - track.velocity) * SPEED_SMOOTH end
	track.position, track.time = position, now

	return track.velocity
end

local listener = {}
local listenerPosition, listenerVelocity = Vector(0, 0, 0), Vector(0, 0, 0)

-- the listener: the camera entity when the view is on one, else the player's eyes (EyePos()
-- is only reliable while drawing: read in Think it jittered, and so did the listener's speed)
local function getListenerPosition()
	local player = LocalPlayer()
	local viewEntity = GetViewEntity()

	return (IsValid(viewEntity) and viewEntity ~= player) and viewEntity:GetPos() or player:EyePos()
end

-- how much higher (ratio) a listener hears a source moving at vel through pos
local function dopplerRatio(sourcePosition, sourceVelocity)
	local strength = (PoliceSiren.CONFIG.doppler or 0) * dopplerConVar:GetFloat()
	if strength <= 0 then return 1 end
	local towardListener = listenerPosition - sourcePosition
	if towardListener:LengthSqr() < 1 then return 1 end
	towardListener:Normalize()
	local sourceClosing = sourceVelocity:Dot(towardListener)            -- source closing in
	local listenerReceding = listenerVelocity:Dot(towardListener)      -- listener moving off
	local ratio = (SPEED_OF_SOUND - listenerReceding) / math.max(SPEED_OF_SOUND - sourceClosing, 1)

	return 1 + (ratio - 1) * strength
end

--[[
	The siren's own fade with distance (CONFIG.distance), on top of the game's: the game keeps an 85 dB
	sound at full volume for its first ~16 m and halves it per doubling after, and on a near-pure tone
	that didn't tell how far a siren was. Full volume up to `full` m, then even in dB over the log of the
	distance down to `volume` at `at` m, and on at that slope. Inside the car: none.
]]
local UNITS_PER_METER = 1 / 0.0254
local VOLUME_GLIDE = 0.1
local VOLUME_STEP = 0.005   -- volume changes under this aren't sent

local function distanceGain(vehicle)
	local falloff = PoliceSiren.CONFIG.distance
	if not falloff then return 1 end
	local meters = listenerPosition:Distance(vehicle:GetPos()) / UNITS_PER_METER
	local full = math.max(falloff.full or 20, 1)
	if meters <= full then return 1 end
	local at = math.max(falloff.at or 150, full * 1.01)

	return (falloff.volume or 0.4) ^ (math.log(meters / full) / math.log(at / full))
end

local function startTone(vehicle, toneId, inside, fadeTime)
	local config = PoliceSiren.CONFIG
	local name = inside and soundNames[toneId].inside or soundNames[toneId].out
	-- the game knows a playing sound by entity + name: a fading one of this name on this car would take
	-- the new one down with it when it stops (a tone back right after the honk override): cut it now
	for i = #fading, 1, -1 do
		if fading[i].vehicle == vehicle and fading[i].name == name then
			fading[i].patch:Stop()
			table.remove(fading, i)
		end
	end
	local patch = CreateSound(vehicle, name)
	patch:SetSoundLevel(config.soundLevels[string.lower(vehicle:GetModel() or "")] or config.soundLevel)
	patch:PlayEx(0, BASE_PITCH)
	local baseVolume = config.volume * (config.tones[toneId].level or 1) * volumeConVar:GetFloat() * (inside and config.cabin.volume or 1)
	local volume = baseVolume * (inside and 1 or distanceGain(vehicle))

	return {
		toneId = toneId, name = name, vehicle = vehicle, inside = inside, patch = patch, baseVolume = baseVolume,
		volume = volume, fadeInVolume = volume, fadeTime = fadeTime,
		pitch = BASE_PITCH, dopplerRatio = 1, velocityTrack = {}, nextReviveCheck = RealTime() + REVIVE_EVERY,
	}
end

local function stopTone(state, fadeTime, pitchDrop)
	local patch = state.patch
	patch:ChangeVolume(0, fadeTime)
	if pitchDrop and PoliceSiren.CONFIG.stopPitch < 1 then patch:ChangePitch(state.pitch * PoliceSiren.CONFIG.stopPitch, fadeTime) end
	table.insert(fading, { vehicle = state.vehicle, name = state.name, patch = patch, stopAt = RealTime() + fadeTime })
end

local function update(vehicle)
	local config = PoliceSiren.CONFIG
	local state = cars[vehicle]
	local wantedTone = not vehicle:IsDormant() and not overBudget[vehicle] and playingTone(vehicle, RealTime()) or nil
	if wantedTone and not soundNames[wantedTone] then
		requestTone(wantedTone)
		wantedTone = nil
	end
	local listenerInside = wantedTone ~= nil and insideOf(vehicle)
	if state and state.toneId == wantedTone and state.inside == listenerInside then
		-- (a volume change in the frame the sound started doesn't take: the fade-in goes a frame later)
		local volume = state.baseVolume * (state.inside and 1 or distanceGain(vehicle))
		if state.fadeInVolume then
			state.patch:ChangeVolume(volume, state.fadeTime)
			state.fadeInVolume = nil
			state.volume = volume
		elseif math.abs(volume - state.volume) > VOLUME_STEP then
			-- (the distance fade, CONFIG.distance)
			state.patch:ChangeVolume(volume, VOLUME_GLIDE)
			state.volume = volume
		end
		-- the game only mixes so many sounds: with many cars driving around it takes a channel back,
		-- and a siren it dropped stayed silent. Started again at its full volume, it holds on to one
		local now = RealTime()
		if now >= state.nextReviveCheck then
			state.nextReviveCheck = now + REVIVE_EVERY
			if not state.patch:IsPlaying() then
				state.patch:Stop()
				state.patch:PlayEx(state.volume, state.pitch)
			end
		end
		-- (inside the car you move with it: no Doppler)
		local velocity = trackVelocity(state.velocityTrack, vehicle:GetPos(), RealTime())
		local targetRatio = listenerInside and 1 or dopplerRatio(vehicle:GetPos(), velocity)
		state.dopplerRatio = state.dopplerRatio + (targetRatio - state.dopplerRatio) * math.min(1, RealFrameTime() * DOPPLER_RATE)
		local pitch = math.Clamp(math.Round(BASE_PITCH * state.dopplerRatio), PITCH_MIN, PITCH_MAX)
		if pitch ~= state.pitch then
			state.patch:ChangePitch(pitch, PITCH_GLIDE)
			state.pitch = pitch
		end
		return
	end
	-- getting in or out: the same tone swaps version quickly; a new tone or none fades as set
	local swapVersion = state and state.toneId == wantedTone
	if state then stopTone(state, swapVersion and SWAP_FADE or config.release, not swapVersion) end
	cars[vehicle] = wantedTone and startTone(vehicle, wantedTone, listenerInside, swapVersion and SWAP_FADE or config.attack) or nil
end

local sirenCars = {}

-- which sounding siren cars are past the budget (the nearest ones are heard)
local function rankSirens()
	local maxSirens = maxSirensConVar:GetInt()
	local sounding = {}
	for _, vehicle in ipairs(sirenCars) do
		if IsValid(vehicle) and not vehicle:IsDormant() and PoliceSiren.SoundingTone(vehicle) then
			sounding[#sounding + 1] = { vehicle = vehicle, distance = listenerPosition:DistToSqr(vehicle:GetPos()) }
		end
	end
	table.sort(sounding, function(first, second) return first.distance < second.distance end)
	local nextOverBudget = {}
	for rank, entry in ipairs(sounding) do
		local limit = overBudget[entry.vehicle] and maxSirens - SIREN_BUDGET_MARGIN or maxSirens
		if maxSirens > 0 and rank > limit then nextOverBudget[entry.vehicle] = true end
	end
	overBudget = nextOverBudget
end
local nextRefresh = 0

-- for profilers (the audio engine's debug module reads it when the siren is installed): what the
-- siren holds right now. Only counts, kept anyway; nothing is measured unless asked
function PoliceSiren.Stats()
	local builtCount, playingCount = 0, 0
	for _ in pairs(soundNames) do builtCount = builtCount + 1 end
	for _, state in pairs(cars) do
		if state.patch:IsPlaying() then playingCount = playingCount + 1 end
	end

	return {
		tonesBuilt = builtCount, samples = builtSamples, sampleRate = PoliceSiren.CONFIG.sampleRate or 44100,
		cars = #sirenCars, sounding = table.Count(cars), patches = table.Count(cars) + #fading, playing = playingCount,
		building = #queued,
	}
end

hook.Add("Think", "police_siren", function()
	local now = RealTime()
	stepBuilder()
	listenerPosition = getListenerPosition()
	listenerVelocity = trackVelocity(listener, listenerPosition, now)
	if now >= nextRefresh then
		nextRefresh = now + LIST_REFRESH
		sirenCars = {}
		for _, vehicle in ipairs(ents.FindByClass("prop_vehicle_jeep")) do
			if PoliceSiren.HasSiren(vehicle) then table.insert(sirenCars, vehicle) end
		end
		rankSirens()
	end
	for _, vehicle in ipairs(sirenCars) do
		if IsValid(vehicle) then update(vehicle) end
	end
	for vehicle, state in pairs(cars) do
		if not IsValid(vehicle) then
			stopTone(state, PoliceSiren.CONFIG.release, true)
			cars[vehicle] = nil
		end
	end
	for i = #fading, 1, -1 do
		if now >= fading[i].stopAt then
			fading[i].patch:Stop()
			table.remove(fading, i)
		end
	end
end)

hook.Add("EntityRemoved", "police_siren", function(entity)
	local state = cars[entity]
	if not state then return end
	state.patch:Stop()
	cars[entity] = nil
end)

-- the tone key, sent as a console command (as the audio engine's start and light keys).
-- Plain alt/shift/ctrl mean the left one (the game only knows KEY_LALT, KEY_LSHIFT...)
local KEY_ALIASES = { alt = "lalt", shift = "lshift", ctrl = "lcontrol", control = "lcontrol" }

local function isKeyDown(conVar)
	local keyName = string.lower(conVar:GetString())
	local keyCode = _G["KEY_" .. string.upper(KEY_ALIASES[keyName] or keyName)]

	return keyCode ~= nil and input.IsKeyDown(keyCode)
end

-- the tone next to the light mode on the audio engine's HUD (its audio_engine/lights-label hook)
hook.Add("audio_engine/lights-label", "police_siren", function(vehicle)
	local toneId = PoliceSiren.SoundingTone(vehicle)
	if toneId then return string.upper(PoliceSiren.CONFIG.tones[toneId].name) end
end)

-- Q (sandbox's spawn menu key) is the default tone key: no spawn menu while sitting in a siren car
hook.Add("SpawnMenuOpen", "police_siren", function()
	local seat = LocalPlayer():GetVehicle()
	if not IsValid(seat) then return end
	local sirenCar = IsValid(seat:GetParent()) and seat:GetParent() or seat
	if PoliceSiren.HasSiren(sirenCar) then return false end
end)

local toneHeld = false
hook.Add("Think", "police_siren_keys", function()
	local player = LocalPlayer()
	local vehicle = IsValid(player) and player:GetVehicle()
	local usable = IsValid(vehicle) and PoliceSiren.HasSiren(vehicle) and not player:IsTyping()
		and not gui.IsGameUIVisible() and not IsValid(vgui.GetKeyboardFocus())
	local toneKeyDown = usable and isKeyDown(toneKeyConVar)
	if toneKeyDown and not toneHeld then RunConsoleCommand("police_siren_tone") end
	toneHeld = toneKeyDown
end)
