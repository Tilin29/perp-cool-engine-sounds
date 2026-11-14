--[[
	Car horn, client side: builds the horns of CAR_HORN.CONFIG with the synth (cl_horn_synth.lua,
	a few frames' work each, ahead of need: the horns of the cars around you, and the inside version
	of the one you sit in), plays the honks of nearby cars and reads the driver's honk key.

	A honk is one sound: the attack, then a loop for as long as the key is held (sound.Generate's
	loop start). Letting go fades it over the horn's release.time while its pitch falls to
	release.pitch. A press always sounds for at least MIN_HONK, so a tap is a short "beep", and a
	new press while one still sounds starts it again (beep-beep). Your own car's horn follows your
	key at once; everyone else's follows sh_horn.lua's networked state.

	Loudness: Source's own falloff at CONFIG.soundLevel, times the horn's fall-off (CONFIG.distance)
	over the engine's audible range: loud close up, fading to CONFIG.distance.volume at its `at`
	share and silent at `silent`. Inside the car: CONFIG.cabin, no fall-off, no Doppler.

	Overuse (car_horn_limit, CONFIG.limit): a horn running low plays quieter and lower (its car's
	horn_power from the server, or your own charge predicted here), and one held long eases down.
]]
local CarHorn = CAR_HORN
local Synth = CarHorn.Synth

local volumeConVar = CreateClientConVar("car_horn_volume", "1", true, false, "Car horn volume (0-1)", 0, 1)
local maxHornsConVar = CreateClientConVar("car_horn_maxcars", "8", true, false,
	"How many car horns you hear at once, the nearest ones (0 = all): the game mixes only so many sounds", 0, 64)
local dopplerConVar = CreateClientConVar("car_horn_doppler", "1", true, false,
	"Doppler pitch shift of passing car horns, x the horn's own setting (0 = off, 1 = default, 2 = double)", 0, 2)
local keyConVar = CreateClientConVar("car_horn_key", CarHorn.CONFIG.keys.honk, true, false,
	"Key held to sound the horn of the car you drive (a key name such as lalt; none = off)")

local LIST_REFRESH = 0.5
-- a honking car past the nearest car_horn_maxcars is cut; it's back once HORN_BUDGET_MARGIN places inside
local HORN_BUDGET_MARGIN = 2
local BUILD_BUDGET = 0.004
local MIN_HONK = 0.12        -- s a press sounds at least (a tap)
local QUICK_FADE = 0.03      -- s: cut for a new press, getting in or out, the budget
local VOLUME_GLIDE = 0.1
local VOLUME_STEP = 0.01     -- volume changes under this aren't sent
local UNITS_PER_METER = 1 / 0.0254
local DEFAULT_RANGE = 250    -- m: the engine's audible range for an 85 dB car when audio_engine_range isn't there (or 0)
-- Doppler, as the siren's: speeds from positions sampled at least SPEED_SAMPLE s apart, gaps over
-- SPEED_GAP or speeds over SPEED_MAX (a teleport) dropped, smoothed by SPEED_SMOOTH; the pitch
-- follows its target at DOPPLER_RATE per second
local SPEED_OF_SOUND = 13504   -- units/s (343 m/s)
local SPEED_SAMPLE = 0.05
local SPEED_GAP = 0.3
local SPEED_MAX = 6000
local SPEED_SMOOTH = 0.5
local DOPPLER_RATE = 14
-- Source sets pitch in whole percent: the horns are generated an octave low and played at
-- BASE_PITCH, which halves the step (and caps the pitch at PITCH_MAX / BASE_PITCH, +4 semitones)
local BASE_PITCH = 200
local PITCH_MIN, PITCH_MAX = 100, 255
local PITCH_GLIDE = 0.05
local REVIVE_EVERY = 1   -- s between checks that the game still plays a honk
--[[
	The game knows a playing sound by its entity and name: a honk fading out and a new one of the
	same name on the same car were the same sound to it, so the old one's fade and stop killed the
	new one (pressed twice, the horn went silent for good). Each horn is registered COPIES times
	under its own names (the samples are shared) and a car's honks take turns.
]]
local COPIES = 4

