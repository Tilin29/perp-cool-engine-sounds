--[[
	Audio Engine - per-car engine sound (client)

	Each client runs the rpm/gear model for every registered car near it (from the car's speed and
	the driver's keys, which the server networks) and plays the generated loops:
	  * two neighbouring rpm bands at a time, pitched to the exact rpm and cross-faded
	  * on/off throttle layers of a band cross-faded by throttle (they share firing phase)
	  * a rev-limiter loop, start-up / shut-down one-shots and overrun pops
]]

local E = AUDIO_ENGINE
local DT = E.Drivetrain
local Bank = E.Bank

local cvVol = CreateClientConVar("audio_engine_volume", "1", true, false, "Engine sound volume (0-2)", 0, 2)
-- sent to the server (userinfo): the key that switches the engine on and off, e.g. i, k, f1, or none
CreateClientConVar("audio_engine_startkey", "i", true, true, "Key that starts/stops the engine of the car you drive (a key name such as i, k or f1; none = off)")
local cvRoad = CreateClientConVar("audio_engine_roadnoise", "1", true, false, "Tyre roar volume (0-2)", 0, 2)
local cvWind = CreateClientConVar("audio_engine_windnoise", "1", true, false, "Wind noise volume (0-2)", 0, 2)
local cvDoppler = CreateClientConVar("audio_engine_doppler", "1", true, false, "Doppler pitch shift of passing cars (0 = off, 0.25 = real, 1 = default, four times real)", 0, 1)
local cvPassby = CreateClientConVar("audio_engine_passby", "1", true, false, "How much other cars swell in loudness as they pass close by (0 = off, 1 = default)", 0, 2)

local cars = {}
E.ClientCars = cars

local min, max, abs, log, sin, cos, pi = math.min, math.max, math.abs, math.log, math.sin, math.cos, math.pi
local band = bit.band

local function approach(x, target, step)
	if x < target then return min(target, x + step) end
	return max(target, x - step)
end

---------------------------------------------------------------------------
-- sound patches
---------------------------------------------------------------------------
local function getPatch(car, name)
	local p = car.patches[name]
	if not p then
		p = CreateSound(car.ent, name)
		p:SetSoundLevel(car.cfg.soundLevel or 85)
		car.patches[name] = p
	end
	return p
end

local function stopAll(car)
	for _, p in pairs(car.patches) do p:Stop() end
	car.patches = {}
	car.active = {}
	car.idleT = {}
	car.cur = {}
	if car.oneshot then car.oneshot.patch:Stop(); car.oneshot = nil end
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
	if nx > cur + step then nx = cur + step elseif nx < cur - step then nx = cur - step end
	return nx
end

local function setGroup(car, key, names, vols, pitch, dt)
	local total = 0
	for i = 1, #vols do total = total + vols[i] end
	local cur = car.cur[key]
	if total > 0.0005 then
		car.idleT[key] = 0
		if not car.active[key] then
			cur = {}
			for i = 1, #names do
				cur[i] = glide(0, vols[i], dt)
				getPatch(car, names[i]):PlayEx(max(cur[i], 0.001), pitch)
			end
			car.cur[key] = cur
			car.active[key] = true
		else
			for i = 1, #names do
				cur[i] = glide(cur[i], vols[i], dt)
				local p = getPatch(car, names[i])
				p:ChangeVolume(max(cur[i], 0.001), 0)
				p:ChangePitch(pitch, 0)
			end
		end
	elseif car.active[key] then
		car.idleT[key] = (car.idleT[key] or 0) + dt
		local loud = 0
		for i = 1, #names do
			cur[i] = glide(cur[i], 0, dt)
			loud = max(loud, cur[i])
			local p = getPatch(car, names[i])
			p:ChangeVolume(max(cur[i], 0.001), 0)
			p:ChangePitch(pitch, 0)
		end
		if loud < 0.002 and car.idleT[key] > 0.3 then
			for i = 1, #names do
				local p = car.patches[names[i]]
				if p then p:Stop() end
			end
			car.active[key] = false
		end
	end
end

local function playOneShot(car, kind, name, vol, pitch, fadeAt, dur)
	if car.oneshot then car.oneshot.patch:FadeOut(0.1) end
	local p = CreateSound(car.ent, name)
	p:SetSoundLevel(car.cfg.soundLevel or 85)
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
	local p = getPatch(car, list[car[key]])
	p:Stop()
	p:PlayEx(math.min(1, vol), math.Clamp(math.random(92, 108) * (car.dop or 1), 20, 255))
end

---------------------------------------------------------------------------
-- car state
---------------------------------------------------------------------------
local function newCar(ent, car)
	return {
		ent = ent, cfg = E.GetEngineConfig(ent), stockCfg = E.ResolveProfile(car), st = DT.New(),
		lastOn = nil, first = true,
		patches = {}, active = {}, idleT = {}, cur = {}, bus = 1, popPk = 0, xr = nil,
		loopGain = 0, thrS = 0, limW = 0,
		-- no two cars are tuned exactly alike: +-1.5% so a row of them doesn't phase
		detune = 1 + (math.random() - 0.5) * 0.03,
		v = 0, lastPos = ent:GetPos(), vel = Vector(0, 0, 0), dop = 1,
	}
end

-- the car's nose direction in local space, from the wheel attachments (falls back to +Y,
-- the usual Source vehicle convention)
local function localForward(car)
	if car.fwdLocal then return car.fwdLocal end
	local ent = car.ent
	local ids = {}
	for _, n in ipairs({ "wheel_fl", "wheel_fr", "wheel_rl", "wheel_rr" }) do
		local id = ent:LookupAttachment(n)
		local a = id and id > 0 and ent:GetAttachment(id)
		if not a then return Vector(0, 1, 0) end
		ids[n] = ent:WorldToLocal(a.Pos)
	end
	local f = (ids.wheel_fl + ids.wheel_fr) - (ids.wheel_rl + ids.wheel_rr)
	f.z = 0
	if f:Length() < 1 then return Vector(0, 1, 0) end
	f:Normalize()
	car.fwdLocal = f
	return f
