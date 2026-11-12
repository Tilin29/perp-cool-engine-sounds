--[[
	Police siren, client side: builds each tone of POLICE_SIREN.CONFIG with the synth
	(cl_siren_synth.lua, a few frames' work, once a siren car is near), plays the tone each siren
	car sounds (sh_siren.lua) as a looping sound on the car, and reads the driver's keys.
]]
local PS = POLICE_SIREN
local Synth = PS.Synth

local cvVolume = CreateClientConVar("police_siren_volume", "1", true, false, "Police siren volume (0-1)", 0, 1)
local cvToneKey = CreateClientConVar("police_siren_tonekey", PS.CONFIG.keys.tone, true, false,
	"Key that steps the police siren of the car you drive to the next tone (a key name such as j; none = off)")
local cvHornKey = CreateClientConVar("police_siren_hornkey", PS.CONFIG.keys.horn, true, false,
	"Key that sounds the police siren's horn while held (a key name such as h; none = off)")

local LIST_REFRESH = 0.5
local BUILD_BUDGET = 0.005

-- sound.Generate names can't be reused: a lua refresh builds under a new serial
PS.Serial = (PS.Serial or 0) + 1
local soundNames = {}
local builder

local function buildAll()
	local cfg = PS.CONFIG
	for id, tone in pairs(cfg.tones) do
		local samples, sr, n = Synth.Render(tone, cfg, coroutine.yield)
		local name = string.format("police_siren_%d_%s", PS.Serial, id)
		sound.Generate(name, sr, n / sr, function(t)
			return samples[(t % n) + 1] or 0
		end, 1)
		soundNames[id] = name
		coroutine.yield()
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

local cars = {}
local fading = {}

local function startTone(veh, id)
	local cfg = PS.CONFIG
	local patch = CreateSound(veh, soundNames[id])
	patch:SetSoundLevel(cfg.soundLevel)
	patch:PlayEx(0, 100)

	return { id = id, patch = patch, fadeIn = cfg.volume * (cfg.tones[id].level or 1) * cvVolume:GetFloat() }
end

local function stopTone(state)
	local cfg = PS.CONFIG
	local patch = state.patch
	patch:ChangeVolume(0, cfg.release)
	if cfg.stopPitch < 1 then patch:ChangePitch(100 * cfg.stopPitch, cfg.release) end
	table.insert(fading, { patch = patch, stopAt = RealTime() + cfg.release })
end

local function update(veh)
	local state = cars[veh]
	local want = not veh:IsDormant() and PS.SoundingTone(veh) or nil
	if want and not soundNames[want] then
		if not builder then builder = coroutine.create(buildAll) end
		want = nil
	end
	if state and state.id == want then
		-- (a volume change in the frame the sound started doesn't take: the fade-in goes a frame later)
		if state.fadeIn then
			state.patch:ChangeVolume(state.fadeIn, PS.CONFIG.attack)
			state.fadeIn = nil
		end
		return
	end
	if state then stopTone(state) end
	cars[veh] = want and startTone(veh, want) or nil
end

local sirenCars = {}
local nextRefresh = 0

hook.Add("Think", "police_siren", function()
	local now = RealTime()
	stepBuilder()
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
			stopTone(state)
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

-- the keys, sent as console commands (as the audio engine's start and light keys).
-- Plain alt/shift/ctrl mean the left one (the game only knows KEY_LALT, KEY_LSHIFT...)
local KEY_ALIASES = { alt = "lalt", shift = "lshift", ctrl = "lcontrol", control = "lcontrol" }

local function keyDown(cv)
	local name = string.lower(cv:GetString())
	local key = _G["KEY_" .. string.upper(KEY_ALIASES[name] or name)]

	return key ~= nil and input.IsKeyDown(key)
end

local toneHeld, hornHeld = false, false
hook.Add("Think", "police_siren_keys", function()
	local ply = LocalPlayer()
	local veh = IsValid(ply) and ply:GetVehicle()
	local usable = IsValid(veh) and PS.HasSiren(veh) and not ply:IsTyping()
		and not gui.IsGameUIVisible() and not IsValid(vgui.GetKeyboardFocus())
	local tone = usable and keyDown(cvToneKey)
	local horn = usable and keyDown(cvHornKey)
	if tone and not toneHeld then RunConsoleCommand("police_siren_tone") end
	if horn ~= hornHeld then RunConsoleCommand("police_siren_horn", horn and "1" or "0") end
	toneHeld, hornHeld = tone, horn
end)