-- sound.Generate names can't be reused: a lua refresh builds under a new serial
CarHorn.Serial = (CarHorn.Serial or 0) + 1
local built = {}      -- hornId -> { out = { name, ... COPIES }, inside = { ... } }
local queued = {}     -- { hornId, inside } waiting to be built, the one being built first
local failed = {}     -- "hornId/out|inside" whose build failed (not tried again)
local builder

local function versionName(inside) return inside and "inside" or "out" end

local function generate(hornId, inside)
	local horn = CarHorn.CONFIG.horns[hornId]
	local samples, sampleRate, sampleCount, loopStart = Synth.Render(horn, CarHorn.CONFIG, coroutine.yield, inside)
	local playbackRate = sampleRate / 2   -- an octave low (BASE_PITCH)
	local names = {}
	for copy = 1, COPIES do
		names[copy] = string.format("car_horn_%d_%s_%s_%d", CarHorn.Serial, hornId, versionName(inside), copy)
		sound.Generate(names[copy], playbackRate, sampleCount / playbackRate, function(sampleIndex)
			return samples[(sampleIndex % sampleCount) + 1] or 0
		end, loopStart)
		coroutine.yield()
	end

	return names
end

local function buildQueued()
	while #queued > 0 do
		local item = queued[1]
		built[item.hornId] = built[item.hornId] or {}
		built[item.hornId][versionName(item.inside)] = generate(item.hornId, item.inside)
		table.remove(queued, 1)
	end
end

local function isBuilt(hornId, inside)
	return built[hornId] ~= nil and built[hornId][versionName(inside)] ~= nil
end

-- `urgent`: a car honks with it right now, so it goes next (after the one being built)
local function requestBuild(hornId, inside, urgent)
	if isBuilt(hornId, inside) or failed[hornId .. "/" .. versionName(inside)] then return end
	for index, item in ipairs(queued) do
		if item.hornId == hornId and item.inside == inside then
			if urgent and index > 2 then table.insert(queued, 2, table.remove(queued, index)) end
			return
		end
	end
	local item = { hornId = hornId, inside = inside }
	if urgent and #queued > 0 then table.insert(queued, 2, item) else table.insert(queued, item) end
	if not builder or coroutine.status(builder) == "dead" then builder = coroutine.create(buildQueued) end
end

local function stepBuilder()
	if not builder or coroutine.status(builder) == "dead" then return end
	local startTime = SysTime()
	repeat
		local resumed, message = coroutine.resume(builder)
		if not resumed then
			local item = table.remove(queued, 1)
			ErrorNoHalt("[Car horn] building horn " .. tostring(item and item.hornId) .. " failed: " .. tostring(message) .. "\n")
			if item then failed[item.hornId .. "/" .. versionName(item.inside)] = true end
			builder = #queued > 0 and coroutine.create(buildQueued) or nil
			return
		end
	until coroutine.status(builder) == "dead" or SysTime() - startTime > BUILD_BUDGET
end

-- the car the local player sits in (driver, or a passenger seat parented to it), or nil
local function riddenCar()
	local seat = LocalPlayer():GetVehicle()
	if not IsValid(seat) then return nil end
	local parent = seat:GetParent()

	return IsValid(parent) and parent:IsVehicle() and parent or seat
end

-- does the local player hear this car from inside: sitting in it and looking from their own eyes?
-- Watching through a camera (the view on another entity) they hear it from outside, as the engine does
local function insideOf(vehicle)
	return GetViewEntity() == LocalPlayer() and riddenCar() == vehicle
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

