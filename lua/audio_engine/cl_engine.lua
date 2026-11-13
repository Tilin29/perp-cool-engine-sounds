--[[
	Audio Engine - per-car engine sound (client)

	Each client runs the rpm/gear model for every registered car near it (from the car's speed and
	the driver's keys, which the server networks) and plays the generated loops:
	  * two neighbouring rpm bands at a time, pitched to the exact rpm and cross-faded
	  * on/off throttle layers of a band cross-faded by throttle (they share firing phase)
	  * a rev-limiter loop, start-up / shut-down one-shots and overrun pops
]]

local AudioEngine = AUDIO_ENGINE
local Drivetrain = AudioEngine.Drivetrain
local Bank = AudioEngine.Bank
local Synth = AudioEngine.Synth

local volumeConVar = CreateClientConVar("audio_engine_volume", "1", true, false, "Engine sound volume (0-2)", 0, 2)
-- the key that switches the engine on and off, e.g. i, k, f1, or none
local startKeyConVar = CreateClientConVar("audio_engine_startkey", "r", true, false, "Key that starts/stops the engine of the car you drive (a key name such as r, k or f1; none = off)")
local roadNoiseConVar = CreateClientConVar("audio_engine_roadnoise", "1", true, false, "Tyre roar volume (0-2)", 0, 2)
local windNoiseConVar = CreateClientConVar("audio_engine_windnoise", "1", true, false, "Wind noise volume (0-2)", 0, 2)
local dopplerConVar = CreateClientConVar("audio_engine_doppler", "1", true, false, "Doppler pitch shift of passing cars (0 = off, 1 = default, real, 4 = four times real)", 0, 4)
-- the default was 1 and clients saved it, so a new default alone wouldn't reach them: moved over
-- once, leaving any other value someone picked
-- The scale moved: it was 0.25 = real (1 = four times real), now 1 = real. Every client that ran
-- the old scale has the audio_engine_doppler_moved cookie (from the move before that): its saved
-- value is turned into the new scale once (x4); new clients start on the default
if cookie.GetNumber("audio_engine_doppler_real1", 0) == 0 then
	cookie.Set("audio_engine_doppler_real1", "1")
	if cookie.GetNumber("audio_engine_doppler_moved", 0) == 1 then
		RunConsoleCommand("audio_engine_doppler", tostring(math.min(dopplerConVar:GetFloat() * 4, 4)))
	end
end
local passbyConVar = CreateClientConVar("audio_engine_passby", "1", true, false, "How much other cars swell in loudness as they pass close by (0 = off, 1 = default)", 0, 2)
local tunnelConVar = CreateClientConVar("audio_engine_tunnel", "1", true, false,
	"Source DSP preset for cars in a tunnel (0 = no tunnel effect, 1 = default, the map's own, 6 = medium tunnel, 7 = large tunnel)", 0, 133)
local maxCarsConVar = CreateClientConVar("audio_engine_maxcars", "16", true, false,
	"How many cars you hear at once, the nearest ones (0 = all): the game mixes only so many sounds", 0, 64)
local rangeConVar = CreateClientConVar("audio_engine_range", "250", true, false,
	"Metres past which a car's engine goes quiet and stops playing (for an ordinary car; louder ones carry further; 0 = no limit)", 0, 2000)

-- the settings, read once a frame for every car (the Think hook below)
local settings = { volume = 1, roadNoise = 1, windNoise = 1, doppler = 1, passby = 1, tunnel = 1, range = 250, maxCars = 16 }
local function readSettings()
	settings.volume, settings.roadNoise, settings.windNoise = volumeConVar:GetFloat(), roadNoiseConVar:GetFloat(), windNoiseConVar:GetFloat()
	settings.doppler, settings.passby = dopplerConVar:GetFloat(), passbyConVar:GetFloat()
	settings.tunnel, settings.range = tunnelConVar:GetInt(), rangeConVar:GetFloat()
	settings.maxCars = maxCarsConVar:GetInt()
end
readSettings()

local cars = {}
AudioEngine.ClientCars = cars

local min, max, abs, log, sin, cos, pi, floor = math.min, math.max, math.abs, math.log, math.sin, math.cos, math.pi, math.floor
local bitAnd = bit.band

local function approach(value, target, maxStep)
	if value < target then return min(target, value + maxStep) end
	return max(target, value - maxStep)
end

---------------------------------------------------------------------------
-- sound patches
---------------------------------------------------------------------------
local function getPatch(car, name)
	local patch = car.patches[name]
	if not patch then
		patch = CreateSound(car.entity, name)
		car.patches[name] = patch
	end
	return patch
end

-- every sound starts here: the sound level and DSP go on before it plays (see updateRoom)
local function startPatch(car, name, volume, pitch)
	local patch = getPatch(car, name)
	patch:SetSoundLevel(car.currentSoundLevel or car.config.soundLevel or 85)
	patch:SetDSP(car.dspPreset)
	patch:PlayEx(volume, pitch)
	-- (PlayEx sets both: what's sent from here on only needs to differ from these)
	car.sentVolumes[name], car.sentPitches[name] = volume, floor(pitch)
end

--[[
	A playing loop's volume and pitch, sent only when they change: most loops sit still from one
	frame to the next (idling, cruising), and each call goes into the engine's sound system. The
	game only uses whole-number pitch, so a pitch is new when its whole number is; a volume when it
	moved over VOLUME_CHANGE_SHARE of itself (+ VOLUME_CHANGE_FLOOR: ~0.1 dB, far under a step anyone hears).
	car.changeFadeTime: the time the change glides over, for cars updated less than every frame (parked).
]]
local VOLUME_CHANGE_SHARE, VOLUME_CHANGE_FLOOR = 0.01, 0.0005
local function sendPatch(car, name, patch, volume, pitch)
	local sent = car.sentVolumes[name]
	if not sent or abs(volume - sent) > VOLUME_CHANGE_FLOOR + VOLUME_CHANGE_SHARE * sent then
		patch:ChangeVolume(volume, car.changeFadeTime)
		car.sentVolumes[name] = volume
	end
	local whole = floor(pitch)
	if whole ~= car.sentPitches[name] then
		patch:ChangePitch(pitch, car.changeFadeTime)
		car.sentPitches[name] = whole
	end
end

local function stopAll(car)
	for _, patch in pairs(car.patches) do patch:Stop() end
	car.patches = {}
	car.activeGroups = {}
	car.silentTime = {}
	car.currentVolumes = {}
	car.groupRoomGeneration = {}
	car.sentVolumes, car.sentPitches = {}, {}
	if car.oneShot then car.oneShot.patch:Stop(); car.oneShot = nil end
end

-- name lists and volume lists for setGroup, made once and reused: building them anew for every
-- band of every car each frame came to tens of thousands of tables a second for the GC
local singleNameLists = {}
local function singleNameList(name)
	local list = singleNameLists[name]
	if not list then
		list = { name }
		singleNameLists[name] = list
	end
	return list
end

local function namePairOf(layer)
	local pair = layer.namePair
	if not pair then
		pair = { layer.on, layer.off }
		layer.namePair = pair
	end
	return pair
end

local function volumeList(car, groupKey, first, second)
	local list = car.volumeLists[groupKey]
	if not list then
		list = {}
		car.volumeLists[groupKey] = list
	end
	list[1], list[2] = first, second
	return list
end

--[[
	Play/update a group of loops that must start together (on/off layers of one band).
	Volume only changes once a frame, and a big jump in one go is an audible click (zipper
	noise), so every loop glides to its target: smoothed, and never more than VOLUME_SLEW per
	second. Loops start from silence and fade out before they stop.
]]
local VOLUME_SLEW = 4
-- the supercharger whine plays at SC_GAIN (-3 dB) and fades from SC_FADE_FROM to SC_FADE_TO of
-- the car's top speed, down to SC_FAST_GAIN (-8 dB): by km/h slow cars never reached the fade
local SC_GAIN = 0.7
local SC_FADE_FROM, SC_FADE_TO, SC_FAST_GAIN = 0.4, 0.8, 0.4
-- setGroup keys of the whine's bands, and each env bank's { on, off } sound names per variant.
-- Built on first use, not at load: a Lua refresh can run this file against an older Synth
local SUPERCHARGER_GROUP_KEYS = {}
local superchargerNameCache = setmetatable({}, { __mode = "k" })
local function superchargerBandNames(env, variant)
	if not Synth.SC_BANDS then return nil end
	for bandIndex = #SUPERCHARGER_GROUP_KEYS + 1, #Synth.SC_BANDS do SUPERCHARGER_GROUP_KEYS[bandIndex] = "sc" .. bandIndex end
	local byVariant = superchargerNameCache[env]
	if not byVariant then
		byVariant = {}
		superchargerNameCache[env] = byVariant
	end
	local names = byVariant[variant]
	if names == nil then
		names = {}
		for bandIndex = 1, #Synth.SC_BANDS do
			local onName = env["sc_" .. variant .. "_" .. bandIndex]
			local offName = env["sc_" .. variant .. "_" .. bandIndex .. "_off"]
			if not (onName and offName) then
				names = false
				break
			end
			names[bandIndex] = { onName, offName }
		end
		byVariant[variant] = names
	end
	return names or nil
end
-- electric motors (and their low-speed hum) play at this fraction: their banks are rendered at a
-- workable level for 16-bit files, a real EV is far quieter than any engine
AudioEngine.EV_VOLUME = 0.1
local function glide(current, target, deltaTime)
	local nextValue = current + (target - current) * min(1, deltaTime * 18)
	local maxStep = VOLUME_SLEW * deltaTime
	if nextValue > current + maxStep then nextValue = current + maxStep elseif nextValue < current - maxStep then nextValue = current - maxStep end
	return nextValue
end

--[[
	A group that isn't playing starts only once it would be heard (GROUP_START_VOLUME, about -40 dB).
	Starting at any trace of volume, a car sweeping its revs opened every band it passed, and each
	stayed open while it faded: ~22 loops a car for a moment, and 40 cars setting off together
	asked the game for ~900 sounds at once, more than it mixes (sirens and the game's own sounds
	went missing). A group already playing still fades all the way out as before.
]]
local GROUP_START_VOLUME = 0.01
-- ...and stops once it has been under GROUP_STOP_VOLUME (~-48 dB) for GROUP_STOP_HOLD: the gap to the
-- start level keeps a band at the edge of the cross-fade from flickering on and off (it held 0.3 s
-- under 0.002 before, so a fast rev sweep kept six or seven bands open as they faded)
local GROUP_STOP_VOLUME, GROUP_STOP_HOLD = 0.004, 0.1

local function setGroup(car, groupKey, names, targetVolumes, pitch, deltaTime)
	local total = 0
	for i = 1, #targetVolumes do total = total + targetVolumes[i] end
	local currentVolumes = car.currentVolumes[groupKey]
	if total > 0.0005 and (car.activeGroups[groupKey] or total >= GROUP_START_VOLUME) then
		car.silentTime[groupKey] = 0
		if not car.activeGroups[groupKey] then
			currentVolumes = {}
			for i = 1, #names do
				currentVolumes[i] = glide(0, targetVolumes[i], deltaTime)
				startPatch(car, names[i], max(currentVolumes[i], 0.001), pitch)
			end
			car.currentVolumes[groupKey] = currentVolumes
			car.activeGroups[groupKey] = true
			car.groupRoomGeneration[groupKey] = car.roomGeneration
		else
			-- restarted when the room changed, or if the game dropped the loop (out of channels
			-- with many cars around): nothing else would start it again, the car just went silent
			local roomChanged = car.groupRoomGeneration[groupKey] ~= car.roomGeneration
			car.groupRoomGeneration[groupKey] = car.roomGeneration
			for i = 1, #names do
				currentVolumes[i] = glide(currentVolumes[i], targetVolumes[i], deltaTime)
				local patch = getPatch(car, names[i])
				if roomChanged or (car.reviveCheckDue and not patch:IsPlaying()) then
					patch:Stop()
					startPatch(car, names[i], max(currentVolumes[i], 0.001), pitch)
				else
					sendPatch(car, names[i], patch, max(currentVolumes[i], 0.001), pitch)
				end
			end
		end
	elseif car.activeGroups[groupKey] then
		car.silentTime[groupKey] = (car.silentTime[groupKey] or 0) + deltaTime
		local loudest = 0
		for i = 1, #names do
			currentVolumes[i] = glide(currentVolumes[i], 0, deltaTime)
			loudest = max(loudest, currentVolumes[i])
			sendPatch(car, names[i], getPatch(car, names[i]), max(currentVolumes[i], 0.001), pitch)
		end
		if loudest < GROUP_STOP_VOLUME and car.silentTime[groupKey] > GROUP_STOP_HOLD then
			for i = 1, #names do
				local patch = car.patches[names[i]]
				if patch then patch:Stop() end
			end
			car.activeGroups[groupKey] = false
		end
	end
end

local function playOneShot(car, kind, name, volume, pitch, fadeAt, duration)
	if car.oneShot then car.oneShot.patch:FadeOut(0.1) end
	local patch = CreateSound(car.entity, name)
	patch:SetSoundLevel(car.currentSoundLevel or car.config.soundLevel or 85)
	patch:SetDSP(car.dspPreset)
	patch:PlayEx(volume, pitch)
	car.oneShot = { kind = kind, patch = patch, startTime = RealTime(), fadeAt = fadeAt or 0, duration = duration }
end

local function playPop(car, volume, isBang)
	local bank = car.bank
	local sounds = isBang and bank.bangs or bank.pops
	if not sounds or #sounds == 0 then return end
	local pickField = isBang and "lastBangIndex" or "lastPopIndex"
	local pickIndex = math.random(#sounds)
	if pickIndex == car[pickField] and #sounds > 1 then pickIndex = pickIndex % #sounds + 1 end
	car[pickField] = pickIndex
	-- headroom: the pop's peak on top of the engine's, and of any pop still ringing, must stay
	-- under full scale
	local peak = bank.peak and bank.peak[sounds[pickIndex]] or 0.98
	volume = min(volume, max(0.05, 0.98 - (car.mixPeak or 0) - (car.popPeakLoad or 0)) / max(peak, 0.05))
	car.popPeakLoad = (car.popPeakLoad or 0) + volume * peak
	getPatch(car, sounds[car[pickField]]):Stop()
	startPatch(car, sounds[car[pickField]], math.min(1, volume), math.Clamp(math.random(92, 108) * (car.dopplerRatio or 1), 20, 255))
end

---------------------------------------------------------------------------
-- car state
---------------------------------------------------------------------------
local function newCar(entity, carConfig)
	return {
		entity = entity, config = AudioEngine.GetEngineConfig(entity), stockConfig = AudioEngine.ResolveProfile(carConfig), engineState = Drivetrain.New(),
		lastEngineOn = nil, firstUpdate = true,
		patches = {}, activeGroups = {}, silentTime = {}, currentVolumes = {}, headroomGain = 1, popPeak = 0, crossfadeLogRpm = nil,
		sentVolumes = {}, sentPitches = {}, volumeLists = {}, bandWeights = {}, changeFadeTime = 0, rangeGain = 1,
		loopGain = 0, smoothedThrottle = 0, limiterWeight = 0,
		-- no two cars are tuned exactly alike: +-1.5% so a row of them doesn't phase
		detune = 1 + (math.random() - 0.5) * 0.03,
		speedAlongNose = 0, velocity = Vector(0, 0, 0), dopplerRatio = 1,
		dspPreset = 0, roomGeneration = 0, groupRoomGeneration = {}, tunnelWeight = 0, nextReviveCheck = RealTime() + 1,
		samplePosition = entity:GetPos(), sampleTime = RealTime(), speedAlongNoseSamples = { 0, 0, 0 }, flatSpeedSamples = { 0, 0, 0 }, measuredSpeedAlongNose = 0, flatSpeed = 0,
	}
end

-- the car's nose direction in local space, from the wheel attachments (falls back to +Y,
-- the usual Source vehicle convention)
local function localForward(car)
	if car.localNoseDirection then return car.localNoseDirection end
	local entity = car.entity
	local wheelPositions = {}
	for _, attachmentName in ipairs({ "wheel_fl", "wheel_fr", "wheel_rl", "wheel_rr" }) do
		local attachmentId = entity:LookupAttachment(attachmentName)
		local attachment = attachmentId and attachmentId > 0 and entity:GetAttachment(attachmentId)
		if not attachment then return Vector(0, 1, 0) end
		wheelPositions[attachmentName] = entity:WorldToLocal(attachment.Pos)
	end
	local forward = (wheelPositions.wheel_fl + wheelPositions.wheel_fr) - (wheelPositions.wheel_rl + wheelPositions.wheel_rr)
	forward.z = 0
	if forward:Length() < 1 then return Vector(0, 1, 0) end
	forward:Normalize()
	car.localNoseDirection = forward
	return forward
end

local function readInputs(car)
	local entity = car.entity
	local inputBits = entity:GetNW2Int("audio_in", 0)
	local forwardHeld, backwardHeld, handbrakeHeld, steeringHeld = bitAnd(inputBits, 1) ~= 0, bitAnd(inputBits, 2) ~= 0, bitAnd(inputBits, 4) ~= 0, bitAnd(inputBits, 8) ~= 0
	local player = LocalPlayer()
	if IsValid(player) and player:GetVehicle() == entity then
		-- the local driver: use their own keys for zero latency, once we know they register
		local forwardKey, backwardKey, handbrakeKey = player:KeyDown(IN_FORWARD), player:KeyDown(IN_BACK), player:KeyDown(IN_JUMP)
		if forwardKey or backwardKey or handbrakeKey then car.usesLocalKeys = true end
		if car.usesLocalKeys then
			forwardHeld, backwardHeld, handbrakeHeld, steeringHeld = forwardKey, backwardKey, handbrakeKey, player:KeyDown(IN_MOVELEFT) ~= player:KeyDown(IN_MOVERIGHT)
		end
	end
	-- speed limiter (sv_cruise.lua): holding at the limit sounds like steady part throttle;
	-- over it the throttle is shut even with W held
	local limiterState = entity:GetNW2Int("audio_limst", 0)
	if limiterState == 2 then forwardHeld = false end
	return forwardHeld, backwardHeld, handbrakeHeld, steeringHeld, forwardHeld and limiterState == 1
end

-- the listener (whoever's ears the sound reaches): position and velocity, once per frame
local listener = { position = Vector(0, 0, 0), velocity = Vector(0, 0, 0), valid = false, tunnelWeight = 0 }
local SPEED_OF_SOUND = 343 / 0.0254   -- in inches/s

local function updateListener(deltaTime)
	local player = LocalPlayer()
	if not IsValid(player) then return end
	local viewEntity = GetViewEntity()
	local position = (IsValid(viewEntity) and viewEntity ~= player) and viewEntity:GetPos() or player:EyePos()
	local now = RealTime()
	if listener.valid and now > listener.time then
		local measuredVelocity = (position - listener.position) / (now - listener.time)
		if measuredVelocity:Length() > 6000 then measuredVelocity = listener.velocity end          -- teleported / respawned
		listener.velocity = listener.velocity + (measuredVelocity - listener.velocity) * min(1, deltaTime * 8)
	end
	listener.position, listener.time = position, now
	listener.valid = true
	listener.inCabin = IsValid(player:GetVehicle()) and viewEntity == player
end

-- f' = f (c + v_listener) / (c - v_source), both measured toward each other. Sound travels at
-- c / audio_engine_doppler: the default 1 is the real speed of sound, where an 80 mph drive-by
-- bends 3-4 semitones; 4 is four times that
-- The full boost goes shrill at speed: closing at 40 m/s came out almost an octave up. Up to
-- DOPPLER_KNEE semitones it's left alone (an ordinary pass), past it the shift bends over towards
-- DOPPLER_MAX, which a head-on pass at any speed never goes over
local DOPPLER_KNEE, DOPPLER_MAX = 4, 7
local function softPitch(ratio)
	local semitones = 12 * log(ratio) / log(2)
	local beyondKnee = abs(semitones) - DOPPLER_KNEE
	if beyondKnee <= 0 then return ratio end
	local bendRange = DOPPLER_MAX - DOPPLER_KNEE
	local bentSemitones = DOPPLER_KNEE + bendRange * math.tanh(beyondKnee / bendRange)
	return 2 ^ ((semitones > 0 and bentSemitones or -bentSemitones) / 12)
end

local function dopplerFactor(car, deltaTime, listenerInside)
	local strength = settings.doppler
	local targetRatio = 1
	if strength > 0 and not listenerInside and listener.valid then
		local toListener = listener.position - car.entity:GetPos()
		local distance = toListener:Length()
		if distance > 1 then
			toListener:Mul(1 / distance)
			local sourceClosingSpeed = car.velocity:Dot(toListener)            -- source toward listener
			local listenerClosingSpeed = -listener.velocity:Dot(toListener)      -- listener toward source
			local soundSpeed = SPEED_OF_SOUND / strength
			targetRatio = softPitch(max(soundSpeed * 0.25, soundSpeed + listenerClosingSpeed) / max(soundSpeed * 0.5, soundSpeed - sourceClosingSpeed))
		end
	end
	-- quick enough to keep up with the pitch drop: a fast close pass is over in about 0.2 s
	car.dopplerRatio = car.dopplerRatio + (targetRatio - car.dopplerRatio) * min(1, deltaTime * 14)
	return car.dopplerRatio
end

--[[
	Pass-by swell, for everyone but the car's own driver. Close up the game already plays a car
	at full level (its distance falloff only starts some 20-40 m out), so a drive-by had no
	loudness peak. Instead a car is turned down at range and rises as it gets close, the way
	distance really works: steepest right next to you, so the peak is sharp. It reaches full level
	at PASSBY_REF and keeps rising to PASSBY_NEAR, over the car's headroom ceiling: a pass is too
	short for the ceiling's margin to matter, so updateSound only holds the peak under PASSBY_PEAK.
	All of this is for fast cars: pace (0-1, PASSBY_SLOW to PASSBY_FAST m/s) sets how steep the
	drop is, from PASSBY_CURVE_SLOW (-5.4 dB at PASSBY_FAR) to PASSBY_CURVE_FAST (-10.9 dB), and how
	much of the extra near the car and of the exhaust direction it gets. The steep curve on every
	car cut how far slow ones carried, and made a crawl past sound like a fly-by.
	A fast car is judged PASSBY_LEAD seconds closer than it is: at 60 m/s it's inside 5 m for a
	blink, too short for the volume glide to follow or the ear to register as loud.
	Past PASSBY_FAR the game's own falloff has taken over and the drop stays put.

	The exhaust points backward: a fast car is EXHAUST_FRONT_DB down coming at you and
	EXHAUST_REAR_DB up once it's past, so the hit lands just as the pitch drops (electric cars have
	none). Close to a fast car you also hear what the driver doesn't: car.rushAmount (0-1) brings up the
	tyre roar and wind, tuned low for the cabin, as a whoosh over RUSH_FAR to PASSBY_NEAR.

	Speed here means how fast the car goes past you: its own speed, but no more than its speed
	relative to the listener. A car keeping pace beside you isn't passing, and on its own speed it
	got the whole swell and whoosh while your own engine stayed at 1, so it drowned yours out.
	Sitting in a car, every other car is CABIN_DB down: it comes through the bodywork, yours doesn't.
	A tunnel carries sound along it, so with both you and the car inside there's no drop with range.
]]
local PASSBY_NEAR, PASSBY_REF, PASSBY_FAR = 2.5 / 0.0254, 5 / 0.0254, 30 / 0.0254   -- inches
local PASSBY_CURVE_SLOW, PASSBY_CURVE_FAST = 0.35, 0.7
local PASSBY_SLOW, PASSBY_FAST, PASSBY_PEAK, PASSBY_LEAD = 5, 30, 0.95, 0.2
local EXHAUST_FRONT_DB, EXHAUST_REAR_DB = 5, 3
local CABIN_DB = 3
local RUSH_FAR, RUSH_SLOW, RUSH_FAST, RUSH_ROAD, RUSH_WIND = 10 / 0.0254, 12, 40, 0.7, 1   -- inches; m/s; volumes
local function proximityGain(car, listenerInside, noseDirection)
	car.rushAmount = 0
	if listenerInside or not listener.valid then return 1 end
	local cabinGain = listener.inCabin and 10 ^ (-CABIN_DB / 20) or 1
	local strength = settings.passby
	if strength <= 0 then return cabinGain end
	local toEar = listener.position - car.entity:GetPos()
	local distance = toEar:Length()
	local passingSpeed = min(car.velocity:Length(), (car.velocity - listener.velocity):Length())   -- inches/s
	local passingSpeedMs = passingSpeed * 0.0254
	local judgedDistance = math.Clamp(distance - passingSpeed * PASSBY_LEAD, PASSBY_NEAR, PASSBY_FAR)
	local pace = math.Clamp((passingSpeedMs - PASSBY_SLOW) / (PASSBY_FAST - PASSBY_SLOW), 0, 1)
	local gain
	if judgedDistance > PASSBY_REF then
		gain = (PASSBY_REF / judgedDistance) ^ ((PASSBY_CURVE_SLOW + (PASSBY_CURVE_FAST - PASSBY_CURVE_SLOW) * pace) * strength
			* (1 - listener.tunnelWeight * car.tunnelWeight))
	else
		gain = 1 + ((PASSBY_REF / judgedDistance) ^ strength - 1) * pace
	end
	car.rushAmount = strength * math.Clamp((RUSH_FAR - distance) / (RUSH_FAR - PASSBY_NEAR), 0, 1) ^ 2
		* math.Clamp((passingSpeedMs - RUSH_SLOW) / (RUSH_FAST - RUSH_SLOW), 0, 1)
	if car.config.electric or distance < 1 then return gain * cabinGain end
	local aheadShare = noseDirection:Dot(toEar) / distance                     -- 1 in front of the car, -1 behind it
	local exhaustDb = -aheadShare * (aheadShare > 0 and EXHAUST_FRONT_DB or EXHAUST_REAR_DB)
	return gain * cabinGain * 10 ^ (exhaustDb * pace * strength / 20)
end

local NO_PEAKS = {}

local function updateSound(car, deltaTime)
	local bank, config, engineState, entity = car.bank, car.config, car.engineState, car.entity
	if not bank or not bank.ready then return end

	-- (rangeGain: fading out towards audio_engine_range, see updateCar)
	local masterVolume = settings.volume * (config.volume or 1) * car.rangeGain
	-- parked (engine idling, standing, no keys, not your own car): only the engine's idle plays,
	-- the extras (supercharger whine, turbo) fade out and stop
	local idleOnly = car.parked

	-- loops are muted while a start-up one-shot plays, and faded out for shut-down
	local targetLoopGain, loopGainRate = 1, 1 / 0.12
	local oneShot = car.oneShot
	if oneShot then
		local elapsed = RealTime() - oneShot.startTime
		if oneShot.kind == "start" then
			if elapsed < oneShot.fadeAt then
				if engineState.phase ~= "run" then
					targetLoopGain = 0
				else
					-- driver hit the throttle during the flare: hand over now
					oneShot.patch:FadeOut(0.12)
					car.oneShot = nil
				end
			else
				loopGainRate = 1 / max(0.05, oneShot.duration - oneShot.fadeAt)
			end
		end
		if car.oneShot and elapsed > oneShot.duration + 0.1 then
			oneShot.patch:Stop()
			car.oneShot = nil
		end
	end
	if not engineState.on then targetLoopGain, loopGainRate = 0, 1 / 0.08 end
	car.loopGain = approach(car.loopGain, targetLoopGain, loopGainRate * deltaTime)

	car.smoothedThrottle = car.smoothedThrottle + (engineState.soundThrottle - car.smoothedThrottle) * min(1, deltaTime * 12)
	-- the limiter loop only while the throttle is held against it: let go and the revs fall
	-- straight away, so the loop must too (it used to stutter on for its hold time)
	local limiterTarget = (engineState.on and engineState.phase == "run" and engineState.gear == 0 and engineState.limiterHoldTimer > 0
		and engineState.lastPedal and engineState.rpm > config.redline * 0.9) and 1 or 0
	car.limiterWeight = approach(car.limiterWeight, limiterTarget, deltaTime / (limiterTarget > car.limiterWeight and 0.06 or 0.03))

	--[[
		Headroom. Everything this car plays is summed by the game and clips (crackles) past
		full scale, so the car's own mix is kept under a ceiling: driving leaves headroom,
		revving in neutral may go a little louder. Loops are normalised to a 0.9 peak; loops
		that aren't phase-locked add up by power. The estimate is by power, but mid cross-fade
		two bands' peaks do line up now and then (up to ~1.4x the estimate on the heavily
		limited V8 / flat-4 banks), so the ceilings leave room for that: at 0.72 / 0.85 most
		engines crackled idling in neutral.
	]]
	local inNeutral = engineState.on and engineState.phase == "run" and engineState.gear == 0
	local targetCeiling = inNeutral and 0.68 or 0.66
	car.headroomCeiling = approach(car.headroomCeiling or 0.66, targetCeiling, deltaTime * 0.5)
	-- revving in neutral sits a few dB above driving (driving leaves that headroom)
	car.neutralRevGain = approach(car.neutralRevGain or 0.85, inNeutral and 1.2 or 0.85, deltaTime * 2)
	local loopVolume = masterVolume * car.loopGain * car.neutralRevGain * (config.electric and AudioEngine.EV_VOLUME or 1)
	local rpm = max(engineState.rpm, 50)
	local layers = bank.layers
	local bandCount = #layers

	-- equal-power cross-fade between the two bands around the current rpm (log spaced).
	-- The fade position follows the rpm a touch smoothed, so a quick blip doesn't swing the
	-- loop volumes from one frame to the next (the pitch still follows the exact rpm).
	local logRpm = log(rpm)
	car.crossfadeLogRpm = car.crossfadeLogRpm and (car.crossfadeLogRpm + (logRpm - car.crossfadeLogRpm) * min(1, deltaTime * 20)) or logRpm
	local crossfadeRpm = math.exp(car.crossfadeLogRpm)
	local bandWeights = car.bandWeights
	for i = 1, bandCount do bandWeights[i] = 0 end
	if crossfadeRpm <= layers[1].rpm then
		bandWeights[1] = 1
	elseif crossfadeRpm >= layers[bandCount].rpm then
		bandWeights[bandCount] = 1
	else
		for i = 1, bandCount - 1 do
			if crossfadeRpm < layers[i + 1].rpm then
				local crossfadePosition = (car.crossfadeLogRpm - log(layers[i].rpm)) / (log(layers[i + 1].rpm) - log(layers[i].rpm))
				bandWeights[i] = cos(crossfadePosition * pi / 2)
				bandWeights[i + 1] = sin(crossfadePosition * pi / 2)
				break
			end
		end
	end

	-- the rolling-noise levels are needed for the headroom estimate
	local sharedBank = Bank.env
	local roadLevel = settings.roadNoise * (config.volume or 1) * car.rangeGain
	local windLevel = settings.windNoise * (config.volume or 1) * car.rangeGain
	local roadVolume, windVolume, rollingShare = 0, 0, 0
	if sharedBank and sharedBank.ready then
		local speedKmh = abs(car.speedAlongNose) * 3.6
		rollingShare = math.Clamp((speedKmh - 3) / 120, 0, 1)
		-- the tyre roar eases back again past 60 km/h (about -5 dB from 160 km/h): pitched up and
		-- at full level it was a rushing-air hiss over the engine on fast cars
		roadVolume = roadLevel * (rollingShare ^ 1.2) * 0.7 * (1 - 0.45 * math.Clamp((speedKmh - 60) / 100, 0, 1))
		-- wind stays in the background: from 80 km/h, and well under the engine even flat out
		-- (0.06 from 60 km/h roared over the engine on fast cars)
		windVolume = windLevel * math.Clamp((speedKmh - 80) / 240, 0, 1) ^ 2 * 0.015
	end
	-- each sound's real peak (measured when it was generated); the on/off layers of a band
	-- share their firing phase so they add directly, separate sounds add by power
	local peaks = bank.peak or NO_PEAKS
	-- turbo sounds live in the shared bank (Bank.env): any engine can have them
	local turboPlaying = config.turbo and sharedBank and sharedBank.ready and sharedBank.turbo and not idleOnly
	local boost = turboPlaying and (engineState.boost or 0) or 0
	-- electric: a steady low hum at walking pace (like an EV's pedestrian warning sound), at an
	-- almost fixed pitch; it fades out between ~8% and 20% of top speed (about 15-35 km/h)
	-- while the motor whine, rising with speed, takes over
	local motorSpeedShare = rpm / config.redline
	local humVolume = 0
	if config.electric and sharedBank and sharedBank.ready and sharedBank.evhum and engineState.on and engineState.phase == "run" then
		local humFade = 1 - math.Clamp((motorSpeedShare - 0.08) / 0.12, 0, 1)
		local movingShare = math.Clamp(abs(car.speedAlongNose) / 2, 0, 1)   -- a little softer standing still
		humVolume = loopVolume * 0.3 * humFade * (0.7 + 0.3 * movingShare)
	end
	--[[
		Supercharger (sh_carlist CAR_SUPERCHARGER): belt-driven, so its whine follows the revs, not
		boost. Louder with the revs; off the throttle the bypass valve opens: the duller, quieter loop.
		The bypass is a vacuum-worked valve on the throttle plate's side, not on the fuel: at the rev
		limiter the throttle stays open, so it stays shut and the blower keeps whining on boost (fed
		the limiter's fuel cuts, the whine flipped to the bypass loop ~12 times a second). It moves
		like a valve too: shuts in ~0.15 s as the throttle opens, opens in ~0.1 s on a lift.
		On the limiter the whine holds near redline: the limiter loop is steady, and a whine
		following every cut's 150 rpm bounce beat against it.
		At speed it fades back (to SC_FAST_GAIN by SC_FADE_TO of top speed): cruising, the steady
		whine wore on the ear over the engine; revving and pulling away it's at full level.
		config.scPitch (sh_carlist SC_PITCH) moves the whine for a blower geared unlike the others.
		The whine is in octave bands (cl_synth SC_BANDS), cross-faded at equal power by the revs x
		scPitch: one loop pitched from idle to redline stepped audibly at low revs.
	]]
	local superchargerKind = config.supercharger
	local superchargerVariant = superchargerKind and Synth.SC_VARIANTS[superchargerKind]
	local superchargerNames = superchargerVariant and not config.electric and sharedBank and sharedBank.ready and superchargerBandNames(sharedBank, superchargerKind)
	local superchargerPlaying = superchargerNames and true or false
	local superchargerRpm = rpm + (config.redline * 0.985 - rpm) * car.limiterWeight
	-- the two bands around the whine's rpm and their weights
	local lowerBand, lowerBandWeight, upperBandWeight = 1, 1, 0
	local whineRpm = (config.scPitch or 1) * superchargerRpm
	local whineBands = Synth.SC_BANDS
	if not superchargerPlaying then
		-- no whine: nothing to weigh
	elseif whineRpm >= whineBands[#whineBands] then
		lowerBand = #whineBands
	elseif whineRpm > whineBands[1] then
		for bandIndex = 1, #whineBands - 1 do
			if whineRpm < whineBands[bandIndex + 1] then
				local crossfadePosition = log(whineRpm / whineBands[bandIndex]) / log(whineBands[bandIndex + 1] / whineBands[bandIndex])
				lowerBand, lowerBandWeight, upperBandWeight = bandIndex, cos(crossfadePosition * pi / 2), sin(crossfadePosition * pi / 2)
				break
			end
		end
	end
	local superchargerVolume = 0
	if superchargerPlaying and engineState.on and not idleOnly then
		local topSpeedShare = abs(car.speedAlongNose) * 3.6 / max(config.topSpeed or 250, 30)
		local fastFade = math.Clamp((topSpeedShare - SC_FADE_FROM) / (SC_FADE_TO - SC_FADE_FROM), 0, 1)
		superchargerVolume = loopVolume * SC_GAIN * superchargerVariant.level * min(1, superchargerRpm / config.redline) ^ 0.9 * (1 - (1 - SC_FAST_GAIN) * fastFade)
	end
	local bypassTarget = max(engineState.soundThrottle, engineState.fuelCut and engineState.throttle or 0)
	car.superchargerThrottle = approach(car.superchargerThrottle or 0, bypassTarget, deltaTime / (bypassTarget > (car.superchargerThrottle or 0) and 0.15 or 0.1))
	local superchargerThrottle = car.superchargerThrottle
	local smoothedThrottle = car.smoothedThrottle
	local estimatedPowerSum = (car.limiterWeight * loopVolume * (peaks[bank.limiter.off] or 0.9)) ^ 2
		+ (superchargerPlaying and superchargerVolume * (superchargerThrottle * (sharedBank.peak[superchargerNames[lowerBand][1]] or 0.3)
			+ (1 - superchargerThrottle) * 0.5 * (sharedBank.peak[superchargerNames[lowerBand][2]] or 0.3)) or 0) ^ 2
		+ (humVolume * (sharedBank and sharedBank.peak and sharedBank.peak.evhum or 0.3)) ^ 2
		+ (turboPlaying and (loopVolume * boost ^ 1.5 * 0.5 * (config.profile.turboVol or 1) * (sharedBank.peak.turbo or 0.9)) or 0) ^ 2
		+ (sharedBank and (roadVolume * (sharedBank.peak and sharedBank.peak.road or 0.3)) or 0) ^ 2
		+ (sharedBank and (windVolume * (sharedBank.peak and sharedBank.peak.wind or 0.3)) or 0) ^ 2
	for i = 1, bandCount do
		local layer, bandVolume = layers[i], (bandWeights[i] or 0) * (1 - car.limiterWeight) * loopVolume
		if bandVolume > 0 then
			estimatedPowerSum = estimatedPowerSum + (bandVolume * (smoothedThrottle * (peaks[layer.on] or 0.9) + (1 - smoothedThrottle) * (peaks[layer.off] or 0.9))) ^ 2
		end
	end
	local estimatedPeak = math.sqrt(estimatedPowerSum)
	local headroomTarget = estimatedPeak > car.headroomCeiling and car.headroomCeiling / estimatedPeak or 1
	-- pull down quickly, recover slowly
	if headroomTarget < car.headroomGain then car.headroomGain = car.headroomGain + (headroomTarget - car.headroomGain) * min(1, deltaTime * 30)
	else car.headroomGain = car.headroomGain + (headroomTarget - car.headroomGain) * min(1, deltaTime * 3) end
	car.popPeakLoad = (car.popPeakLoad or 0) * math.exp(-deltaTime / 0.08)
	-- the pass-by swell goes on after the headroom, so a car pinned at its ceiling still swells
	local passbyGain = car.passbyGain or 1
	if passbyGain > 1 then
		passbyGain = max(1, min(passbyGain, PASSBY_PEAK / max(estimatedPeak * car.headroomGain, 0.01)))
		car.passbyGain = passbyGain
	end
	car.mixPeak = estimatedPeak * car.headroomGain * passbyGain
	loopVolume = loopVolume * car.headroomGain * passbyGain
	roadVolume, windVolume, humVolume = roadVolume * car.headroomGain * passbyGain, windVolume * car.headroomGain * passbyGain, humVolume * car.headroomGain * passbyGain
	-- after the headroom: the whoosh shouldn't pull the engine down just as it peaks
	local rushAmount = car.rushAmount or 0
	roadVolume, windVolume = roadVolume + roadLevel * rushAmount * RUSH_ROAD, windVolume + windLevel * rushAmount * RUSH_WIND

	local throttle = car.smoothedThrottle
	local pitchScale = car.detune * (car.dopplerRatio or 1)
	for i = 1, bandCount do
		local layer = layers[i]
		local bandVolume = (bandWeights[i] or 0) * (1 - car.limiterWeight) * loopVolume
		-- (bands out of the cross-fade and silent: nothing to do)
		if bandVolume > 0 or car.activeGroups[i] then
			local pitch = math.Clamp(100 * pitchScale * rpm / layer.rpm, 5, 250)
			local trim = layer.trim or 1
			setGroup(car, i, namePairOf(layer), volumeList(car, i, bandVolume * throttle * trim, bandVolume * (1 - throttle) * trim), pitch, deltaTime)
		end
	end
	-- a family bank (or the stock fallback) may be rendered at another redline: pitch it to ours
	if car.limiterWeight > 0 or car.activeGroups.lim then
		local limiterPitch = math.Clamp(100 * pitchScale * config.redline / (bank.limiter.rpm or config.redline), 5, 250)
		setGroup(car, "lim", singleNameList(bank.limiter.off), volumeList(car, "lim", car.limiterWeight * loopVolume), limiterPitch, deltaTime)
	end

	-- turbos: the whistle rises with boost, the blow-off valve sighs when the throttle shuts
	if turboPlaying then
		local pitch = math.Clamp(100 * pitchScale * (0.45 + 0.55 * boost) * (0.9 + 0.2 * rpm / config.redline), 20, 220)
		-- the turbo sounds are generated 6 dB hot: half volume is the default level, so the
		-- profile's turbo and blow-off volumes can go to 200%
		local turboVolume = config.profile.turboVol or 1
		setGroup(car, "turbo", singleNameList(sharedBank.turbo), volumeList(car, "turbo", loopVolume * boost ^ 1.5 * 0.5 * turboVolume), pitch, deltaTime)
		local blowOffVolume = config.profile.bovVol or 1
		if engineState.blowOffEvent and config.profile.bov and blowOffVolume > 0 and #sharedBank.blowoff > 0 then
			local name = sharedBank.blowoff[math.random(#sharedBank.blowoff)]
			local volume = loopVolume * math.min(1, engineState.blowOffEvent * 1.2) * 0.5 * blowOffVolume
			-- headroom, like the pops
			local peak = sharedBank.peak[name] or 0.98
			volume = min(1, volume, max(0.05, 0.98 - (car.mixPeak or 0) - (car.popPeakLoad or 0)) / max(peak, 0.05))
			car.popPeakLoad = (car.popPeakLoad or 0) + volume * peak
			getPatch(car, name):Stop()
			startPatch(car, name, volume, math.Clamp(math.random(95, 105) * (car.dopplerRatio or 1), 20, 255))
		end
	elseif car.activeGroups.turbo then
		-- turbo switched off in the menu, or the car parked: fade the whistle out
		setGroup(car, "turbo", singleNameList(sharedBank.turbo), volumeList(car, "turbo", 0), 100, deltaTime)
	end
	if superchargerPlaying then
		superchargerVolume = superchargerVolume * car.headroomGain * (car.passbyGain or 1)
		for bandIndex = 1, #whineBands do
			local bandWeight = (bandIndex == lowerBand and lowerBandWeight) or (bandIndex == lowerBand + 1 and upperBandWeight) or 0
			local groupKey = SUPERCHARGER_GROUP_KEYS[bandIndex]
			if bandWeight > 0 or car.activeGroups[groupKey] then
				local pitch = math.Clamp(100 * pitchScale * whineRpm / whineBands[bandIndex], 5, 255)
				local onVolume = superchargerVolume * bandWeight * superchargerThrottle
				local bypassVolume = superchargerVolume * bandWeight * 0.5 * (1 - superchargerThrottle)
				setGroup(car, groupKey, superchargerNames[bandIndex], volumeList(car, groupKey, onVolume, bypassVolume), pitch, deltaTime)
			end
		end
	end
	if humVolume > 0 or car.activeGroups.evhum then
		local pitch = math.Clamp(100 * (car.dopplerRatio or 1) * (1 + 0.12 * math.Clamp(motorSpeedShare / 0.2, 0, 1)), 20, 220)
		setGroup(car, "evhum", singleNameList(sharedBank.evhum), volumeList(car, "evhum", humVolume), pitch, deltaTime)
	end

	--[[
		Pops & bangs: profile "pops" = how often (0 = off), "popVolume" = how loud (1 = default).
		Timed like a real overrun: lifting off high in the revs starts a burble a moment later (the
		fuel has to reach the hot exhaust), pops in uneven clusters, thick at first and thinning out
		as the revs fall and the seconds pass; back on the throttle ends it. A long coast only pops
		now and then. (A per-frame chance spread lone pops evenly over every coast: popcorn.)
		The big events (a bang to open the burble, upshift crack, limiter) go with P squared: a Rare
		or Occasional car crackles now and then, only a Frequent one bangs on most lifts.
	]]
	local popFrequency = config.profile.pops or 0
	-- 0.7: about 3 dB over the 0.5 they were baked for (they came out a little too quiet)
	local popVolume = masterVolume * car.loopGain * 0.7 * (config.profile.popVol or 1) * (car.passbyGain or 1)
	if popFrequency > 0 and popVolume > 0 and #bank.pops > 0 and engineState.on and engineState.phase == "run" then
		local redline, now = config.redline, RealTime()
		local bigEventChance = popFrequency * popFrequency
		local overrun = engineState.soundThrottle < 0.04 and engineState.rpm > redline * 0.35 and not engineState.fuelCut
		-- lift-off high in the revs: a burble starts, longer the higher the revs and the more it pops
		if (car.lastThrottle or 0) > 0.8 and engineState.throttle < 0.5 and engineState.rpm > redline * 0.5 then
			local highRevShare = math.Clamp((engineState.rpm / redline - 0.5) / 0.4, 0, 1)
			car.burbleStart = now
			car.burbleDuration = (0.8 + 2.2 * popFrequency) * (0.5 + 0.5 * highRevShare)
			car.nextPopTime = now + 0.12 + 0.18 * math.random()
			car.burbleOpensWithBang = math.random() < bigEventChance * (0.4 + 0.6 * highRevShare)
		end
		if engineState.soundThrottle > 0.3 then car.nextPopTime = nil end    -- back on the throttle
		if overrun and car.nextPopTime and now >= car.nextPopTime then
			local burbleAge = (now - car.burbleStart) / car.burbleDuration
			local burbleIntensity = (burbleAge < 1 and (1 - burbleAge) ^ 1.5 or 0) * math.Clamp((engineState.rpm / redline - 0.35) / 0.5, 0, 1)
			if burbleIntensity > 0.03 then
				if car.burbleOpensWithBang then
					playPop(car, popVolume * (0.8 + 0.2 * math.random()), true)
					car.burbleOpensWithBang = false
				else
					playPop(car, popVolume * (0.5 + 0.5 * burbleIntensity) * (0.75 + 0.25 * math.random()), false)
				end
				-- a quick follow-up (a cluster), or a pause that grows as the burble dies away
				if math.random() < 0.25 + 0.3 * burbleIntensity then
					car.nextPopTime = now + 0.05 + 0.08 * math.random()
				else
					car.nextPopTime = now + (0.15 + 0.5 * math.random()) / (0.3 + 1.5 * burbleIntensity * popFrequency)
				end
			else
				car.nextPopTime = nil
			end
		end
		-- a long coast at high revs: an odd pop now and then
		if overrun and not car.nextPopTime and engineState.rpm > redline * 0.55 and math.random() < bigEventChance * 0.25 * deltaTime then
			playPop(car, popVolume * (0.4 + 0.3 * math.random()), false)
		end
		-- upshift crack, flat out high in the revs
		if engineState.gear > (car.lastGear or 0) and (car.lastGear or 0) > 0 and engineState.shiftDirection == 1 and engineState.throttle > 0.8
			and (car.lastRpm or 0) > redline * 0.75 and math.random() < bigEventChance * 0.6 then
			playPop(car, popVolume * 0.8, popFrequency > 0.7 and math.random() < 0.3)
		end
		-- limiter
		if engineState.limiterEvent and math.random() < bigEventChance then
			playPop(car, popVolume * 0.8, popFrequency > 0.7 and math.random() < 0.25)
		end
	end
	car.lastRpm = engineState.rpm
	car.lastThrottle = engineState.throttle
	car.lastGear = engineState.gear

	-- rolling noise: tyre roar grows with speed, wind takes over on the motorway.
	-- It doesn't depend on the engine running (a coasting car still roars).
	if sharedBank and sharedBank.ready then
		local dopplerRatio = car.dopplerRatio or 1
		if roadVolume > 0 or car.activeGroups.road then
			setGroup(car, "road", singleNameList(sharedBank.road), volumeList(car, "road", roadVolume), math.Clamp((75 + 30 * rollingShare) * dopplerRatio, 20, 255), deltaTime)
		end
		if windVolume > 0 or car.activeGroups.wind then
			setGroup(car, "wind", singleNameList(sharedBank.wind), volumeList(car, "wind", windVolume), math.Clamp((85 + 35 * rollingShare) * dopplerRatio, 20, 255), deltaTime)
		end
	end
end

--[[
	The vehicle_guage pose, set right before the car is drawn. The server sets it too (Source's
	speedometer) and networks it, and the client re-interpolates that value every frame after
	Think, so a value set in Think only showed now and then: the Murcielago's vents flickered
	open and shut wherever Source's value crossed their range. Keeps any existing override.
]]
local function guageOverride(entity)
	if entity.audioGaugeOverrideInstalled then return end
	entity.audioGaugeOverrideInstalled = true
	local previousOverride = entity.RenderOverride
	entity.RenderOverride = function(self, flags)
		if self.audioGaugePose then
			self:SetPoseParameter("vehicle_guage", self.audioGaugePose)
			self:InvalidateBoneCache()
		end
		if previousOverride then previousOverride(self, flags) else self:DrawModel(flags) end
	end
end

--[[
	Tunnels. A spot is in a tunnel when it has a roof, walls close on two opposite sides, and a long
	open run the other way: traced against the map only, so cars and props don't count. An overpass
	has no walls, a street no roof, and a room no long run.
	A car in one, or any car while you stand in one, gets a Source reverb (DSP preset
	audio_engine_tunnel, picked by ear), and a car in one
	carries TUNNEL_LEVEL dB further. Neither is known to reach a sound already playing, so loops are
	restarted when the room changes (setGroup).
	All of this is for people outside a car: sitting in one, cars sound as they do anywhere else.
]]
local TUNNEL_ROOF, TUNNEL_REACH = 25 / 0.0254, 50 / 0.0254   -- inches
local TUNNEL_WIDE, TUNNEL_LONG, TUNNEL_RATIO = 30 / 0.0254, 30 / 0.0254, 2.5
local TUNNEL_LEVEL, TUNNEL_FADE = 8, 0.6                     -- dB; s
local TUNNEL_UP, TUNNEL_CAR_HEIGHT = Vector(0, 0, 1), Vector(0, 0, 60)
local TUNNEL_AXES = {}
for i = 0, 7 do TUNNEL_AXES[i + 1] = Vector(cos(i * pi / 8), sin(i * pi / 8), 0) end

local tunnelTrace = { mask = MASK_SOLID_BRUSHONLY }
local function openDistance(position, direction, maxDistance)
	tunnelTrace.start, tunnelTrace.endpos = position, position + direction * maxDistance
	local trace = util.TraceLine(tunnelTrace)
	if not trace.Hit or trace.HitSky then return maxDistance end
	return maxDistance * trace.Fraction
end

local function isTunnelAt(position)
	if openDistance(position, TUNNEL_UP, TUNNEL_ROOF) >= TUNNEL_ROOF then return false end
	local narrowestSpan, longestSpan = math.huge, 0
	for _, axis in ipairs(TUNNEL_AXES) do
		local span = openDistance(position, axis, TUNNEL_REACH) + openDistance(position, -axis, TUNNEL_REACH)
		narrowestSpan, longestSpan = min(narrowestSpan, span), max(longestSpan, span)
	end
	return narrowestSpan <= TUNNEL_WIDE and longestSpan >= max(TUNNEL_LONG, narrowestSpan * TUNNEL_RATIO)
end

-- the listener a few times a second, the cars one per frame. A car that hasn't moved TUNNEL_MOVED
-- since its last probe keeps its answer (parked cars): no traces
local TUNNEL_MOVED = 1 / 0.0254   -- inches
local nextListenerProbe, probedEntity = 0, nil
local function probeTunnels(deltaTime)
	local tunnelsOn = settings.tunnel > 0
	local now = RealTime()
	if now >= nextListenerProbe and listener.valid then
		nextListenerProbe = now + 0.25
		listener.inTunnel = tunnelsOn and not listener.inCabin and isTunnelAt(listener.position)
	end
	listener.tunnelWeight = approach(listener.tunnelWeight, listener.inTunnel and 1 or 0, deltaTime / TUNNEL_FADE)
	if probedEntity and not cars[probedEntity] then probedEntity = nil end
	probedEntity = next(cars, probedEntity)
	local car = probedEntity and cars[probedEntity]
	if car and not car.dormant then
		if not tunnelsOn then
			car.inTunnel, car.tunnelProbePosition = false, nil
		else
			local position = probedEntity:GetPos()
			if not car.tunnelProbePosition or position:DistToSqr(car.tunnelProbePosition) > TUNNEL_MOVED * TUNNEL_MOVED then
				car.tunnelProbePosition = position
				car.inTunnel = isTunnelAt(position + TUNNEL_CAR_HEIGHT)
			end
		end
	end
end

local function updateRoom(car, deltaTime)
	car.tunnelWeight = approach(car.tunnelWeight, car.inTunnel and 1 or 0, deltaTime / TUNNEL_FADE)
	local listenerOutside = not listener.inCabin
	local dspPreset = listenerOutside and max(car.tunnelWeight, listener.tunnelWeight) > 0.5 and settings.tunnel or 0
	local soundLevel = (car.config.soundLevel or 85) + (listenerOutside and car.tunnelWeight > 0.5 and TUNNEL_LEVEL or 0)
	if dspPreset ~= car.dspPreset or soundLevel ~= car.currentSoundLevel then
		car.dspPreset, car.currentSoundLevel, car.roomGeneration = dspPreset, soundLevel, car.roomGeneration + 1
	end
end

--[[
	The car's speed, from position change (works for every car, not just our own). Measured over
	real time, at least SPEED_SAMPLE apart: a frame's dt is capped, so a stutter read as several
	times the real speed, and the revs and the gearbox jumped with it. A freeze over SPEED_GAP
	says nothing about the speed, so it's held. The median of three samples drops a lone bad one
	(a network stall reads as zero, then double), and flatSpeed leaves out motion along the car's own
	up axis, so a kerb or a seam kicking the car up doesn't count as speed.
]]
local SPEED_SAMPLE, SPEED_GAP, SPEED_SLEW = 0.05, 0.3, 40   -- s; s; m/s per second the gearbox's speed may change

local function median(samples, value)
	samples[1], samples[2], samples[3] = samples[2], samples[3], value
	return max(min(samples[1], samples[2]), min(max(samples[1], samples[2]), samples[3]))
end

local function sampleSpeed(car, noseDirection)
	local now = RealTime()
	local elapsed = now - car.sampleTime
	if elapsed < SPEED_SAMPLE then return end
	local position = car.entity:GetPos()
	local measuredVelocity = (position - car.samplePosition) / elapsed                  -- inches/s
	car.samplePosition, car.sampleTime = position, now
	if elapsed > SPEED_GAP or measuredVelocity:Length() * 0.0254 > 150 then return end   -- (over 150 m/s: teleported)
	car.velocity = car.velocity + (measuredVelocity - car.velocity) * min(1, elapsed * 8)
	local upDirection = car.entity:GetUp()
	car.measuredSpeedAlongNose = median(car.speedAlongNoseSamples, measuredVelocity:Dot(noseDirection) * 0.0254)
	car.flatSpeed = median(car.flatSpeedSamples, (measuredVelocity - upDirection * measuredVelocity:Dot(upDirection)):Length() * 0.0254)
end

--[[
	Range (audio_engine_range, metres, for an ordinary 85 dB car): past it a car's sounds stop, and
	they fade out over the last RANGE_FADE share so the edge isn't heard. Its rpm model keeps
	running, so it comes back in step. Source's falloff goes with distance x the sound level's
	attenuation (20 / (level - 50)), so a louder car (92 dB, a tunnel's +8) reaches the same level
	further out and gets a longer range. Back inside RANGE_BACK of it the sounds start again.
]]
local RANGE_FADE, RANGE_BACK = 0.25, 0.95
-- the sound budget (rankCars, below): looked at every BUDGET_EVERY s, a car past it fades over BUDGET_FADE s
-- and comes back once it's BUDGET_MARGIN places inside it
local BUDGET_EVERY, BUDGET_FADE, BUDGET_MARGIN = 0.25, 0.5, 2
local function audibleRangeOf(car)
	if settings.range <= 0 then return nil end
	return settings.range / 0.0254 * ((car.currentSoundLevel or car.config.soundLevel or 85) - 50) / 35
end

--[[
	Cars that need little are looked at less than every frame (the Think hook below):
	  asleep   engine off, standing, nothing playing: SLEEP_STEP
	  parked   engine idling, standing, no keys pressed, not your car: only its idle plays (the
	           supercharger whine and turbo fade out, see updateSound); while the listener moves
	           slower than PARKED_LISTENER_SPEED (Doppler and the pass-by swell barely change) every PARKED_STEP,
	           the volume and pitch gliding over that time (car.changeFadeTime)
	Anything that changes (dormancy, ignition, a key) wakes them on the frame it happens (wakes()).
]]
local SLEEP_STEP, PARKED_STEP = 0.25, 0.1
local DRIVETRAIN_SLICE = 0.02           -- s: the rpm model's longest step
local PARKED_LISTENER_SPEED = 6 / 0.0254   -- inches/s
local STANDING_SPEED = 0.3               -- m/s

local function anyActive(car)
	for _, isActive in pairs(car.activeGroups) do
		if isActive then return true end
	end
	return false
end

local function updateRestState(car, isOwnCar, keysHeld)
	local engineState = car.engineState
	car.parked, car.restState, car.nextUpdateTime, car.changeFadeTime = false, nil, nil, 0
	if isOwnCar or abs(car.driveSpeed or 0) > STANDING_SPEED or car.flatSpeed > STANDING_SPEED or car.wingMoving then return end
	if not engineState.on then
		if engineState.rpm <= 0 and not car.oneShot and not anyActive(car) then
			car.restState, car.nextUpdateTime = "asleep", RealTime() + SLEEP_STEP
		end
	-- (in any gear: a car driven and stopped stays in D, idling the same)
	elseif engineState.phase == "run" and not keysHeld and car.limiterWeight <= 0 and engineState.rpm < car.config.idle * 1.15 then
		car.parked, car.restState = true, "parked"
		if listener.velocity:Length() < PARKED_LISTENER_SPEED then
			car.nextUpdateTime, car.changeFadeTime = RealTime() + PARKED_STEP, PARKED_STEP
		end
	end
end

local function updateCar(car, deltaTime)
	local entity, engineState = car.entity, car.engineState

	if entity:IsDormant() then
		if not car.dormant then stopAll(car); car.dormant = true end
		car.samplePosition, car.sampleTime, car.wingPose = entity:GetPos(), RealTime(), nil
		car.restState, car.nextUpdateTime, car.parked = "dormant", RealTime() + SLEEP_STEP, false
		return
	end
	if car.dormant then
		-- back in view, maybe somewhere else: the next speed sample starts from here
		car.samplePosition, car.sampleTime = entity:GetPos(), RealTime()
		car.dormant = false
	end

	-- follow the car's engine profile (retuned in game); its sounds are generated on demand,
	-- the old engine keeps playing until the new one is ready
	local config = AudioEngine.GetEngineConfig(entity) or car.config
	car.config = config
	local player = LocalPlayer()
	local isOwnCar = IsValid(player) and player:GetVehicle() == entity
	local bank = Bank.Get(config, car.stockConfig, isOwnCar)
	if bank ~= car.bank and bank.ready then
		stopAll(car)
		car.bank = bank
	end

	-- out of range: silent (see audibleRangeOf)
	local audibleRange = not isOwnCar and listener.valid and audibleRangeOf(car)
	if audibleRange then
		local distance = listener.position:Distance(entity:GetPos())
		car.rangeGain = math.Clamp((audibleRange - distance) / (audibleRange * RANGE_FADE), 0, 1)
		car.outOfRange = distance > audibleRange or (car.outOfRange and distance > audibleRange * RANGE_BACK) or false
	else
		car.rangeGain, car.outOfRange = 1, false
	end
	-- past the nearest audio_engine_maxcars: fades out, then silent like a car out of range (see rankCars)
	car.budgetGain = approach(car.budgetGain or 1, car.overBudget and not isOwnCar and 0 or 1, deltaTime / BUDGET_FADE)
	car.rangeGain = car.rangeGain * car.budgetGain
	car.outOfRange = car.outOfRange or car.budgetGain <= 0
	if car.outOfRange and not car.silencedByRange then stopAll(car) end
	car.silencedByRange = car.outOfRange

	-- engine switched on / off by the server
	local engineOn = entity:GetNW2Bool("audio_on", false)
	if engineOn ~= car.lastEngineOn then
		local oneShotVolume = settings.volume * (config.volume or 1) * (car.passbyGain or 1) * car.rangeGain
		if engineOn then
			local sinceStarted = CurTime() - entity:GetNW2Float("audio_on_t", 0)
			if car.firstUpdate or sinceStarted > 2 then
				Drivetrain.SkipStart(engineState, config)
				car.loopGain = 1
			else
				Drivetrain.Start(engineState, entity:GetNW2Bool("audio_emo", false))
				car.loopGain = 0
				if car.bank and car.bank.ready and not car.outOfRange then
					local startSound = engineState.emotion and car.bank.startEmo or car.bank.start
					playOneShot(car, "start", startSound.name, oneShotVolume, 100, startSound.fadeAt, startSound.dur)
				end
			end
		else
			if not car.firstUpdate and engineState.rpm > 100 and car.bank and car.bank.ready and not car.outOfRange then
				local pitch = math.Clamp(100 * engineState.rpm / config.idle, 70, 160)
				playOneShot(car, "stop", car.bank.stop.name, oneShotVolume, pitch, 0, car.bank.stop.dur)
			end
			Drivetrain.Stop(engineState)
			if car.firstUpdate then engineState.rpm = 0 end
		end
		car.lastEngineOn = engineOn
	end
	car.firstUpdate = false

	-- speed along the nose
	local noseDirection = car.worldNoseDirection or Vector()
	car.worldNoseDirection = noseDirection
	noseDirection:Set(localForward(car))
	noseDirection:Rotate(entity:GetAngles())
	sampleSpeed(car, noseDirection)
	car.speedAlongNose = car.speedAlongNose + (car.measuredSpeedAlongNose - car.speedAlongNose) * min(1, deltaTime * 10)
	-- driving it but watching from a camera, you hear it from outside like anyone else
	local listenerInside = isOwnCar and GetViewEntity() == player
	dopplerFactor(car, deltaTime, listenerInside)
	car.passbyGain = proximityGain(car, listenerInside, noseDirection)

	-- the gearbox follows the wheels, and in a slide they still roll at the car's full speed: the
	-- speed along the nose collapsed as the car went sideways, the revs plunged and shot back up
	-- as it straightened (a cartoon "weee-ooo"). Full speed, signed by the nose, unless it has
	-- turned mostly backwards or sideways (a spin)
	local flatSpeed = car.flatSpeed
	local driveSpeed = car.speedAlongNose
	if flatSpeed > 2 and abs(car.speedAlongNose) > flatSpeed * 0.3 then driveSpeed = (car.speedAlongNose >= 0 and 1 or -1) * flatSpeed end
	-- no car really changes speed faster than SPEED_SLEW: what's left of a bump stops here
	car.driveSpeed = car.driveSpeed and approach(car.driveSpeed, car.driveSpeed + (driveSpeed - car.driveSpeed) * min(1, deltaTime * 10), deltaTime * SPEED_SLEW) or driveSpeed

	local forwardHeld, backwardHeld, handbrakeHeld, steeringHeld, holdingSpeedLimit = readInputs(car)
	local controls = car.controls or {}
	car.controls = controls
	controls.forward = forwardHeld
	controls.backward = backwardHeld
	controls.handbrake = handbrakeHeld
	controls.steering = steeringHeld
	controls.speed = car.driveSpeed
	controls.holdingSpeedLimit = holdingSpeedLimit
	-- a resting car's longer step goes in slices of at most DRIVETRAIN_SLICE: in one step the idle control
	-- overshot (the revs swung 640-760 at 0.1 s steps). A frame's step (up to 0.05 s) is left whole,
	-- as it always was. (Each step clears its events: one from any slice counts)
	local sliceCount = deltaTime > 0.05 and math.ceil(deltaTime / DRIVETRAIN_SLICE - 1e-6) or 1
	if sliceCount <= 1 then
		Drivetrain.Step(engineState, config, deltaTime, controls)
	else
		local limiterEvent, blowOffEvent = false, nil
		for _ = 1, sliceCount do
			Drivetrain.Step(engineState, config, deltaTime / sliceCount, controls)
			limiterEvent, blowOffEvent = limiterEvent or engineState.limiterEvent, blowOffEvent or engineState.blowOffEvent
		end
		engineState.limiterEvent, engineState.blowOffEvent = limiterEvent, blowOffEvent
	end

	updateRoom(car, deltaTime)
	local now = RealTime()
	car.reviveCheckDue = now >= car.nextReviveCheck
	if car.reviveCheckDue then car.nextReviveCheck = now + 1 end
	if not car.outOfRange then updateSound(car, deltaTime) end

	-- the model's own dashboard tach needle follows the revs. Cars whose wings/vents also hang off
	-- that pose (AudioEngine.GAUGE_PARTS) follow the position the server picks from speed (sv_engine.lua)
	-- instead, glided here so they move smoothly between its updates
	if config.gaugeParts then
		local targetWingPose = entity:GetNW2Float("audio_wing", config.gaugeParts[1])
		car.wingPose = car.wingPose and approach(car.wingPose, targetWingPose, deltaTime * AudioEngine.WING_RATE) or targetWingPose
		car.wingMoving = car.wingPose ~= targetWingPose
		entity.audioGaugePose = car.wingPose
	else
		local gaugeMaxRpm = math.ceil((config.redline + 500) / 1000) * 1000
		entity.audioGaugePose = math.Clamp(engineState.rpm / gaugeMaxRpm, 0, 1)
	end
	guageOverride(entity)

	updateRestState(car, isOwnCar, forwardHeld or backwardHeld or handbrakeHeld or steeringHeld)
	if car.outOfRange then car.restState = "far" end   -- (for audio_engine_perf_snapshot)
end

-- something a resting car must hear about now, not at its next look
local function needsUpdateNow(car, entity)
	return entity:IsDormant() ~= (car.dormant or false)
		or entity:GetNW2Bool("audio_on", false) ~= car.lastEngineOn
		or entity:GetNW2Int("audio_in", 0) ~= 0
end

--[[
	The sound budget. The game mixes only so many sounds at once for everything (a few hundred
	channels, the siren's and the game's own included), and a car holds several loops: ~6 driving,
	up to ~16 for a moment while its revs sweep through the bands. 40 cars setting off together
	asked for far more than that, and sirens and the game's own sounds went missing. So only the
	nearest audio_engine_maxcars cars with something to play are heard; one further out fades over
	BUDGET_FADE and goes silent until it's among the nearest again (BUDGET_MARGIN places of slack, so
	two cars at the edge don't take turns). In a crowd that big the far ones are drowned out anyway.
]]
local nextBudget = 0
local ranked = {}

local function rankCars()
	if settings.maxCars <= 0 or not listener.valid then
		for _, car in pairs(cars) do car.overBudget = false end
		return
	end
	table.Empty(ranked)
	for entity, car in pairs(cars) do
		-- (asleep and dormant cars play nothing: they don't take a place)
		if IsValid(entity) and not car.dormant and (car.engineState.on or anyActive(car)) then
			car.budgetDistance = listener.position:DistToSqr(entity:GetPos())
			ranked[#ranked + 1] = car
		else
			car.overBudget = false
		end
	end
	table.sort(ranked, function(first, second) return first.budgetDistance < second.budgetDistance end)
	for rank, car in ipairs(ranked) do
		if car.overBudget then
			car.overBudget = rank > settings.maxCars - BUDGET_MARGIN
		else
			car.overBudget = rank > settings.maxCars
		end
	end
end

---------------------------------------------------------------------------
-- tracking
---------------------------------------------------------------------------
local nextVehicleScan = 0
hook.Add("Think", "audio_engine_cars", function()
	local now = RealTime()
	if now >= nextVehicleScan then
		nextVehicleScan = now + 0.5
		for _, entity in ipairs(ents.FindByClass("prop_vehicle_jeep*")) do
			if not cars[entity] then
				local carConfig = AudioEngine.GetCarConfig(entity)
				if carConfig then cars[entity] = newCar(entity, carConfig) end
			end
		end
	end

	local deltaTime = min(FrameTime(), 0.05)
	if deltaTime > 0 then
		readSettings()
		updateListener(deltaTime)
	end
	if now >= nextBudget then
		nextBudget = now + BUDGET_EVERY
		rankCars()
	end
	-- AudioEngine.PerfCar(ent, seconds): set only while the debug module's profiler runs (audio_engine_perf)
	local perfCallback = AudioEngine.PerfCar
	for entity, car in pairs(cars) do
		if not IsValid(entity) then
			stopAll(car)
			cars[entity] = nil
		elseif deltaTime > 0 and (not car.nextUpdateTime or now >= car.nextUpdateTime or needsUpdateNow(car, entity)) then
			-- a resting car (rest()) is stepped over the time since its last look
			local stepTime = car.nextUpdateTime and car.lastUpdateTime and math.Clamp(now - car.lastUpdateTime, deltaTime, SLEEP_STEP) or deltaTime
			car.lastUpdateTime = now
			if perfCallback then
				local startTime = SysTime()
				updateCar(car, stepTime)
				perfCallback(entity, SysTime() - startTime)
			else
				updateCar(car, stepTime)
			end
		end
	end
	if deltaTime > 0 then probeTunnels(deltaTime) end
end)

-- the start key, read here and sent as a console command: the server's PlayerButtonDown rides on
-- the usercmds, so now and then a press never reached it and the car stayed off
local startKeyHeld = false
hook.Add("Think", "audio_engine_startkey", function()
	local keyCode = _G["KEY_" .. string.upper(startKeyConVar:GetString())]
	local isDown = keyCode ~= nil and input.IsKeyDown(keyCode)
	local pressed = isDown and not startKeyHeld
	startKeyHeld = isDown
	if not pressed then return end
	local player = LocalPlayer()
	if not IsValid(player) or not IsValid(player:GetVehicle()) or player:IsTyping() then return end
	if gui.IsGameUIVisible() or IsValid(vgui.GetKeyboardFocus()) then return end
	RunConsoleCommand("audio_engine_toggle")
end)

hook.Add("EntityRemoved", "audio_engine_cars", function(entity)
	local car = cars[entity]
	if car then
		stopAll(car)
		cars[entity] = nil
	end
end)

-- for the HUD
function AudioEngine.GetClientCar(entity)
	return cars[entity]
end