end

local function readInputs(car)
	local ent = car.ent
	local bits = ent:GetNW2Int("audio_in", 0)
	local f, b, h, s = band(bits, 1) ~= 0, band(bits, 2) ~= 0, band(bits, 4) ~= 0, band(bits, 8) ~= 0
	local ply = LocalPlayer()
	if IsValid(ply) and ply:GetVehicle() == ent then
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

-- the listener (whoever's ears the sound reaches): position and velocity, once per frame
local listener = { pos = Vector(0, 0, 0), vel = Vector(0, 0, 0), ok = false }
local SPEED_OF_SOUND = 343 / 0.0254   -- in inches/s

local function updateListener(dt)
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	local view = GetViewEntity()
	local pos = (IsValid(view) and view ~= ply) and view:GetPos() or ply:EyePos()
	if listener.ok then
		local v = (pos - listener.pos) / dt
		if v:Length() > 6000 then v = listener.vel end          -- teleported / respawned
		listener.vel = listener.vel + (v - listener.vel) * min(1, dt * 8)
	end
	listener.pos = pos
	listener.ok = true
	listener.cabin = IsValid(ply:GetVehicle()) and view == ply
end

-- f' = f (c + v_listener) / (c - v_source), both measured toward each other. At the real speed of
-- sound an 80 mph drive-by only bends 3-4 semitones, which hardly registers in a game, so sound
-- travels slower here: c / (audio_engine_doppler x DOPPLER_BOOST)
local DOPPLER_BOOST = 4
local function dopplerFactor(car, dt, mine)
	local amt = cvDoppler:GetFloat()
	local target = 1
	if amt > 0 and not mine and listener.ok then
		local d = listener.pos - car.ent:GetPos()
		local dist = d:Length()
		if dist > 1 then
			d:Mul(1 / dist)
			local vs = car.vel:Dot(d)            -- source toward listener
			local vl = -listener.vel:Dot(d)      -- listener toward source
			local c = SPEED_OF_SOUND / (amt * DOPPLER_BOOST)
			target = math.Clamp((c + vl) / math.max(c * 0.5, c - vs), 0.6, 1.8)
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
]]
local PASSBY_NEAR, PASSBY_REF, PASSBY_FAR = 2.5 / 0.0254, 5 / 0.0254, 30 / 0.0254   -- inches
local PASSBY_CURVE_SLOW, PASSBY_CURVE_FAST = 0.35, 0.7
local PASSBY_SLOW, PASSBY_FAST, PASSBY_PEAK, PASSBY_LEAD = 5, 30, 0.95, 0.2
local EXHAUST_FRONT_DB, EXHAUST_REAR_DB = 5, 3
local CABIN_DB = 3
local RUSH_FAR, RUSH_SLOW, RUSH_FAST, RUSH_ROAD, RUSH_WIND = 10 / 0.0254, 12, 40, 0.7, 1   -- inches; m/s; volumes
local function proximityGain(car, mine, fwd)
	car.rush = 0
	if mine or not listener.ok then return 1 end
	local cabin = listener.cabin and 10 ^ (-CABIN_DB / 20) or 1
	local amt = cvPassby:GetFloat()
	if amt <= 0 then return cabin end
	local toEar = listener.pos - car.ent:GetPos()
	local dist = toEar:Length()
	local speed = min(car.vel:Length(), (car.vel - listener.vel):Length())   -- inches/s
	local ms = speed * 0.0254
	local d = math.Clamp(dist - speed * PASSBY_LEAD, PASSBY_NEAR, PASSBY_FAR)
	local pace = math.Clamp((ms - PASSBY_SLOW) / (PASSBY_FAST - PASSBY_SLOW), 0, 1)
	local gain
	if d > PASSBY_REF then
		gain = (PASSBY_REF / d) ^ ((PASSBY_CURVE_SLOW + (PASSBY_CURVE_FAST - PASSBY_CURVE_SLOW) * pace) * amt)
	else
		gain = 1 + ((PASSBY_REF / d) ^ amt - 1) * pace
	end
	car.rush = amt * math.Clamp((RUSH_FAR - dist) / (RUSH_FAR - PASSBY_NEAR), 0, 1) ^ 2
		* math.Clamp((ms - RUSH_SLOW) / (RUSH_FAST - RUSH_SLOW), 0, 1)
	if car.cfg.electric or dist < 1 then return gain * cabin end
	local ahead = fwd:Dot(toEar) / dist                     -- 1 in front of the car, -1 behind it
	local db = -ahead * (ahead > 0 and EXHAUST_FRONT_DB or EXHAUST_REAR_DB)
	return gain * cabin * 10 ^ (db * pace * amt / 20)