-- the listener: the camera entity when the view is on one, else the player's eyes
local function getListenerPosition()
	local player = LocalPlayer()
	local viewEntity = GetViewEntity()

	return (IsValid(viewEntity) and viewEntity ~= player) and viewEntity:GetPos() or player:EyePos()
end

-- how much higher (ratio) the listener hears a source moving at `sourceVelocity` through `sourcePosition`
local function dopplerRatio(sourcePosition, sourceVelocity)
	local strength = (CarHorn.CONFIG.doppler or 0) * dopplerConVar:GetFloat()
	if strength <= 0 then return 1 end
	local towardListener = listenerPosition - sourcePosition
	if towardListener:LengthSqr() < 1 then return 1 end
	towardListener:Normalize()
	local sourceClosing = sourceVelocity:Dot(towardListener)
	local listenerReceding = listenerVelocity:Dot(towardListener)
	local ratio = (SPEED_OF_SOUND - listenerReceding) / math.max(SPEED_OF_SOUND - sourceClosing, 1)

	return 1 + (ratio - 1) * strength
end

-- the engine's audible range (units) for a sound at the horn's level: audio_engine_range is for an
-- 85 dB car, and Source's falloff scales with 20 / (level - 50) (cl_engine.lua's audibleRangeOf)
local function audibleRange()
	local rangeConVar = GetConVar("audio_engine_range")
	local meters = rangeConVar and rangeConVar:GetFloat() or 0
	if meters <= 0 then meters = DEFAULT_RANGE end

	return meters * UNITS_PER_METER * math.max((CarHorn.CONFIG.soundLevel or 85) - 50, 1) / 35
end

--[[
	The horn's fall-off at `share` of the audible range (CONFIG.distance): 1 up to `full`, then
	even in dB over the log of the distance down to `volume` at `at`, carrying on at that slope
	while it eases out to 0 at `silent`.
]]
local function distanceVolume(share)
	local falloff = CarHorn.CONFIG.distance
	local full, at = math.max(falloff.full or 0.1, 0.001), falloff.at or 0.6
	local silent = math.max(falloff.silent or 1, at + 0.001)
	if share <= full then return 1 end
	if share >= silent then return 0 end
	local volume = (falloff.volume or 0.3) ^ (math.log(share / full) / math.log(math.max(at, full * 1.01) / full))
	if share > at then
		local progress = (share - at) / (silent - at)
		volume = volume * (1 - progress * progress * (3 - 2 * progress))
	end

	return math.min(volume, 1)
end

local cars = {}         -- vehicle -> { hornId, presses, holdUntil, velocityTrack, dopplerRatio, honk }
local hornCars = {}     -- the cars with a horn, refreshed every LIST_REFRESH
local overBudget = {}   -- vehicle -> true: past the nearest car_horn_maxcars honking cars
local fading = {}       -- released honks: { patch, stopAt }
local range = audibleRange()

