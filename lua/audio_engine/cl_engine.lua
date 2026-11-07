--[[
	Audio Engine - per-car engine sound (client)

	Each client runs the rpm/gear model for every registered car near it (from the car's speed and
	the driver's keys, which the server networks) and plays the generated loops:
	  * two neighbouring rpm bands at a time, pitched to the exact rpm and cross-faded
	  * on/off throttle layers of a band cross-faded by throttle (they share firing phase)
	  * a rev-limiter loop, start-up / shut-down one-shots and overrun pops

	A native Source car plays one sound and costs no Lua; a car here plays up to ten loops and
	runs Lua. With 40 cars around that would run the game out of sound channels and frame time, so
	not every car gets all of it (see rankCars): full detail for the car you're in and the nearest
	few, one loop for the next ones, silence past that.
]]

local E = PerpAudioEngine
local DT = E.Drivetrain
local Bank = E.Bank

local cvVol = CreateClientConVar("audio_engine_volume", "1", true, false, "Engine sound volume (0-2)", 0, 2)
-- the key that switches the engine on and off, e.g. i, k, f1, or none
local cvStartKey = CreateClientConVar(
	"audio_engine_startkey",
	"i",
	true,
	false,
	"Key that starts/stops the engine of the car you drive (a key name such as i, k or f1; none = off)"
)
local cvRoad = CreateClientConVar("audio_engine_roadnoise", "1", true, false, "Tyre roar volume (0-2)", 0, 2)
local cvWind = CreateClientConVar("audio_engine_windnoise", "1", true, false, "Wind noise volume (0-2)", 0, 2)
local cvDoppler = CreateClientConVar(
	"audio_engine_doppler",
	"0.25",
	true,
	false,
	"Doppler pitch shift of passing cars (0 = off, 0.25 = default, real, 1 = four times real)",
	0,
	1
)
-- the default was 1 and clients saved it, so a new default alone wouldn't reach them: moved over
-- once, leaving any other value someone picked
if cookie.GetNumber("audio_engine_doppler_moved", 0) == 0 then
	cookie.Set("audio_engine_doppler_moved", "1")
	if cvDoppler:GetFloat() == 1 then RunConsoleCommand("audio_engine_doppler", "0.25") end
end
local cvPassby = CreateClientConVar(
	"audio_engine_passby",
	"1",
	true,
	false,
	"How much other cars swell in loudness as they pass close by (0 = off, 1 = default)",
	0,
	2
)
local cvTunnel = CreateClientConVar(
	"audio_engine_tunnel",
	"1",
	true,
	false,
	"Source DSP preset for cars in a tunnel (0 = no tunnel effect, 1 = default, the map's own, "
		.. "6 = medium tunnel, 7 = large tunnel)",
	0,
	133
)
local cvMaxCars = CreateClientConVar(
	"audio_engine_maxcars",
	"8",
	true,
	false,
	"How many other cars play in full detail; twice as many more play a single loop (lower = faster)",
	1,
	32
)
local cvRange = CreateClientConVar(
	"audio_engine_range",
	"200",
	true,
	false,
	"Metres past which other cars aren't played (for an 85 dB car; louder ones carry further)",
	50,
	1000
)

local cars = {}
E.ClientCars = cars

local min, max, abs, log, sin, cos, pi = math.min, math.max, math.abs, math.log, math.sin, math.cos, math.pi
local exp, sqrt, clamp = math.exp, math.sqrt, math.Clamp
local band = bit.band
local IsValid, RealTime = IsValid, RealTime

local INCH_TO_M = 0.0254
local PEAK_UNKNOWN = 0.9
local NO_PEAKS = {}

local function approach(x, target, step)
	if x < target then return min(target, x + step) end

	return max(target, x - step)
end

--[[
	Detail tiers. rankCars sorts the cars a few times a second, the car you're in always at the top:
	  TIER_FULL    every sound, every frame
	  TIER_LIGHT   the one nearest band's on or off loop at TIER_INTERVAL: past the pass-by range
	               that is all that carries anyway
	  TIER_SILENT  no sound; the gearbox model keeps up at a low rate, so the car comes back
	               in the right gear
	A car moving down fades out over TIER_FADE first; moving up it starts like any new sound.
]]
local TIER_FULL, TIER_LIGHT, TIER_SILENT = 1, 2, 3
local TIER_INTERVAL = { 0, 1 / 15, 0.2 }
local TIER_FADE = 0.25
local RANK_INTERVAL = 0.25
local FULL_RANGE_SHARE = 0.3 -- of audio_engine_range: farther cars are never in full detail
local LIGHT_CARS_PER_FULL = 2
local REFERENCE_LEVEL = 85 -- dB audio_engine_range is meant for; every 20 dB more carries ten times as far
-- parked and idling: heard last. An idling car matters less than one the same distance away driving
local PARKED_SPEED, PARKED_PENALTY = 1, 2.5
local KEEP_TIER_BONUS = 0.85 -- a car keeps its place until another is clearly closer: no flapping
local TACH_RANGE = 15 -- m: nobody reads a dashboard needle from further

local function stopAll(car)
	for _, p in pairs(car.patches) do
		p:Stop()
	end
	car.patches = {}
	car.active = {}
	car.idleT = {}
	car.cur = {}
	car.roomOf = {}
	if car.oneshot then
		car.oneshot.patch:Stop()
		car.oneshot = nil
	end
end

local function getPatch(car, name)
	local p = car.patches[name]
	if not p then
		p = CreateSound(car.ent, name)
		car.patches[name] = p
	end

	return p
end

-- every sound starts here: the sound level and DSP go on before it plays (see updateRoom)
local function startPatch(car, name, vol, pitch)
	local p = getPatch(car, name)
	p:SetSoundLevel(car.level or car.cfg.soundLevel or 85)
	p:SetDSP(car.dsp)
	p:PlayEx(vol, pitch)
end

--[[
	Play/update a group of loops that must start together (on/off layers of one band).
	Volume only changes once a frame, and a big jump in one go is an audible click (zipper
	noise), so every loop glides to its target: smoothed, and never more than VOL_SLEW per
	second. Loops start from silence and fade out before they stop.
]]
local VOL_SLEW = 4
-- electric motors (and their low-speed hum) play at this fraction: their banks are rendered at a
-- workable level for 16-bit files, a real EV is far quieter than any engine
E.EV_VOLUME = 0.1
local function glide(cur, target, dt)
	local nx = cur + (target - cur) * min(1, dt * 18)
	local step = VOL_SLEW * dt
	if nx > cur + step then
		nx = cur + step
	elseif nx < cur - step then
		nx = cur - step
	end

	return nx
end

local function startGroup(car, key, names, vols, pitch, dt)
	local cur = {}
	for i = 1, #names do
		cur[i] = glide(0, vols[i], dt)
		startPatch(car, names[i], max(cur[i], 0.001), pitch)
	end
	car.cur[key] = cur
	car.active[key] = true
	car.roomOf[key] = car.roomGen
end

local function runGroup(car, key, names, vols, pitch, dt, fade)
	local cur = car.cur[key]
	-- restarted when the room changed, or if the game dropped the loop (out of channels
	-- with many cars around): nothing else would start it again, the car just went silent
	local moved = car.roomOf[key] ~= car.roomGen
	car.roomOf[key] = car.roomGen
	for i = 1, #names do
		cur[i] = glide(cur[i], vols[i], dt)
		local p = getPatch(car, names[i])
		if moved or (car.revive and not p:IsPlaying()) then
			p:Stop()
			startPatch(car, names[i], max(cur[i], 0.001), pitch)
		else
			p:ChangeVolume(max(cur[i], 0.001), fade)
			p:ChangePitch(pitch, fade)
		end
	end
end

local function fadeGroup(car, key, names, pitch, dt, fade)
	local cur = car.cur[key]
	car.idleT[key] = (car.idleT[key] or 0) + dt
	local loud = 0
	for i = 1, #names do
		cur[i] = glide(cur[i], 0, dt)
		loud = max(loud, cur[i])
		local p = getPatch(car, names[i])
		p:ChangeVolume(max(cur[i], 0.001), fade)
		p:ChangePitch(pitch, fade)
	end
	if loud >= 0.002 or car.idleT[key] <= 0.3 then return end
	for i = 1, #names do
		local p = car.patches[names[i]]
		if p then p:Stop() end
	end
	car.active[key] = false
end

local function setGroup(car, key, names, vols, pitch, dt)
	local total = 0
	for i = 1, #vols do
		total = total + vols[i]
	end
	-- a light car is updated a few times a second: the game spreads each step over that time
	local fade = car.tier == TIER_LIGHT and dt or 0
	if total > 0.0005 then
		car.idleT[key] = 0
		if car.active[key] then
			runGroup(car, key, names, vols, pitch, dt, fade)
		else
			startGroup(car, key, names, vols, pitch, dt)
		end
	elseif car.active[key] then
		fadeGroup(car, key, names, pitch, dt, fade)
	end
end

-- one loop, or a band's on/off pair: setGroup only reads these, so one table of each serves all
local oneName, oneVol, twoVols = { "" }, { 0 }, { 0, 0 }

local function setLoop(car, key, name, vol, pitch, dt)
	oneName[1], oneVol[1] = name, vol
	setGroup(car, key, oneName, oneVol, pitch, dt)
end

local function playOneShot(car, kind, name, vol, pitch, fadeAt, dur)
	if car.oneshot then car.oneshot.patch:FadeOut(0.1) end
	local p = CreateSound(car.ent, name)
	p:SetSoundLevel(car.level or car.cfg.soundLevel or 85)
	p:SetDSP(car.dsp)
	p:PlayEx(vol, pitch)
	car.oneshot = { kind = kind, patch = p, t0 = RealTime(), fadeAt = fadeAt or 0, dur = dur }
end

local function playPop(car, vol, big)
	local bank = car.bank
	local list = big and bank.bangs or bank.pops
	if not list or #list == 0 then return end
	local key = big and "bangIdx" or "popIdx"
	local pick = math.random(#list)
	if pick == car[key] and #list > 1 then pick = pick % #list + 1 end
	car[key] = pick
	-- headroom: the pop's peak on top of the engine's, and of any pop still ringing, must stay
	-- under full scale
	local pk = bank.peak and bank.peak[list[pick]] or 0.98
	vol = min(vol, max(0.05, 0.98 - (car.busPeak or 0) - (car.popLoad or 0)) / max(pk, 0.05))
	car.popLoad = (car.popLoad or 0) + vol * pk
	getPatch(car, list[car[key]]):Stop()
	startPatch(car, list[car[key]], min(1, vol), clamp(math.random(92, 108) * (car.dop or 1), 20, 255))
end

local carSerial = 0

local function newCar(ent, car)
	carSerial = carSerial + 1

	return {
		ent = ent,
		cfg = E.GetEngineConfig(ent),
		stockCfg = E.ResolveProfile(car),
		st = DT.New(),
		inp = {},
		lastOn = nil,
		first = true,
		patches = {},
		active = {},
		idleT = {},
		cur = {},
		bus = 1,
		popPk = 0,
		xr = nil,
		loopGain = 0,
		thrS = 0,
		limW = 0,
		-- no two cars are tuned exactly alike: +-1.5% so a row of them doesn't phase
		detune = 1 + (math.random() - 0.5) * 0.03,
		v = 0,
		vel = Vector(0, 0, 0),
		dop = 1,
		dsp = 0,
		roomGen = 0,
		roomOf = {},
		tunnelW = 0,
		reviveT = RealTime() + 1,
		sampPos = ent:GetPos(),
		sampT = RealTime(),
		sampAlong = { 0, 0, 0 },
		sampFlat = { 0, 0, 0 },
		vAlong = 0,
		vFlat = 0,
		tier = TIER_SILENT,
		tierGain = 1,
		dist = math.huge,
		inBits = 0,
		serial = carSerial,
		nextUpdate = 0,
		pendingDt = 0,
	}
end

local WHEEL_ATTACHMENTS = { "wheel_fl", "wheel_fr", "wheel_rl", "wheel_rr" }
local FORWARD_FALLBACK = Vector(0, 1, 0)
local FORWARD_RETRY = 2 -- s between tries on a model that has no wheel attachments

-- the car's nose direction in local space, from the wheel attachments (falls back to +Y,
-- the usual Source vehicle convention)
local function localForward(car)
	if car.fwdLocal then return car.fwdLocal end
	local now = RealTime()
	if now < (car.fwdRetryT or 0) then return FORWARD_FALLBACK end
	car.fwdRetryT = now + FORWARD_RETRY
	local ent = car.ent
	local ids = {}
	for _, n in ipairs(WHEEL_ATTACHMENTS) do
		local id = ent:LookupAttachment(n)
		local a = id and id > 0 and ent:GetAttachment(id)
		if not a then return FORWARD_FALLBACK end
		ids[n] = ent:WorldToLocal(a.Pos)
	end
	local f = (ids.wheel_fl + ids.wheel_fr) - (ids.wheel_rl + ids.wheel_rr)
	f.z = 0
	if f:Length() < 1 then return FORWARD_FALLBACK end
	f:Normalize()
	car.fwdLocal = f

	return f
end

-- the listener (whoever's ears the sound reaches): position and velocity, once per frame
local listener = { pos = Vector(0, 0, 0), vel = Vector(0, 0, 0), ok = false, tunnelW = 0 }
local SPEED_OF_SOUND = 343 / INCH_TO_M -- in inches/s

local function readInputs(car)
	local ent = car.ent
	local bits = ent:GetNW2Int("audio_in", 0)
	car.inBits = bits
	local f, b, h, s = band(bits, 1) ~= 0, band(bits, 2) ~= 0, band(bits, 4) ~= 0, band(bits, 8) ~= 0
	local ply = listener.ply
	if ply and listener.vehicle == ent then
		-- the local driver: use their own keys for zero latency, once we know they register
		local lf, lb, lh = ply:KeyDown(IN_FORWARD), ply:KeyDown(IN_BACK), ply:KeyDown(IN_JUMP)
		if lf or lb or lh then car.localKeys = true end
		if car.localKeys then
			f, b, h, s = lf, lb, lh, ply:KeyDown(IN_MOVELEFT) ~= ply:KeyDown(IN_MOVERIGHT)
		end
	end
	-- speed limiter (sv_cruise.lua): holding at the limit sounds like steady part throttle;
	-- over it the throttle is shut even with W held
	local lim = ent:GetNW2Int("audio_limst", 0)
	if lim == 2 then f = false end

	return f, b, h, s, f and lim == 1
end

local function updateListener(dt)
	local ply = LocalPlayer()
	listener.ply, listener.vehicle = nil, nil
	if not IsValid(ply) then return end
	local view = GetViewEntity()
	local vehicle = ply:GetVehicle()
	local pos = (IsValid(view) and view ~= ply) and view:GetPos() or ply:EyePos()
	local now = RealTime()
	if listener.ok and now > listener.t then
		local v = (pos - listener.pos) / (now - listener.t)
		if v:Length() > 6000 then v = listener.vel end -- teleported / respawned
		listener.vel = listener.vel + (v - listener.vel) * min(1, dt * 8)
	end
	listener.pos, listener.t = pos, now
	listener.ok = true
	listener.ply, listener.view = ply, view
	listener.vehicle = IsValid(vehicle) and vehicle or nil
	listener.cabin = listener.vehicle ~= nil and view == ply
end

-- f' = f (c + v_listener) / (c - v_source), both measured toward each other. Sound travels at
-- c / (audio_engine_doppler x DOPPLER_BOOST): the default 0.25 is the real speed of sound, where
-- an 80 mph drive-by bends 3-4 semitones; 1 is four times that
local DOPPLER_BOOST = 4
-- The full boost goes shrill at speed: closing at 40 m/s came out almost an octave up. Up to
-- DOPPLER_KNEE semitones it's left alone (an ordinary pass), past it the shift bends over towards
-- DOPPLER_MAX, which a head-on pass at any speed never goes over
local DOPPLER_KNEE, DOPPLER_MAX = 4, 7
local function softPitch(ratio)
	local semis = 12 * log(ratio) / log(2)
	local over = abs(semis) - DOPPLER_KNEE
	if over <= 0 then return ratio end
	local room = DOPPLER_MAX - DOPPLER_KNEE
	local bent = DOPPLER_KNEE + room * math.tanh(over / room)
	return 2 ^ ((semis > 0 and bent or -bent) / 12)
end

local function dopplerFactor(car, dt, mine)
	local amt = cvDoppler:GetFloat()
	local target = 1
	if amt > 0 and not mine and listener.ok then
		local d = listener.pos - car.ent:GetPos()
		local dist = d:Length()
		if dist > 1 then
			d:Mul(1 / dist)
			local vs = car.vel:Dot(d) -- source toward listener
			local vl = -listener.vel:Dot(d) -- listener toward source
			local c = SPEED_OF_SOUND / (amt * DOPPLER_BOOST)
			target = softPitch(max(c * 0.25, c + vl) / max(c * 0.5, c - vs))
		end
	end
	-- quick enough to keep up with the pitch drop: a fast close pass is over in about 0.2 s
	car.dop = car.dop + (target - car.dop) * min(1, dt * 14)
	return car.dop
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
	none). Close to a fast car you also hear what the driver doesn't: car.rush (0-1) brings up the
	tyre roar and wind, tuned low for the cabin, as a whoosh over RUSH_FAR to PASSBY_NEAR.

	Speed here means how fast the car goes past you: its own speed, but no more than its speed
	relative to the listener. A car keeping pace beside you isn't passing, and on its own speed it
	got the whole swell and whoosh while your own engine stayed at 1, so it drowned yours out.
	Sitting in a car, every other car is CABIN_DB down: it comes through the bodywork, yours doesn't.
	A tunnel carries sound along it, so with both you and the car inside there's no drop with range.
]]
local PASSBY_NEAR, PASSBY_REF, PASSBY_FAR = 2.5 / 0.0254, 5 / 0.0254, 30 / 0.0254 -- inches
local PASSBY_CURVE_SLOW, PASSBY_CURVE_FAST = 0.35, 0.7
local PASSBY_SLOW, PASSBY_FAST, PASSBY_PEAK, PASSBY_LEAD = 5, 30, 0.95, 0.2
local EXHAUST_FRONT_DB, EXHAUST_REAR_DB = 5, 3
local CABIN_DB = 3
local RUSH_FAR, RUSH_SLOW, RUSH_FAST, RUSH_ROAD, RUSH_WIND = 10 / 0.0254, 12, 40, 0.7, 1 -- inches; m/s; volumes
local function proximityGain(car, mine, fwd)
	car.rush = 0
	if mine or not listener.ok then return 1 end
	local cabin = listener.cabin and 10 ^ (-CABIN_DB / 20) or 1
	local amt = cvPassby:GetFloat()
	if amt <= 0 then return cabin end
	local toEar = listener.pos - car.ent:GetPos()
	local dist = toEar:Length()
	local speed = min(car.vel:Length(), (car.vel - listener.vel):Length()) -- inches/s
	local ms = speed * INCH_TO_M
	local d = clamp(dist - speed * PASSBY_LEAD, PASSBY_NEAR, PASSBY_FAR)
	local pace = clamp((ms - PASSBY_SLOW) / (PASSBY_FAST - PASSBY_SLOW), 0, 1)
	local gain
	if d > PASSBY_REF then
		gain = (PASSBY_REF / d)
			^ (
				(PASSBY_CURVE_SLOW + (PASSBY_CURVE_FAST - PASSBY_CURVE_SLOW) * pace)
				* amt
				* (1 - listener.tunnelW * car.tunnelW)
			)
	else
		gain = 1 + ((PASSBY_REF / d) ^ amt - 1) * pace
	end
	car.rush = amt
		* clamp((RUSH_FAR - dist) / (RUSH_FAR - PASSBY_NEAR), 0, 1) ^ 2
		* clamp((ms - RUSH_SLOW) / (RUSH_FAST - RUSH_SLOW), 0, 1)
	if car.cfg.electric or dist < 1 then return gain * cabin end
	local ahead = fwd:Dot(toEar) / dist -- 1 in front of the car, -1 behind it
	local db = -ahead * (ahead > 0 and EXHAUST_FRONT_DB or EXHAUST_REAR_DB)
	return gain * cabin * 10 ^ (db * pace * amt / 20)
