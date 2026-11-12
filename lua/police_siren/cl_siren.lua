--[[
	Police siren, client side: builds each tone of POLICE_SIREN.CONFIG with the synth
	(cl_siren_synth.lua, a few frames' work, once a siren car is near) in two versions, as heard
	outside and inside the car (muffled, CONFIG.cabin), plays the tone each siren car sounds
	(sh_siren.lua) as a looping sound on the car, and reads the driver's tone key.
]]
local PS = POLICE_SIREN
local Synth = PS.Synth

local cvVolume = CreateClientConVar("police_siren_volume", "1", true, false, "Police siren volume (0-1)", 0, 1)
local cvToneKey = CreateClientConVar("police_siren_tonekey", PS.CONFIG.keys.tone, true, false,
	"Key that steps the police siren of the car you drive to the next tone (a key name such as q; none = off)")

local LIST_REFRESH = 0.5
local BUILD_BUDGET = 0.005
local SWAP_FADE = 0.15
-- Doppler: speeds from positions sampled at least SPEED_SAMPLE s apart (a frame-to-frame
-- reading jumps on every stutter), gaps over SPEED_GAP dropped, smoothed by SPEED_SMOOTH
local SPEED_OF_SOUND = 13504   -- units/s (343 m/s)
local SPEED_SAMPLE = 0.05
local SPEED_GAP = 0.3
local SPEED_SMOOTH = 0.5
local PITCH_MIN, PITCH_MAX = 75, 133
local PITCH_GLIDE = 0.05

-- sound.Generate names can't be reused: a lua refresh builds under a new serial
PS.Serial = (PS.Serial or 0) + 1
local soundNames = {}   -- id -> { out = name, inside = name }
local builder

local function generate(tone, id, inside)
	local cfg = PS.CONFIG
	local samples, sr, n = Synth.Render(tone, cfg, coroutine.yield, inside)
	local name = string.format("police_siren_%d_%s_%s", PS.Serial, id, inside and "in" or "out")
	sound.Generate(name, sr, n / sr, function(t)
		return samples[(t % n) + 1] or 0
	end, 1)
	coroutine.yield()

	return name
end

local function buildAll()
	for id, tone in pairs(PS.CONFIG.tones) do
		local out = generate(tone, id, false)
		soundNames[id] = { out = out, inside = generate(tone, id, true) }
	end
end

local function stepBuilder()
	if not builder or coroutine.status(builder) == "dead" then return end
	local t0 = SysTime()
	repeat
		local ok, err = coroutine.resume(builder)
		if not ok then
			ErrorNoHalt("[Police siren] building the tones failed: " .. tostring(err) .. "\n")
			builder = nil
			return
		end
	until coroutine.status(builder) == "dead" or SysTime() - t0 > BUILD_BUDGET
end

-- is the local player sitting in this car (driver, or a passenger seat parented to it)?
local function insideOf(veh)
	local seat = LocalPlayer():GetVehicle()
	if not IsValid(seat) then return false end

	return seat == veh or seat:GetParent() == veh
end

local cars = {}
local fading = {}

-- a moving point's velocity, from its position now and then
local function trackVelocity(track, pos, now)
	if not track.t then
		track.p, track.t, track.v = pos, now, Vector(0, 0, 0)
		return track.v
	end
	local dt = now - track.t
	if dt < SPEED_SAMPLE then return track.v end
	if dt <= SPEED_GAP then track.v = track.v + ((pos - track.p) / dt - track.v) * SPEED_SMOOTH end
	track.p, track.t = pos, now

	return track.v
end

local listener = {}
local listenerPos, listenerVel = Vector(0, 0, 0), Vector(0, 0, 0)

-- the pitch (percent) a listener hears from a source moving at vel through pos
local function dopplerPitch(pos, vel)
	local strength = PS.CONFIG.doppler or 0
	if strength <= 0 then return 100 end
	local dir = listenerPos - pos
	if dir:LengthSqr() < 1 then return 100 end
	dir:Normalize()
	local toward = vel:Dot(dir)            -- source closing in
	local away = listenerVel:Dot(dir)      -- listener moving off
	local ratio = (SPEED_OF_SOUND - away) / math.max(SPEED_OF_SOUND - toward, 1)
	ratio = 1 + (ratio - 1) * strength

	return math.Clamp(math.Round(100 * ratio), PITCH_MIN, PITCH_MAX)
end

local function startTone(veh, id, inside, fade)
	local cfg = PS.CONFIG
	local patch = CreateSound(veh, inside and soundNames[id].inside or soundNames[id].out)
	patch:SetSoundLevel(cfg.soundLevel)
	patch:PlayEx(0, 100)
	local volume = cfg.volume * (cfg.tones[id].level or 1) * cvVolume:GetFloat() * (inside and cfg.cabin.volume or 1)

	return { id = id, inside = inside, patch = patch, fadeIn = volume, fade = fade, pitch = 100, track = {} }
end

local function stopTone(state, fade, pitchDrop)
	local patch = state.patch
	patch:ChangeVolume(0, fade)
	if pitchDrop and PS.CONFIG.stopPitch < 1 then patch:ChangePitch(100 * PS.CONFIG.stopPitch, fade) end
	table.insert(fading, { patch = patch, stopAt = RealTime() + fade })
end

local function update(veh)
	local cfg = PS.CONFIG
	local state = cars[veh]
	local want = not veh:IsDormant() and PS.SoundingTone(veh) or nil
	if want and not soundNames[want] then
		if not builder then builder = coroutine.create(buildAll) end
		want = nil
	end
	local inside = want ~= nil and insideOf(veh)
	if state and state.id == want and state.inside == inside then
		-- (a volume change in the frame the sound started doesn't take: the fade-in goes a frame later)
		if state.fadeIn then
			state.patch:ChangeVolume(state.fadeIn, state.fade)
			state.fadeIn = nil
		end
		-- (inside the car you move with it: no Doppler)
		local vel = trackVelocity(state.track, veh:GetPos(), RealTime())
		local pitch = inside and 100 or dopplerPitch(veh:GetPos(), vel)
		if pitch ~= state.pitch then
			state.patch:ChangePitch(pitch, PITCH_GLIDE)
			state.pitch = pitch
		end
		return
	end
	-- getting in or out: the same tone swaps version quickly; a new tone or none fades as set
	local swap = state and state.id == want
	if state then stopTone(state, swap and SWAP_FADE or cfg.release, not swap) end
	cars[veh] = want and startTone(veh, want, inside, swap and SWAP_FADE or cfg.attack) or nil
end

local sirenCars = {}
local nextRefresh = 0

hook.Add("Think", "police_siren", function()
	local now = RealTime()
	stepBuilder()
	listenerPos = EyePos()
	listenerVel = trackVelocity(listener, listenerPos, now)
	if now >= nextRefresh then
		nextRefresh = now + LIST_REFRESH
		sirenCars = {}
		for _, veh in ipairs(ents.FindByClass("prop_vehicle_jeep")) do
			if PS.HasSiren(veh) then table.insert(sirenCars, veh) end
		end
	end
	for _, veh in ipairs(sirenCars) do
		if IsValid(veh) then update(veh) end
	end
	for veh, state in pairs(cars) do
		if not IsValid(veh) then
			stopTone(state, PS.CONFIG.release, true)
			cars[veh] = nil
		end
	end
	for i = #fading, 1, -1 do
		if now >= fading[i].stopAt then
			fading[i].patch:Stop()
			table.remove(fading, i)
		end
	end
end)

hook.Add("EntityRemoved", "police_siren", function(ent)
	local state = cars[ent]
	if not state then return end
	state.patch:Stop()
	cars[ent] = nil
end)

-- the tone key, sent as a console command (as the audio engine's start and light keys).
-- Plain alt/shift/ctrl mean the left one (the game only knows KEY_LALT, KEY_LSHIFT...)
local KEY_ALIASES = { alt = "lalt", shift = "lshift", ctrl = "lcontrol", control = "lcontrol" }

local function keyDown(cv)
	local name = string.lower(cv:GetString())
	local key = _G["KEY_" .. string.upper(KEY_ALIASES[name] or name)]

	return key ~= nil and input.IsKeyDown(key)
end

local toneHeld = false
hook.Add("Think", "police_siren_keys", function()
	local ply = LocalPlayer()
	local veh = IsValid(ply) and ply:GetVehicle()
	local usable = IsValid(veh) and PS.HasSiren(veh) and not ply:IsTyping()
		and not gui.IsGameUIVisible() and not IsValid(vgui.GetKeyboardFocus())
	local tone = usable and keyDown(cvToneKey)
	if tone and not toneHeld then RunConsoleCommand("police_siren_tone") end
	toneHeld = tone
end)