end

local function updateSound(car, dt)
	local bank, cfg, st, ent = car.bank, car.cfg, car.st, car.ent
	if not bank or not bank.ready then return end

	local master = cvVol:GetFloat() * (cfg.volume or 1)

	-- loops are muted while a start-up one-shot plays, and faded out for shut-down
	local target, rate = 1, 1 / 0.12
	local shot = car.oneshot
	if shot then
		local el = RealTime() - shot.t0
		if shot.kind == "start" then
			if el < shot.fadeAt then
				if st.phase ~= "run" then
					target = 0
				else
					-- driver hit the throttle during the flare: hand over now
					shot.patch:FadeOut(0.12)
					car.oneshot = nil
				end
			else
				rate = 1 / max(0.05, shot.dur - shot.fadeAt)
			end
		end
		if car.oneshot and el > shot.dur + 0.1 then
			shot.patch:Stop()
			car.oneshot = nil
		end
	end
	if not st.on then target, rate = 0, 1 / 0.08 end
	car.loopGain = approach(car.loopGain, target, rate * dt)

	car.thrS = car.thrS + (st.soundThr - car.thrS) * min(1, dt * 12)
	-- the limiter loop only while the throttle is held against it: let go and the revs fall
	-- straight away, so the loop must too (it used to stutter on for its hold time)
	local limTarget = (st.on and st.phase == "run" and st.gear == 0 and st.limHold > 0
		and st.lastPedal and st.rpm > cfg.redline * 0.9) and 1 or 0
	car.limW = approach(car.limW, limTarget, dt / (limTarget > car.limW and 0.06 or 0.03))

	--[[
		Headroom. Everything this car plays is summed by the game and clips (crackles) past
		full scale, so the car's own mix is kept under a ceiling: driving leaves headroom,
		revving in neutral may go a little louder. Loops are normalised to a 0.9 peak; loops
		that aren't phase-locked add up by power. The estimate is by power, but mid cross-fade
		two bands' peaks do line up now and then (up to ~1.4x the estimate on the heavily
		limited V8 / flat-4 banks), so the ceilings leave room for that: at 0.72 / 0.85 most
		engines crackled idling in neutral.
	]]
	local neutral = st.on and st.phase == "run" and st.gear == 0
	local ceiling = neutral and 0.68 or 0.66
	car.ceiling = approach(car.ceiling or 0.66, ceiling, dt * 0.5)
	-- revving in neutral sits a few dB above driving (driving leaves that headroom)
	car.revGain = approach(car.revGain or 0.85, neutral and 1.2 or 0.85, dt * 2)
	local g = master * car.loopGain * car.revGain * (cfg.electric and E.EV_VOLUME or 1)
	local rpm = max(st.rpm, 50)
	local layers = bank.layers
	local n = #layers

	-- equal-power cross-fade between the two bands around the current rpm (log spaced).
	-- The fade position follows the rpm a touch smoothed, so a quick blip doesn't swing the
	-- loop volumes from one frame to the next (the pitch still follows the exact rpm).
	local lr = log(rpm)
	car.xr = car.xr and (car.xr + (lr - car.xr) * min(1, dt * 20)) or lr
	local xrpm = math.exp(car.xr)
	local w = {}
	if xrpm <= layers[1].rpm then
		w[1] = 1
	elseif xrpm >= layers[n].rpm then
		w[n] = 1
	else
		for i = 1, n - 1 do
			if xrpm < layers[i + 1].rpm then
				local t = (car.xr - log(layers[i].rpm)) / (log(layers[i + 1].rpm) - log(layers[i].rpm))
				w[i] = cos(t * pi / 2)
				w[i + 1] = sin(t * pi / 2)
				break
			end
		end
	end

	-- the rolling-noise levels are needed for the headroom estimate
	local env = Bank.env
	local road = cvRoad:GetFloat() * (cfg.volume or 1)
	local wind = cvWind:GetFloat() * (cfg.volume or 1)
	local roadVol, windVol, rr = 0, 0, 0
	if env and env.ready then
		local kmh = abs(car.v) * 3.6
		rr = math.Clamp((kmh - 3) / 120, 0, 1)
		-- the tyre roar eases back again past 60 km/h (about -5 dB from 160 km/h): pitched up and
		-- at full level it was a rushing-air hiss over the engine on fast cars
		roadVol = road * (rr ^ 1.2) * 0.7 * (1 - 0.45 * math.Clamp((kmh - 60) / 100, 0, 1))
		-- wind stays in the background: from 80 km/h, and well under the engine even flat out
		-- (0.06 from 60 km/h roared over the engine on fast cars)
		windVol = wind * math.Clamp((kmh - 80) / 240, 0, 1) ^ 2 * 0.015
	end
	-- each sound's real peak (measured when it was generated); the on/off layers of a band
	-- share their firing phase so they add directly, separate sounds add by power
	local PK = bank.peak or {}
	local function pk(name) return PK[name] or 0.9 end
	-- turbo sounds live in the shared bank (Bank.env): any engine can have them
	local turboOn = cfg.turbo and env and env.ready and env.turbo
	local b = turboOn and (st.boost or 0) or 0
	-- electric: a steady low hum at walking pace (like an EV's pedestrian warning sound), at an
	-- almost fixed pitch; it fades out between ~8% and 20% of top speed (about 15-35 km/h)
	-- while the motor whine, rising with speed, takes over
	local humSpd = rpm / cfg.redline
	local humVol = 0
	if cfg.electric and env and env.ready and env.evhum and st.on and st.phase == "run" then
		local fade = 1 - math.Clamp((humSpd - 0.08) / 0.12, 0, 1)
		local moving = math.Clamp(abs(car.v) / 2, 0, 1)   -- a little softer standing still
		humVol = g * 0.3 * fade * (0.7 + 0.3 * moving)
	end
	local thrE = car.thrS
	local est2 = (car.limW * g * pk(bank.limiter.off)) ^ 2
		+ (humVol * (env and env.peak and env.peak.evhum or 0.3)) ^ 2
		+ (turboOn and (g * b ^ 1.5 * 0.5 * (cfg.profile.turboVol or 1) * (env.peak.turbo or 0.9)) or 0) ^ 2
		+ (env and (roadVol * (env.peak and env.peak.road or 0.3)) or 0) ^ 2
		+ (env and (windVol * (env.peak and env.peak.wind or 0.3)) or 0) ^ 2
	for i = 1, n do
		local L, wi = layers[i], (w[i] or 0) * (1 - car.limW) * g
		if wi > 0 then est2 = est2 + (wi * (thrE * pk(L.on) + (1 - thrE) * pk(L.off))) ^ 2 end
	end
	local est = math.sqrt(est2)
	local busT = est > car.ceiling and car.ceiling / est or 1
	-- pull down quickly, recover slowly
	if busT < car.bus then car.bus = car.bus + (busT - car.bus) * min(1, dt * 30)
	else car.bus = car.bus + (busT - car.bus) * min(1, dt * 3) end
	car.popLoad = (car.popLoad or 0) * math.exp(-dt / 0.08)
	-- the pass-by swell goes on after the headroom, so a car pinned at its ceiling still swells
	local prox = car.prox or 1
	if prox > 1 then
		prox = max(1, min(prox, PASSBY_PEAK / max(est * car.bus, 0.01)))
		car.prox = prox
	end
	car.busPeak = est * car.bus * prox
	g = g * car.bus * prox
	roadVol, windVol, humVol = roadVol * car.bus * prox, windVol * car.bus * prox, humVol * car.bus * prox
	-- after the headroom: the whoosh shouldn't pull the engine down just as it peaks
	local rush = car.rush or 0
	roadVol, windVol = roadVol + road * rush * RUSH_ROAD, windVol + wind * rush * RUSH_WIND

	local thr = car.thrS
	local det = car.detune * (car.dop or 1)
	for i = 1, n do
		local L = layers[i]
		local wi = (w[i] or 0) * (1 - car.limW) * g
		local pitch = math.Clamp(100 * det * rpm / L.rpm, 5, 250)
		local trim = L.trim or 1
		setGroup(car, i, { L.on, L.off }, { wi * thr * trim, wi * (1 - thr) * trim }, pitch, dt)
	end
	-- a family bank (or the stock fallback) may be rendered at another redline: pitch it to ours
	local limPitch = math.Clamp(100 * det * cfg.redline / (bank.limiter.rpm or cfg.redline), 5, 250)
	setGroup(car, "lim", { bank.limiter.off }, { car.limW * g }, limPitch, dt)

	-- turbos: the whistle rises with boost, the blow-off valve sighs when the throttle shuts
	if turboOn then
		local pitch = math.Clamp(100 * det * (0.45 + 0.55 * b) * (0.9 + 0.2 * rpm / cfg.redline), 20, 220)
		-- the turbo sounds are generated 6 dB hot: half volume is the default level, so the
		-- profile's turbo and blow-off volumes can go to 200%
		local turboVol = cfg.profile.turboVol or 1
		setGroup(car, "turbo", { env.turbo }, { g * b ^ 1.5 * 0.5 * turboVol }, pitch, dt)
		local bovVol = cfg.profile.bovVol or 1
		if st.bovEvent and cfg.profile.bov and bovVol > 0 and #env.blowoff > 0 then
			local name = env.blowoff[math.random(#env.blowoff)]
			local vol = g * math.min(1, st.bovEvent * 1.2) * 0.5 * bovVol
			-- headroom, like the pops
			local pk = env.peak[name] or 0.98
			vol = min(1, vol, max(0.05, 0.98 - (car.busPeak or 0) - (car.popLoad or 0)) / max(pk, 0.05))
			car.popLoad = (car.popLoad or 0) + vol * pk
			local p = getPatch(car, name)
			p:Stop()
			p:PlayEx(vol, math.Clamp(math.random(95, 105) * (car.dop or 1), 20, 255))
		end
	elseif car.active.turbo then
		-- turbo switched off in the menu: fade the whistle out
		setGroup(car, "turbo", { env.turbo }, { 0 }, 100, dt)
	end
	if humVol > 0 or car.active.evhum then
		local pitch = math.Clamp(100 * (car.dop or 1) * (1 + 0.12 * math.Clamp(humSpd / 0.2, 0, 1)), 20, 220)
		setGroup(car, "evhum", { env.evhum }, { humVol }, pitch, dt)
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
	local P = cfg.profile.pops or 0
	-- 0.7: about 3 dB over the 0.5 they were baked for (they came out a little too quiet)
	local popVol = master * car.loopGain * 0.7 * (cfg.profile.popVol or 1) * (car.prox or 1)
	if P > 0 and popVol > 0 and #bank.pops > 0 and st.on and st.phase == "run" then
		local red, now = cfg.redline, RealTime()
		local event = P * P
		local overrun = st.soundThr < 0.04 and st.rpm > red * 0.35 and not st.cut
		-- lift-off high in the revs: a burble starts, longer the higher the revs and the more it pops
		if (car.lastThr or 0) > 0.8 and st.thr < 0.5 and st.rpm > red * 0.5 then
			local hi = math.Clamp((st.rpm / red - 0.5) / 0.4, 0, 1)
			car.burbleT0 = now
			car.burbleDur = (0.8 + 2.2 * P) * (0.5 + 0.5 * hi)
			car.popNext = now + 0.12 + 0.18 * math.random()
			car.popBang = math.random() < event * (0.4 + 0.6 * hi)
		end
		if st.soundThr > 0.3 then car.popNext = nil end    -- back on the throttle
		if overrun and car.popNext and now >= car.popNext then
			local age = (now - car.burbleT0) / car.burbleDur
			local inten = (age < 1 and (1 - age) ^ 1.5 or 0) * math.Clamp((st.rpm / red - 0.35) / 0.5, 0, 1)
			if inten > 0.03 then
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
			else
				car.popNext = nil
			end
		end
		-- a long coast at high revs: an odd pop now and then
		if overrun and not car.popNext and st.rpm > red * 0.55 and math.random() < event * 0.25 * dt then
			playPop(car, popVol * (0.4 + 0.3 * math.random()), false)
		end
		-- upshift crack, flat out high in the revs
		if st.gear > (car.lastGear or 0) and (car.lastGear or 0) > 0 and st.shiftKind == 1 and st.thr > 0.8
			and (car.lastRpm or 0) > red * 0.75 and math.random() < event * 0.6 then
			playPop(car, popVol * 0.8, P > 0.7 and math.random() < 0.3)
		end
		-- limiter
		if st.limEvent and math.random() < event then playPop(car, popVol * 0.8, P > 0.7 and math.random() < 0.25) end
	end
	car.lastRpm = st.rpm
	car.lastThr = st.thr
	car.lastGear = st.gear

	-- rolling noise: tyre roar grows with speed, wind takes over on the motorway.
	-- It doesn't depend on the engine running (a coasting car still roars).
	if env and env.ready then
		local dop = car.dop or 1
		setGroup(car, "road", { env.road }, { roadVol }, math.Clamp((75 + 30 * rr) * dop, 20, 255), dt)
		setGroup(car, "wind", { env.wind }, { windVol }, math.Clamp((85 + 35 * rr) * dop, 20, 255), dt)
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
		if prev then prev(self, flags) else self:DrawModel(flags) end
	end
end

local function updateCar(car, dt)
	local ent, st = car.ent, car.st

	if ent:IsDormant() then
		if not car.dormant then stopAll(car); car.dormant = true end
		car.lastPos = ent:GetPos()
		return
	end
	car.dormant = false

	-- follow the car's engine profile (retuned in game); its sounds are generated on demand,
	-- the old engine keeps playing until the new one is ready
	local cfg = E.GetEngineConfig(ent) or car.cfg
	car.cfg = cfg
	local ply = LocalPlayer()
	local mine = IsValid(ply) and ply:GetVehicle() == ent
	local bank = Bank.Get(cfg, car.stockCfg, mine)
	if bank ~= car.bank and bank.ready then
		stopAll(car)
		car.bank = bank
	end

	-- engine switched on / off by the server
	local on = ent:GetNW2Bool("audio_on", false)
	if on ~= car.lastOn then
		if on then
			local age = CurTime() - ent:GetNW2Float("audio_on_t", 0)
			if car.first or age > 2 then
				DT.SkipStart(st, cfg)
				car.loopGain = 1
			else
				DT.Start(st, ent:GetNW2Bool("audio_emo", false))
				car.loopGain = 0
				if car.bank and car.bank.ready then
					local s = st.emotion and car.bank.startEmo or car.bank.start
					playOneShot(car, "start", s.name, cvVol:GetFloat() * (cfg.volume or 1) * (car.prox or 1), 100, s.fadeAt, s.dur)
				end
			end
		else
			if not car.first and st.rpm > 100 and car.bank and car.bank.ready then
				local pitch = math.Clamp(100 * st.rpm / cfg.idle, 70, 160)
				playOneShot(car, "stop", car.bank.stop.name, cvVol:GetFloat() * (cfg.volume or 1) * (car.prox or 1), pitch, 0, car.bank.stop.dur)
			end
			DT.Stop(st)
			if car.first then st.rpm = 0 end
		end
		car.lastOn = on
	end
	car.first = false

	-- speed along the nose, from position change (works for every car, not just our own)
	local pos = ent:GetPos()
	local fwd = Vector(localForward(car))
	fwd:Rotate(ent:GetAngles())
	local delta = pos - car.lastPos
	local vRaw = delta:Dot(fwd) / dt * 0.0254 -- inches/s -> m/s
	car.lastPos = pos
	if abs(vRaw) > 150 then
		vRaw = car.v                                         -- teleported
	else
		car.vel = car.vel + (delta / dt - car.vel) * min(1, dt * 8)
	end
	car.v = car.v + (vRaw - car.v) * min(1, dt * 10)
	-- driving it but watching from a camera, you hear it from outside like anyone else
	local inside = mine and GetViewEntity() == ply
	dopplerFactor(car, dt, inside)
	car.prox = proximityGain(car, inside, fwd)

	-- the gearbox follows the wheels, and in a slide they still roll at the car's full speed: the
	-- speed along the nose collapsed as the car went sideways, the revs plunged and shot back up
	-- as it straightened (a cartoon "weee-ooo"). Full speed, signed by the nose, unless it has
	-- turned mostly backwards or sideways (a spin)
	local vFull = car.vel:Length() * 0.0254
	local vDrive = car.v
	if vFull > 2 and abs(car.v) > vFull * 0.3 then vDrive = (car.v >= 0 and 1 or -1) * vFull end
	car.vDrive = car.vDrive and car.vDrive + (vDrive - car.vDrive) * min(1, dt * 10) or vDrive

	local f, b, h, s, cr = readInputs(car)
	DT.Step(st, cfg, dt, { fwd = f, back = b, hand = h, steer = s, v = car.vDrive, cruise = cr })

	updateSound(car, dt)

	-- the model's own dashboard tach needle follows the revs. Cars whose wings/vents also hang off
	-- that pose (E.GAUGE_PARTS) are left alone: the server sets it from speed (sv_engine.lua),
	-- over Source's own speedometer value, and networks it
	if cfg.gaugeParts then
		ent.audioGuage = nil
	else
		local maxR = math.ceil((cfg.redline + 500) / 1000) * 1000
		ent.audioGuage = math.Clamp(st.rpm / maxR, 0, 1)
	end
	guageOverride(ent)
end

---------------------------------------------------------------------------
-- tracking
---------------------------------------------------------------------------
local nextScan = 0
hook.Add("Think", "audio_engine_cars", function()
	local now = RealTime()
	if now >= nextScan then
		nextScan = now + 0.5
		for _, ent in ipairs(ents.FindByClass("prop_vehicle_jeep*")) do
			if not cars[ent] then
				local carCfg = E.GetCarConfig(ent)
				if carCfg then cars[ent] = newCar(ent, carCfg) end
			end
		end
	end

	local dt = min(FrameTime(), 0.05)
	if dt > 0 then updateListener(dt) end
	for ent, car in pairs(cars) do
		if not IsValid(ent) then
			stopAll(car)
			cars[ent] = nil
		elseif dt > 0 then
			updateCar(car, dt)
		end
	end
end)

hook.Add("EntityRemoved", "audio_engine_cars", function(ent)
	local car = cars[ent]
	if car then
		stopAll(car)
		cars[ent] = nil
	end
end)

-- for the HUD
function E.GetClientCar(ent)
	return cars[ent]
end