end

-- loops are muted while a start-up one-shot plays, and faded out for shut-down
local function updateLoopGain(car, st, dt)
	local target, rate = 1, 1 / 0.12
	local shot = car.oneshot
	if shot then
		local el = RealTime() - shot.t0
		if shot.kind == "start" and el >= shot.fadeAt then
			rate = 1 / max(0.05, shot.dur - shot.fadeAt)
		elseif shot.kind == "start" and st.phase ~= "run" then
			target = 0
		elseif shot.kind == "start" then
			-- driver hit the throttle during the flare: hand over now
			shot.patch:FadeOut(0.12)
			car.oneshot = nil
		end
		if car.oneshot and el > shot.dur + 0.1 then
			shot.patch:Stop()
			car.oneshot = nil
		end
	end
	if not st.on then
		target, rate = 0, 1 / 0.08
	end
	car.loopGain = approach(car.loopGain, target, rate * dt)
end

local bandWeights = {}

-- equal-power cross-fade between the two bands around the current rpm (log spaced), into
-- bandWeights. The fade position follows the rpm a touch smoothed, so a quick blip doesn't swing
-- the loop volumes from one frame to the next (the pitch still follows the exact rpm).
local function crossfadeBands(car, layers, rpm, dt)
	local n = #layers
	local lr = log(rpm)
	car.xr = car.xr and (car.xr + (lr - car.xr) * min(1, dt * 20)) or lr
	local xrpm = exp(car.xr)
	for i = 1, n do
		bandWeights[i] = 0
	end
	if xrpm <= layers[1].rpm then
		bandWeights[1] = 1
		return
	end
	if xrpm >= layers[n].rpm then
		bandWeights[n] = 1
		return
	end
	for i = 1, n - 1 do
		if xrpm < layers[i + 1].rpm then
			local t = (car.xr - log(layers[i].rpm)) / (log(layers[i + 1].rpm) - log(layers[i].rpm))
			bandWeights[i] = cos(t * pi / 2)
			bandWeights[i + 1] = sin(t * pi / 2)
			break
		end
	end