-- your own honk key (polled below): your car follows it at once, not after the server's echo
local ownCar, ownHeld, ownPresses, ownHoldUntil = nil, false, 0, 0
-- your horn charge (sh_horn.lua's, in CurTime()), the server's time of the last one taken from it,
-- and whether this press is silent (run dry, or pressed while exhausted)
local ownCharge, ownChargeSyncedAt, ownMuted = nil, -1, false

local function syncOwnCharge(player, serverNow)
	ownCharge = ownCharge or CarHorn.NewCharge(serverNow)
	local at = player:GetNW2Float(CarHorn.CHARGE_AT_NW, -1)
	if at <= ownChargeSyncedAt then return end
	ownChargeSyncedAt = at
	ownCharge.charge, ownCharge.at = player:GetNW2Float(CarHorn.CHARGE_NW, CarHorn.CONFIG.limit.charge), at
	ownCharge.exhausted = player:GetNW2Bool(CarHorn.EXHAUSTED_NW, false)
	-- (the server let it run dry or turned the press away: so does this)
	if ownCharge.exhausted and ownCharge.honking then
		ownCharge.honking, ownCharge.croakUntil = false, nil
		ownMuted = true
	end
end

local function ownPower()
	if not CarHorn.Limited() or not ownCharge then return 1 end

	return CarHorn.ChargeStrength(ownCharge)
end

local function honkVolume(car, inside, distanceGain)
	local config = CarHorn.CONFIG

	return config.volume * (config.horns[car.hornId].level or 1) * volumeConVar:GetFloat() * (inside and config.cabin.volume or distanceGain)
end

local function startHonk(vehicle, car, inside, volume, pitch, presses)
	-- the car's next copy; one still fading under that name (4 presses inside a release) is cut first
	car.copy = car.copy % COPIES + 1
	local name = built[car.hornId][versionName(inside)][car.copy]
	for i = #fading, 1, -1 do
		local entry = fading[i]
		if entry.vehicle == vehicle and entry.name == name then
			entry.patch:Stop()
			table.remove(fading, i)
		end
	end
	local patch = CreateSound(vehicle, name)
	patch:SetSoundLevel(CarHorn.CONFIG.soundLevel or 85)
	-- (the attack is in the sound: it starts at its volume, no fade-in)
	patch:PlayEx(volume, pitch)

	return {
		patch = patch, name = name, inside = inside, presses = presses, volume = volume, pitch = pitch,
		nextReviveCheck = RealTime() + REVIVE_EVERY,
	}
end

-- let go: the horn's release (a fade, the pitch falling); `quick`: a short cut instead
local function releaseHonk(vehicle, honk, hornId, quick)
	local release = CarHorn.CONFIG.horns[hornId] and CarHorn.CONFIG.horns[hornId].release or {}
	local fadeTime = quick and QUICK_FADE or math.max(release.time or 0.05, 0.01)
	honk.patch:ChangeVolume(0, fadeTime)
	if not quick and (release.pitch or 1) ~= 1 then
		honk.patch:ChangePitch(math.Clamp(math.Round(honk.pitch * release.pitch), 1, 255), fadeTime)
	end
	table.insert(fading, { vehicle = vehicle, name = honk.name, patch = honk.patch, stopAt = RealTime() + fadeTime + 0.05 })
end

local function update(vehicle, car, now)
	-- what the car wants: your own key for your car, else the networked state
	-- (the server's count is followed in your car too, so getting out doesn't read your last press as a new one)
	local held, presses
	local networkPresses = vehicle:GetNW2Int(CarHorn.PRESSES_NW, 0)
	-- (power: how strong the horn still is, CONFIG.limit: predicted for yours, the server's for the others)
	local held, presses, power
	if vehicle == ownCar then
		held, presses, power = not ownMuted and (ownHeld or now < ownHoldUntil), ownPresses, ownPower()
	else
		if car.presses and networkPresses ~= car.presses then car.holdUntil = now + MIN_HONK end
		held, presses = vehicle:GetNW2Bool(CarHorn.ON_NW, false) or now < (car.holdUntil or 0), networkPresses
		power = CarHorn.Limited() and vehicle:GetNW2Float(CarHorn.POWER_NW, 1) or 1
	end
	car.presses = networkPresses

	local position = vehicle:GetPos()
	-- (followed while silent too, so a honk starts at the right Doppler pitch)
	local velocity = trackVelocity(car.velocityTrack, position, now)
	if not held and not car.honk then return end
	-- something else plays this car's honk (the police siren's horn override): the horn stays silent
	if held and hook.Run("car_horn/replace", vehicle) then held = false end
	local inside = insideOf(vehicle)
	local distanceGain = inside and 1 or distanceVolume(listenerPosition:Distance(position) / range)
	local audible = held and distanceGain > 0 and not vehicle:IsDormant() and not overBudget[vehicle]

	local honk = car.honk
	-- a new press, or the view moving in or out of the car: cut over; let go: its release
	if honk and (not audible or honk.inside ~= inside or honk.presses ~= presses) then
		releaseHonk(vehicle, honk, car.hornId, audible)
		car.honk, honk = nil, nil
	end

	-- (inside the car you move with it: no Doppler)
	local targetRatio = inside and 1 or dopplerRatio(position, velocity)
	if honk then
		car.dopplerRatio = car.dopplerRatio + (targetRatio - car.dopplerRatio) * math.min(1, RealFrameTime() * DOPPLER_RATE)
	else
		car.dopplerRatio = targetRatio
	end
	-- overused: weaker (quieter, its pitch sagging); held long: easing down
	local weakVolume, weakPitch = CarHorn.WeakFactors(power)
	local relax = (honk and CarHorn.Limited()) and CarHorn.RelaxFactor(now - honk.startedAt) or 1
	local pitch = math.Clamp(math.Round(BASE_PITCH * car.dopplerRatio * weakPitch), PITCH_MIN, PITCH_MAX)
	local volume = audible and honkVolume(car, inside, distanceGain) * weakVolume * relax or 0

	if audible and not honk then
		if isBuilt(car.hornId, inside) then
			car.honk = startHonk(vehicle, car, inside, volume, pitch, presses)
			car.honk.startedAt = now
		else
			-- (the horns around you are built ahead: this is a horn that wasn't, or the inside version)
			requestBuild(car.hornId, inside, true)
		end
		return
	end
	if not honk then return end

	-- the game only mixes so many sounds: a honk it dropped is started again
	if now >= honk.nextReviveCheck then
		honk.nextReviveCheck = now + REVIVE_EVERY
		if not honk.patch:IsPlaying() then
			honk.patch:Stop()
			honk.patch:PlayEx(volume, pitch)
			honk.volume, honk.pitch = volume, pitch
			return
		end
	end
	if math.abs(volume - honk.volume) > VOLUME_STEP then
		honk.patch:ChangeVolume(volume, VOLUME_GLIDE)
		honk.volume = volume
	end
	if pitch ~= honk.pitch then
		honk.patch:ChangePitch(pitch, PITCH_GLIDE)
		honk.pitch = pitch
	end
end

-- which honking cars are past the budget (the nearest ones are heard)
local function rankHorns()
	local maxHorns = maxHornsConVar:GetInt()
	local honking = {}
	for _, vehicle in ipairs(hornCars) do
		local car = cars[vehicle]
		if car and not vehicle:IsDormant() and (car.honk or vehicle:GetNW2Bool(CarHorn.ON_NW, false)) then
			honking[#honking + 1] = { vehicle = vehicle, distance = listenerPosition:DistToSqr(vehicle:GetPos()) }
		end
	end
	table.sort(honking, function(first, second) return first.distance < second.distance end)
	local nextOverBudget = {}
	for rank, entry in ipairs(honking) do
		local limit = overBudget[entry.vehicle] and maxHorns - HORN_BUDGET_MARGIN or maxHorns
		if maxHorns > 0 and rank > limit and entry.vehicle ~= ownCar then nextOverBudget[entry.vehicle] = true end
	end
	overBudget = nextOverBudget
end

-- the cars with a horn; builds ahead the horns of those in range, and the inside version of yours
local function refreshCars()
	range = audibleRange()
	hornCars = {}
	local seen = {}
	local ridden = riddenCar()
	for _, vehicle in ipairs(ents.FindByClass("prop_vehicle_jeep")) do
		local hornId = CarHorn.HornOf(vehicle)
		if hornId then
			hornCars[#hornCars + 1] = vehicle
			seen[vehicle] = true
			local car = cars[vehicle]
			if not car or car.hornId ~= hornId then
				if car and car.honk then releaseHonk(vehicle, car.honk, car.hornId, true) end
				cars[vehicle] = { hornId = hornId, velocityTrack = {}, dopplerRatio = 1, copy = 0 }
			end
			if vehicle == ridden then
				requestBuild(hornId, true)
				requestBuild(hornId, false)
			elseif not vehicle:IsDormant() and listenerPosition:Distance(vehicle:GetPos()) < range * (CarHorn.CONFIG.distance.silent or 1) then
				requestBuild(hornId, false)
			end
		end
	end
	for vehicle, car in pairs(cars) do
		if not seen[vehicle] then
			if car.honk then releaseHonk(vehicle, car.honk, car.hornId, false) end
			cars[vehicle] = nil
		end
	end
	rankHorns()
end

-- the honk key. Plain alt/shift/ctrl mean the left one (the game only knows KEY_LALT, KEY_LSHIFT...)
local KEY_ALIASES = { alt = "lalt", shift = "lshift", ctrl = "lcontrol", control = "lcontrol" }

local function isKeyDown(conVar)
	local keyName = string.lower(conVar:GetString())
	local keyCode = _G["KEY_" .. string.upper(KEY_ALIASES[keyName] or keyName)]

	return keyCode ~= nil and input.IsKeyDown(keyCode)
end

-- the driver's key, sent on press and release (a passenger's seat isn't a car: no horn). Not while
-- typing, in a menu or with the game in the background (alt-tab lets go of it).
-- With car_horn_limit, your charge is worked out here with the server's rules (sh_horn.lua), so your
-- horn weakens, croaks and stays silent when it does for everyone, and set right whenever the server
-- sends a newer one
local function pollKey(now)
	local player = LocalPlayer()
	local seat = player:GetVehicle()
	local driving = CarHorn.HornOf(seat) ~= nil
	ownCar = driving and seat or nil
	local limited = CarHorn.Limited()
	local serverNow = CurTime()
	if limited then syncOwnCharge(player, serverNow) end
	local down = driving and system.HasFocus() and not player:IsTyping() and not gui.IsGameUIVisible()
		and not IsValid(vgui.GetKeyboardFocus()) and isKeyDown(keyConVar)
	if down ~= ownHeld then
		ownHeld = down
		if down then
			ownPresses = ownPresses + 1
			ownHoldUntil = now + MIN_HONK
			-- (a honk something else plays isn't the horn's: it costs no charge, as on the server)
			local replaced = hook.Run("car_horn/replace", seat) == true
			ownMuted = limited and not replaced and not CarHorn.PressCharge(ownCharge, serverNow)
		elseif limited and ownCharge.honking then
			CarHorn.ReleaseCharge(ownCharge, serverNow)
		end
		net.Start("car_horn")
		net.WriteBool(down)
		net.SendToServer()
		-- your key, at once, for whatever plays this car's honk instead (car_horn/replace)
		hook.Run("car_horn/held", driving and seat or nil, down)
	end
	if limited and ownCharge.honking and not CarHorn.HoldCharge(ownCharge, serverNow) then ownMuted = true end
end

local nextRefresh = 0
hook.Add("Think", "car_horn", function()
	local player = LocalPlayer()
	if not IsValid(player) then return end
	local now = RealTime()
	pollKey(now)
	stepBuilder()
	listenerPosition = getListenerPosition()
	listenerVelocity = trackVelocity(listener, listenerPosition, now)
	if now >= nextRefresh then
		nextRefresh = now + LIST_REFRESH
		refreshCars()
	end
	for _, vehicle in ipairs(hornCars) do
		local car = cars[vehicle]
		if car and IsValid(vehicle) then update(vehicle, car, now) end
	end
	for i = #fading, 1, -1 do
		if now >= fading[i].stopAt then
			fading[i].patch:Stop()
			table.remove(fading, i)
		end
	end
end)

hook.Add("EntityRemoved", "car_horn", function(entity)
	local car = cars[entity]
	if not car then return end
	if car.honk then car.honk.patch:Stop() end
	cars[entity] = nil
end)