end

-- what this frame's mix is made of: filled by the steps of updateSound, read by the next ones
local mix = {}

-- the rolling-noise levels are needed for the headroom estimate
local function rollingNoise(car, cfg, env)
	mix.road = cvRoad:GetFloat() * (cfg.volume or 1)
	mix.wind = cvWind:GetFloat() * (cfg.volume or 1)
	mix.roadVol, mix.windVol, mix.rollRate = 0, 0, 0
	if not (env and env.ready) then return end
	local kmh = abs(car.v) * 3.6
	local rr = clamp((kmh - 3) / 120, 0, 1)
	mix.rollRate = rr
	-- the tyre roar eases back again past 60 km/h (about -5 dB from 160 km/h): pitched up and
	-- at full level it was a rushing-air hiss over the engine on fast cars
	mix.roadVol = mix.road * (rr ^ 1.2) * 0.7 * (1 - 0.45 * clamp((kmh - 60) / 100, 0, 1))
	-- wind stays in the background: from 80 km/h, and well under the engine even flat out
	-- (0.06 from 60 km/h roared over the engine on fast cars)
	mix.windVol = mix.wind * clamp((kmh - 80) / 240, 0, 1) ^ 2 * 0.015
end

-- electric: a steady low hum at walking pace (like an EV's pedestrian warning sound), at an
-- almost fixed pitch; it fades out between ~8% and 20% of top speed (about 15-35 km/h)
-- while the motor whine, rising with speed, takes over
local function evHum(car, cfg, st, env, g, rpm)
	mix.humSpd = rpm / cfg.redline
	mix.humVol = 0
	if not (cfg.electric and env and env.ready and env.evhum and st.on and st.phase == "run") then return end
	local fade = 1 - clamp((mix.humSpd - 0.08) / 0.12, 0, 1)
	local moving = clamp(abs(car.v) / 2, 0, 1) -- a little softer standing still
	mix.humVol = g * 0.3 * fade * (0.7 + 0.3 * moving)
end

-- each sound's real peak (measured when it was generated); the on/off layers of a band
-- share their firing phase so they add directly, separate sounds add by power
local function estimatePeak(car, bank, cfg, env, g)
	local peaks = bank.peak or NO_PEAKS
	local envPeaks = env and env.peak
	local turboOn, b = mix.turboOn, mix.boost
	local est2 = (car.limW * g * (peaks[bank.limiter.off] or PEAK_UNKNOWN)) ^ 2
		+ (mix.humVol * (envPeaks and envPeaks.evhum or 0.3)) ^ 2
		+ (turboOn and (g * b ^ 1.5 * 0.5 * (cfg.profile.turboVol or 1) * (env.peak.turbo or 0.9)) or 0) ^ 2
		+ (env and (mix.roadVol * (envPeaks and envPeaks.road or 0.3)) or 0) ^ 2
		+ (env and (mix.windVol * (envPeaks and envPeaks.wind or 0.3)) or 0) ^ 2
	local thrE = car.thrS
	local layers = bank.layers
	for i = 1, #layers do
		local L, wi = layers[i], bandWeights[i] * (1 - car.limW) * g
		if wi > 0 then
			local on, off = peaks[L.on] or PEAK_UNKNOWN, peaks[L.off] or PEAK_UNKNOWN
			est2 = est2 + (wi * (thrE * on + (1 - thrE) * off)) ^ 2
		end
	end

	return sqrt(est2)
end

--[[
	Headroom. Everything this car plays is summed by the game and clips (crackles) past
	full scale, so the car's own mix is kept under a ceiling: driving leaves headroom,
	revving in neutral may go a little louder. Loops are normalised to a 0.9 peak; loops
	that aren't phase-locked add up by power. The estimate is by power, but mid cross-fade
	two bands' peaks do line up now and then (up to ~1.4x the estimate on the heavily
	limited V8 / flat-4 banks), so the ceilings leave room for that: at 0.72 / 0.85 most
	engines crackled idling in neutral.
]]
local function applyHeadroom(car, est, dt)
	local busT = est > car.ceiling and car.ceiling / est or 1
	-- pull down quickly, recover slowly
	local rate = busT < car.bus and 30 or 3
	car.bus = car.bus + (busT - car.bus) * min(1, dt * rate)
	car.popLoad = (car.popLoad or 0) * exp(-dt / 0.08)
	-- the pass-by swell goes on after the headroom, so a car pinned at its ceiling still swells
	local prox = car.prox or 1
	if prox > 1 then
		prox = max(1, min(prox, PASSBY_PEAK / max(est * car.bus, 0.01)))
		car.prox = prox
	end
	car.busPeak = est * car.bus * prox
end

local function playBands(car, bank, g, rpm, det, dt)
	local layers, thr = bank.layers, car.thrS
	for i = 1, #layers do
		local L = layers[i]
		local wi = bandWeights[i] * (1 - car.limW) * g
		if wi > 0 or car.active[i] then
			local pitch = clamp(100 * det * rpm / L.rpm, 5, 250)
			local trim = L.trim or 1
			twoVols[1], twoVols[2] = wi * thr * trim, wi * (1 - thr) * trim
			L.names = L.names or { L.on, L.off }
			setGroup(car, i, L.names, twoVols, pitch, dt)
		end
	end
end

local LIGHT_KEY = 1000 -- group keys of a light car's loops, clear of the band numbers

-- a light car: the nearest band, on or off throttle, nothing else
local function playLight(car, bank, g, rpm, dt)
	local layers = bank.layers
	local best = 1
	for i = 2, #layers do
		if bandWeights[i] > bandWeights[best] then best = i end
	end
	local onThrottle = car.thrS >= 0.5
	local det = car.detune * (car.dop or 1)
	for i = 1, #layers do
		local L = layers[i]
		local onKey, offKey = LIGHT_KEY + i * 2, LIGHT_KEY + i * 2 + 1
		local vol = i == best and g * (L.trim or 1) or 0
		if vol > 0 or car.active[onKey] or car.active[offKey] then
			local pitch = clamp(100 * det * rpm / L.rpm, 5, 250)
			setLoop(car, onKey, L.on, onThrottle and vol or 0, pitch, dt)
			setLoop(car, offKey, L.off, onThrottle and 0 or vol, pitch, dt)
		end
	end
end

-- turbos: the whistle rises with boost, the blow-off valve sighs when the throttle shuts
local function playTurbo(car, cfg, st, env, g, rpm, det, dt)
	local b = mix.boost
	if not mix.turboOn then
		-- turbo switched off in the menu: fade the whistle out
		if car.active.turbo then setLoop(car, "turbo", env.turbo, 0, 100, dt) end
		return
	end
	local pitch = clamp(100 * det * (0.45 + 0.55 * b) * (0.9 + 0.2 * rpm / cfg.redline), 20, 220)
	-- the turbo sounds are generated 6 dB hot: half volume is the default level, so the
	-- profile's turbo and blow-off volumes can go to 200%
	local turboVol = cfg.profile.turboVol or 1
	setLoop(car, "turbo", env.turbo, g * b ^ 1.5 * 0.5 * turboVol, pitch, dt)
	local bovVol = cfg.profile.bovVol or 1
	if not (st.bovEvent and cfg.profile.bov and bovVol > 0 and #env.blowoff > 0) then return end
	local name = env.blowoff[math.random(#env.blowoff)]
	local vol = g * min(1, st.bovEvent * 1.2) * 0.5 * bovVol
	-- headroom, like the pops
	local pk = env.peak[name] or 0.98
	vol = min(1, vol, max(0.05, 0.98 - (car.busPeak or 0) - (car.popLoad or 0)) / max(pk, 0.05))
	car.popLoad = (car.popLoad or 0) + vol * pk
	getPatch(car, name):Stop()
	startPatch(car, name, vol, clamp(math.random(95, 105) * (car.dop or 1), 20, 255))
end

-- lift-off high in the revs: a burble starts, longer the higher the revs and the more it pops
local function startBurble(car, st, red, P, event, now)
	if not ((car.lastThr or 0) > 0.8 and st.thr < 0.5 and st.rpm > red * 0.5) then return end
	local hi = clamp((st.rpm / red - 0.5) / 0.4, 0, 1)
	car.burbleT0 = now
	car.burbleDur = (0.8 + 2.2 * P) * (0.5 + 0.5 * hi)
	car.popNext = now + 0.12 + 0.18 * math.random()
	car.popBang = math.random() < event * (0.4 + 0.6 * hi)
end

local function burblePop(car, st, red, P, popVol, now)
	local age = (now - car.burbleT0) / car.burbleDur
	local inten = (age < 1 and (1 - age) ^ 1.5 or 0) * clamp((st.rpm / red - 0.35) / 0.5, 0, 1)
	if inten <= 0.03 then
		car.popNext = nil
		return
	end
	if car.popBang then
		playPop(car, popVol * (0.8 + 0.2 * math.random()), true)
		car.popBang = false
	else
		playPop(car, popVol * (0.5 + 0.5 * inten) * (0.75 + 0.25 * math.random()), false)
	end
	-- a quick follow-up (a cluster), or a pause that grows as the burble dies away
	if math.random() < 0.25 + 0.3 * inten then
		car.popNext = now + 0.05 + 0.08 * math.random()
	else
		car.popNext = now + (0.15 + 0.5 * math.random()) / (0.3 + 1.5 * inten * P)
	end
end

--[[
	Pops & bangs: profile "pops" = how often (0 = off), "popVol" = how loud (1 = default).
	Timed like a real overrun: lifting off high in the revs starts a burble a moment later (the
	fuel has to reach the hot exhaust), pops in uneven clusters, thick at first and thinning out
	as the revs fall and the seconds pass; back on the throttle ends it. A long coast only pops
	now and then. (A per-frame chance spread lone pops evenly over every coast: popcorn.)
	The big events (a bang to open the burble, upshift crack, limiter) go with P squared: a Rare
	or Occasional car crackles now and then, only a Frequent one bangs on most lifts.
]]
local function updatePops(car, cfg, st, bank, popVol, dt)
	local P = cfg.profile.pops or 0
	if not (P > 0 and popVol > 0 and #bank.pops > 0 and st.on and st.phase == "run") then return end
	local red, now = cfg.redline, RealTime()
	local event = P * P
	local overrun = st.soundThr < 0.04 and st.rpm > red * 0.35 and not st.cut
	startBurble(car, st, red, P, event, now)
	if st.soundThr > 0.3 then car.popNext = nil end -- back on the throttle
	if overrun and car.popNext and now >= car.popNext then burblePop(car, st, red, P, popVol, now) end
	-- a long coast at high revs: an odd pop now and then
	if overrun and not car.popNext and st.rpm > red * 0.55 and math.random() < event * 0.25 * dt then
		playPop(car, popVol * (0.4 + 0.3 * math.random()), false)
	end
	-- upshift crack, flat out high in the revs
	local lastGear = car.lastGear or 0
	local upshifted = st.gear > lastGear and lastGear > 0 and st.shiftKind == 1
	if upshifted and st.thr > 0.8 and (car.lastRpm or 0) > red * 0.75 and math.random() < event * 0.6 then
		playPop(car, popVol * 0.8, P > 0.7 and math.random() < 0.3)
	end
	if st.limEvent and math.random() < event then playPop(car, popVol * 0.8, P > 0.7 and math.random() < 0.25) end
end

local function updateSound(car, dt)
	local bank, cfg, st = car.bank, car.cfg, car.st
	if not bank or not bank.ready then return end

	local master = cvVol:GetFloat() * (cfg.volume or 1)
	updateLoopGain(car, st, dt)

	car.thrS = car.thrS + (st.soundThr - car.thrS) * min(1, dt * 12)
	-- the limiter loop only while the throttle is held against it: let go and the revs fall
	-- straight away, so the loop must too (it used to stutter on for its hold time)
	local running = st.on and st.phase == "run"
	local limTarget = (running and st.gear == 0 and st.limHold > 0 and st.lastPedal and st.rpm > cfg.redline * 0.9)
			and 1
		or 0
	car.limW = approach(car.limW, limTarget, dt / (limTarget > car.limW and 0.06 or 0.03))

	local neutral = running and st.gear == 0
	local ceiling = neutral and 0.68 or 0.66
	car.ceiling = approach(car.ceiling or 0.66, ceiling, dt * 0.5)
	-- revving in neutral sits a few dB above driving (driving leaves that headroom)
	car.revGain = approach(car.revGain or 0.85, neutral and 1.2 or 0.85, dt * 2)
	local g = master * car.loopGain * car.revGain * (cfg.electric and E.EV_VOLUME or 1) * car.tierGain
	local rpm = max(st.rpm, 50)
	crossfadeBands(car, bank.layers, rpm, dt)

	if car.tier == TIER_LIGHT then
		playLight(car, bank, g * car.bus * (car.prox or 1), rpm, dt)
		return
	end

	local env = Bank.env
	rollingNoise(car, cfg, env)
	-- turbo sounds live in the shared bank (Bank.env): any engine can have them
	mix.turboOn = cfg.turbo and env and env.ready and env.turbo
	mix.boost = mix.turboOn and (st.boost or 0) or 0
	evHum(car, cfg, st, env, g, rpm)
	local est = estimatePeak(car, bank, cfg, env, g)
	applyHeadroom(car, est, dt)
	local prox = car.prox or 1
	g = g * car.bus * prox
	local humVol = mix.humVol * car.bus * prox
	local roadVol = mix.roadVol * car.bus * prox * car.tierGain
	local windVol = mix.windVol * car.bus * prox * car.tierGain
	-- after the headroom: the whoosh shouldn't pull the engine down just as it peaks
	local rush = (car.rush or 0) * car.tierGain
	roadVol, windVol = roadVol + mix.road * rush * RUSH_ROAD, windVol + mix.wind * rush * RUSH_WIND

	local det = car.detune * (car.dop or 1)
	playBands(car, bank, g, rpm, det, dt)
	-- a family bank (or the stock fallback) may be rendered at another redline: pitch it to ours
	local limPitch = clamp(100 * det * cfg.redline / (bank.limiter.rpm or cfg.redline), 5, 250)
	setLoop(car, "lim", bank.limiter.off, car.limW * g, limPitch, dt)
	playTurbo(car, cfg, st, env, g, rpm, det, dt)
	if humVol > 0 or car.active.evhum then
		local spd = clamp(mix.humSpd / 0.2, 0, 1)
		local pitch = clamp(100 * (car.dop or 1) * (1 + 0.12 * spd), 20, 220)
		setLoop(car, "evhum", env.evhum, humVol, pitch, dt)
	end

	-- 0.7: about 3 dB over the 0.5 they were baked for (they came out a little too quiet)
	local popVol = master * car.loopGain * 0.7 * (cfg.profile.popVol or 1) * (car.prox or 1) * car.tierGain
	updatePops(car, cfg, st, bank, popVol, dt)
	car.lastRpm = st.rpm
	car.lastThr = st.thr
	car.lastGear = st.gear

	-- rolling noise: tyre roar grows with speed, wind takes over on the motorway.
	-- It doesn't depend on the engine running (a coasting car still roars).
	if env and env.ready then
		local dop, rr = car.dop or 1, mix.rollRate
		setLoop(car, "road", env.road, roadVol, clamp((75 + 30 * rr) * dop, 20, 255), dt)
		setLoop(car, "wind", env.wind, windVol, clamp((85 + 35 * rr) * dop, 20, 255), dt)
	end
end

--[[
	The vehicle_guage pose, set right before the car is drawn. The server sets it too (Source's
	speedometer) and networks it, and the client re-interpolates that value every frame after
	Think, so a value set in Think only showed now and then: the Murcielago's vents flickered
	open and shut wherever Source's value crossed their range. Keeps any existing override.
]]
local function guageOverride(ent)
	if ent.audioGuageHooked then return end
	ent.audioGuageHooked = true
	local prev = ent.RenderOverride
	ent.RenderOverride = function(self, flags)
		if self.audioGuage then
			self:SetPoseParameter("vehicle_guage", self.audioGuage)
			self:InvalidateBoneCache()
		end
		if prev then
			prev(self, flags)
		else
			self:DrawModel(flags)
		end
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
local TUNNEL_ROOF, TUNNEL_REACH = 25 / 0.0254, 50 / 0.0254 -- inches
local TUNNEL_WIDE, TUNNEL_LONG, TUNNEL_RATIO = 30 / 0.0254, 30 / 0.0254, 2.5
local TUNNEL_LEVEL, TUNNEL_FADE = 8, 0.6 -- dB; s
local TUNNEL_UP, TUNNEL_CAR_HEIGHT = Vector(0, 0, 1), Vector(0, 0, 60)
local TUNNEL_AXES = {}
for i = 0, 7 do
	TUNNEL_AXES[i + 1] = Vector(cos(i * pi / 8), sin(i * pi / 8), 0)
end

local tunnelTrace = { mask = MASK_SOLID_BRUSHONLY }
local function reach(pos, dir, dist)
	tunnelTrace.start, tunnelTrace.endpos = pos, pos + dir * dist
	local tr = util.TraceLine(tunnelTrace)
	if not tr.Hit or tr.HitSky then return dist end
	return dist * tr.Fraction
end

local function inTunnel(pos)
	if reach(pos, TUNNEL_UP, TUNNEL_ROOF) >= TUNNEL_ROOF then return false end
	local narrow, long = math.huge, 0
	for _, axis in ipairs(TUNNEL_AXES) do
		local span = reach(pos, axis, TUNNEL_REACH) + reach(pos, -axis, TUNNEL_REACH)
		narrow, long = min(narrow, span), max(long, span)
	end
	return narrow <= TUNNEL_WIDE and long >= max(TUNNEL_LONG, narrow * TUNNEL_RATIO)
end

local TUNNEL_PROBE_INTERVAL = 0.05 -- s between cars: each probe is up to 17 traces

-- the listener a few times a second, the cars one at a time
local nextEarProbe, nextCarProbe, probed = 0, 0, nil
local function probeTunnels(dt)
	local on = cvTunnel:GetInt() > 0
	local now = RealTime()
	if now >= nextEarProbe and listener.ok then
		nextEarProbe = now + 0.25
		listener.inTunnel = on and not listener.cabin and inTunnel(listener.pos)
	end
	listener.tunnelW = approach(listener.tunnelW, listener.inTunnel and 1 or 0, dt / TUNNEL_FADE)
	if now < nextCarProbe then return end
	nextCarProbe = now + TUNNEL_PROBE_INTERVAL
	if probed and not cars[probed] then probed = nil end
	probed = next(cars, probed)
	local car = probed and cars[probed]
	if car and not car.dormant and car.tier ~= TIER_SILENT then
		car.inTunnel = on and inTunnel(probed:GetPos() + TUNNEL_CAR_HEIGHT)
	end
end

local function updateRoom(car, dt)
	car.tunnelW = approach(car.tunnelW, car.inTunnel and 1 or 0, dt / TUNNEL_FADE)
	local outside = not listener.cabin
	local dsp = outside and max(car.tunnelW, listener.tunnelW) > 0.5 and cvTunnel:GetInt() or 0
	local level = (car.cfg.soundLevel or 85) + (outside and car.tunnelW > 0.5 and TUNNEL_LEVEL or 0)
	if dsp ~= car.dsp or level ~= car.level then
		car.dsp, car.level, car.roomGen = dsp, level, car.roomGen + 1
	end
end

--[[
	The car's speed, from position change (works for every car, not just our own). Measured over
	real time, at least SPEED_SAMPLE apart: a frame's dt is capped, so a stutter read as several
	times the real speed, and the revs and the gearbox jumped with it. A freeze over SPEED_GAP
	says nothing about the speed, so it's held. The median of three samples drops a lone bad one
	(a network stall reads as zero, then double), and vFlat leaves out motion along the car's own
	up axis, so a kerb or a seam kicking the car up doesn't count as speed.
]]
local SPEED_SAMPLE, SPEED_GAP, SPEED_SLEW = 0.05, 0.3, 40 -- s; s; m/s per second the gearbox's speed may change

local function median(h, x)
	h[1], h[2], h[3] = h[2], h[3], x
	return max(min(h[1], h[2]), min(max(h[1], h[2]), h[3]))
end

local function sampleSpeed(car, fwd)
	local now = RealTime()
	local span = now - car.sampT
	if span < SPEED_SAMPLE then return end
	local pos = car.ent:GetPos()
	local vel = (pos - car.sampPos) / span -- inches/s
	car.sampPos, car.sampT = pos, now
	if span > SPEED_GAP or vel:Length() * INCH_TO_M > 150 then return end -- (over 150 m/s: teleported)
	car.vel = car.vel + (vel - car.vel) * min(1, span * 8)
	local up = car.ent:GetUp()
	car.vAlong = median(car.sampAlong, vel:Dot(fwd) * INCH_TO_M)
	car.vFlat = median(car.sampFlat, (vel - up * vel:Dot(up)):Length() * INCH_TO_M)
end

-- a car moving down a tier fades out first, then swaps over
local function updateTierFade(car, dt)
	if not car.pendingTier then
		car.tierGain = approach(car.tierGain, 1, dt / TIER_FADE)
		return
	end
	car.tierGain = approach(car.tierGain, 0, dt / TIER_FADE)
	if car.tierGain > 0 then return end
	stopAll(car)
	car.tier, car.pendingTier, car.tierGain = car.pendingTier, nil, 1
end

local function setTier(car, tier)
	if tier == car.tier then
		car.pendingTier = nil
		return
	end
	if car.tier ~= TIER_SILENT then
		car.pendingTier = tier
		return
	end
	car.tier, car.pendingTier, car.tierGain = tier, nil, 1
	car.nextUpdate = 0
end

local function tierScore(car)
	local score = car.dist
	if abs(car.v) < PARKED_SPEED and car.inBits == 0 then score = score * PARKED_PENALTY end
	if car.tier ~= TIER_SILENT then score = score * KEEP_TIER_BONUS end

	return score
end

local ranked = {}
local function byScore(a, b)
	return a.score < b.score
end

local function collectRanked()
	local n = 0
	for ent, car in pairs(cars) do
		if IsValid(ent) and not ent:IsDormant() then
			car.dist = sqrt(ent:GetPos():DistToSqr(listener.pos)) * INCH_TO_M
			car.score = tierScore(car)
			n = n + 1
			ranked[n] = car
		end
	end
	for i = #ranked, n + 1, -1 do
		ranked[i] = nil
	end
	table.sort(ranked, byScore)
end

-- who gets which tier, a few times a second (see the tiers at the top of this file)
local function rankCars()
	if not listener.ok then return end
	collectRanked()
	local fullLeft = cvMaxCars:GetInt()
	local lightLeft = fullLeft * LIGHT_CARS_PER_FULL
	local range = cvRange:GetFloat()
	for i = 1, #ranked do
		local car = ranked[i]
		local carRange = range * 10 ^ (((car.level or REFERENCE_LEVEL) - REFERENCE_LEVEL) / 20)
		local tier = TIER_SILENT
		if car.ent == listener.vehicle then
			tier = TIER_FULL
		elseif car.dist > carRange then
			tier = TIER_SILENT
		elseif fullLeft > 0 and car.dist < carRange * FULL_RANGE_SHARE then
			fullLeft = fullLeft - 1
			tier = TIER_FULL
		elseif lightLeft > 0 then
			lightLeft = lightLeft - 1
			tier = TIER_LIGHT
		end
		setTier(car, tier)
	end
end

-- engine switched on / off by the server
local function followIgnition(car, cfg, ent, st)
	local on = ent:GetNW2Bool("audio_on", false)
	if on == car.lastOn then return end
	local bank = car.tier ~= TIER_SILENT and car.bank
	local audible = bank and bank.ready
	local vol = cvVol:GetFloat() * (cfg.volume or 1) * (car.prox or 1)
	if on then
		local age = CurTime() - ent:GetNW2Float("audio_on_t", 0)
		if car.first or age > 2 then
			DT.SkipStart(st, cfg)
			car.loopGain = 1
		else
			DT.Start(st, ent:GetNW2Bool("audio_emo", false))
			car.loopGain = 0
			if audible then
				local s = st.emotion and bank.startEmo or bank.start
				playOneShot(car, "start", s.name, vol, 100, s.fadeAt, s.dur)
			end
		end
	else
		if not car.first and st.rpm > 100 and audible then
			local pitch = clamp(100 * st.rpm / cfg.idle, 70, 160)
			playOneShot(car, "stop", bank.stop.name, vol, pitch, 0, bank.stop.dur)
		end
		DT.Stop(st)
		if car.first then st.rpm = 0 end
	end
	car.lastOn = on
end

-- the gearbox follows the wheels, and in a slide they still roll at the car's full speed: the
-- speed along the nose collapsed as the car went sideways, the revs plunged and shot back up
-- as it straightened (a cartoon "weee-ooo"). Full speed, signed by the nose, unless it has
-- turned mostly backwards or sideways (a spin)
local function updateDriveSpeed(car, dt)
	local vFull = car.vFlat
	local vDrive = car.v
	if vFull > 2 and abs(car.v) > vFull * 0.3 then vDrive = (car.v >= 0 and 1 or -1) * vFull end
	-- no car really changes speed faster than SPEED_SLEW: what's left of a bump stops here
	local eased = car.vDrive and car.vDrive + (vDrive - car.vDrive) * min(1, dt * 10)
	car.vDrive = car.vDrive and approach(car.vDrive, eased, dt * SPEED_SLEW) or vDrive
end

-- the model's own dashboard tach needle follows the revs. Cars whose wings/vents also hang off
-- that pose (E.GAUGE_PARTS) follow the position the server picks from speed (sv_engine.lua)
-- instead, glided here so they move smoothly between its updates. The pose costs a bone setup
-- per draw, so a far car's needle is left alone.
local function updateGuage(car, cfg, ent, st, mine, dt)
	if cfg.gaugeParts then
		local want = ent:GetNW2Float("audio_wing", cfg.gaugeParts[1])
		car.wing = car.wing and approach(car.wing, want, dt * E.WING_RATE) or want
		ent.audioGuage = car.wing
	elseif mine or car.dist < TACH_RANGE then
		local maxR = math.ceil((cfg.redline + 500) / 1000) * 1000
		ent.audioGuage = clamp(st.rpm / maxR, 0, 1)
	else
		ent.audioGuage = nil
	end
	if ent.audioGuage then guageOverride(ent) end
end

local function updateCar(car, dt)
	local ent, st = car.ent, car.st

	if ent:IsDormant() then
		if not car.dormant then
			stopAll(car)
			car.dormant = true
			car.tier, car.pendingTier, car.tierGain = TIER_SILENT, nil, 1
		end
		car.sampPos, car.sampT, car.wing = ent:GetPos(), RealTime(), nil
		return
	end
	car.dormant = false

	-- follow the car's engine profile (retuned in game); its sounds are generated on demand,
	-- the old engine keeps playing until the new one is ready
	local cfg = E.GetEngineConfig(ent) or car.cfg
	car.cfg = cfg
	local mine = listener.vehicle == ent
	if car.tier ~= TIER_SILENT then
		local bank = Bank.Get(cfg, car.stockCfg, mine)
		if bank ~= car.bank and bank.ready then
			stopAll(car)
			car.bank = bank
		end
	end

	followIgnition(car, cfg, ent, st)
	car.first = false

	-- speed along the nose
	local fwd = Vector(localForward(car))
	fwd:Rotate(ent:GetAngles())
	sampleSpeed(car, fwd)
	car.v = car.v + (car.vAlong - car.v) * min(1, dt * 10)
	-- driving it but watching from a camera, you hear it from outside like anyone else
	local inside = mine and listener.view == listener.ply
	dopplerFactor(car, dt, inside)
	car.prox = proximityGain(car, inside, fwd)
	updateDriveSpeed(car, dt)

	local inp = car.inp
	inp.fwd, inp.back, inp.hand, inp.steer, inp.cruise = readInputs(car)
	inp.v = car.vDrive
	DT.Step(st, cfg, dt, inp)

	updateRoom(car, dt)
	local now = RealTime()
	car.revive = now >= car.reviveT
	if car.revive then car.reviveT = now + 1 end
	updateTierFade(car, dt)
	if car.tier ~= TIER_SILENT then updateSound(car, dt) end
	updateGuage(car, cfg, ent, st, mine, dt)
end

local SCAN_INTERVAL = 0.5
local SWEEP_INTERVAL = 5 -- the entity list is long on a full server: new cars come in by hook

local newEnts = {}

-- true once it's settled whether this entity is one of ours (its model may not be known yet)
local function adopt(ent)
	if cars[ent] then return true end
	local mdl = ent:GetModel()
	if not mdl or mdl == "" then return false end
	local carCfg = E.GetCarConfig(ent)
	if carCfg then cars[ent] = newCar(ent, carCfg) end

	return true
end

local nextScan, nextSweep, nextRank = 0, 0, 0

local function scanCars(now)
	for ent in pairs(newEnts) do
		if not IsValid(ent) or adopt(ent) then newEnts[ent] = nil end
	end
	if now < nextSweep then return end
	nextSweep = now + SWEEP_INTERVAL
	for _, ent in ipairs(ents.FindByClass("prop_vehicle_jeep*")) do
		adopt(ent)
	end
end

local function stepCar(car, now, dt)
	car.pendingDt = car.pendingDt + dt
	if now < car.nextUpdate then return end
	local step = car.pendingDt
	local interval = TIER_INTERVAL[car.tier]
	car.pendingDt = 0
	-- (spread out by the serial, so the cars of a tier don't all update on the same frame)
	car.nextUpdate = now + interval * (1 + (car.serial % 8) / 64)
	updateCar(car, step)
end

hook.Add("Think", "perpheads/audio-engine/update-cars", function()
	local now = RealTime()
	if now >= nextScan then
		nextScan = now + SCAN_INTERVAL
		scanCars(now)
	end

	local dt = min(FrameTime(), 0.05)
	if dt > 0 then updateListener(dt) end
	if now >= nextRank then
		nextRank = now + RANK_INTERVAL
		rankCars()
	end
	for ent, car in pairs(cars) do
		if not IsValid(ent) then
			stopAll(car)
			cars[ent] = nil
		elseif dt > 0 then
			stepCar(car, now, dt)
		end
	end
	if dt > 0 then probeTunnels(dt) end
end)

hook.Add("OnEntityCreated", "perpheads/audio-engine/find-cars", function(ent)
	if ent:IsVehicle() then newEnts[ent] = true end
end)

local startKey
local function refreshStartKey()
	startKey = _G["KEY_" .. string.upper(cvStartKey:GetString())]
end
refreshStartKey()
cvars.AddChangeCallback("audio_engine_startkey", refreshStartKey, "perpheads/audio-engine/start-key")

-- the start key, read here and sent as a console command: the server's PlayerButtonDown rides on
-- the usercmds, so now and then a press never reached it and the car stayed off
local startHeld = false
hook.Add("Think", "perpheads/audio-engine/start-key", function()
	local down = startKey ~= nil and input.IsKeyDown(startKey)
	local pressed = down and not startHeld
	startHeld = down
	if not pressed then return end
	local ply = LocalPlayer()
	if not IsValid(ply) or not IsValid(ply:GetVehicle()) or ply:IsTyping() then return end
	if gui.IsGameUIVisible() or IsValid(vgui.GetKeyboardFocus()) then return end
	RunConsoleCommand("audio_engine_toggle")
end)

hook.Add("EntityRemoved", "perpheads/audio-engine/forget-cars", function(ent, fullUpdate)
	local car = cars[ent]
	if not car then return end
	stopAll(car)
	cars[ent] = nil
	-- a full update takes the entity away for a moment, it isn't gone
	if fullUpdate then newEnts[ent] = true end
end)

-- for the HUD
function E.GetClientCar(ent)
	return cars[ent]
end

concommand.Add("audio_engine_lod_info", function()
	local tiers, loops = { 0, 0, 0 }, 0
	for _, car in pairs(cars) do
		tiers[car.tier] = tiers[car.tier] + 1
		for _, p in pairs(car.patches) do
			if p:IsPlaying() then loops = loops + 1 end
		end
	end
	print(
		string.format(
			"[Audio Engine] cars: %d full, %d light, %d silent; %d sounds playing",
			tiers[TIER_FULL],
			tiers[TIER_LIGHT],
			tiers[TIER_SILENT],
			loops
		)
	)
end, nil, "Show how many cars play at each detail level and how many sounds that takes")
