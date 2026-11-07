--[[
	Audio Engine - server side
	Switches the engine on/off as drivers get in and out, and networks the driver's
	throttle/brake/handbrake keys so every client can run the rpm model and sound.

	Per-car state goes out as NW2 vars, against the style guide's "no NW2": SetNW* reaches every
	client whether the car is near them or not and re-sends every value each 10 seconds, which
	at 128 players and a hundred cars is a lot more traffic than the PVS-limited, on-change NW2.
	The car classes here are engine entities, which NW2 has no known trouble with.

	A native Source car costs no Lua at all, so nothing here may scale with the cars parked around
	the map: tracked is every registered car, active (E.ActiveVehicles) only those being driven
	or settling after it. Everything that runs each tick loops over active.
]]

local E = PerpAudioEngine

-- not archived: an old saved "0" (the default before) kept switching engines off; set it in server.cfg to change it
local cvKeep = CreateConVar(
	"audio_engine_keeprunning",
	"1",
	FCVAR_NONE,
	"1 = cars keep idling after the driver gets out (the driver switches them off); 0 = getting out "
		.. "switches the engine off"
)
local cvIdleOff = CreateConVar(
	"audio_engine_idletimeout",
	"180",
	FCVAR_ARCHIVE,
	"Seconds an empty car keeps idling before its engine stops (0 = it never does): a car park of "
		.. "idling engines costs every client nearby sound channels"
)
local cvEmotion = CreateConVar(
	"audio_engine_emotionstart",
	"1",
	FCVAR_ARCHIVE,
	"1 = rev flare on start-up (Rev Bench 'emotion start')"
)
local cvAuto = CreateConVar(
	"audio_engine_autostart",
	"0",
	FCVAR_ARCHIVE + FCVAR_REPLICATED,
	"1 = the engine starts by itself when a driver gets in; 0 = the driver starts it (start key or "
		.. "audio_engine_toggle)"
)

local tracked = {}
E.TrackedVehicles = tracked
local active = E.ActiveVehicles

local SETTLE_TIME = 3 -- s a car stays active after its driver left, for wings and traction to reset
local SETTLE_SPEED = 40 -- inches/s: still rolling faster than this, it stays active
local HOUSEKEEPING_INTERVAL = 1

local function isOurs(ent)
	-- (a seat on a car's model is a vehicle too, without an engine or params)
	return IsValid(ent) and string.StartsWith(ent:GetClass(), "prop_vehicle_jeep") and E.GetCarConfig(ent) ~= nil
end

local function activate(veh)
	active[veh] = true
	veh.audioSettleT = CurTime() + SETTLE_TIME
end

---------------------------------------------------------------------------
-- real performance: the profile's acceleration and top speed are applied to the car's
-- physics (Source vehicle params), starting from what its own vehicle script set up
---------------------------------------------------------------------------
local HU_PER_MPH = E.HU_PER_MPH -- GetVehicleParams speeds are inches/s (sv_handling.lua: E.SetParams)
local KMH_PER_MPH = 1.609344

local function captureBase(veh)
	if veh.audioBase then return veh.audioBase end
	local params = E.ReadParams(veh)
	if not params then return nil end
	veh.audioBase = table.Copy(params)
	-- the car's own top speed, for "fit gearing" and the menu
	if (params.engine.maxSpeed or 0) > 0 then
		veh:SetNW2Float("audio_vmax", params.engine.maxSpeed / HU_PER_MPH * KMH_PER_MPH)
	end

	return veh.audioBase
end

function E.ApplyPerformance(veh, prof)
	local base = captureBase(veh)
	if not base then return end
	local accel = prof and prof.accel or 1
	local vmax = prof and prof.vmax or 0
	-- traction control comes through here many times a second: a copy of the params made once
	-- per car, with only the fields below ever changed in it
	local p = veh.audioParams
	if not p then
		p = table.Copy(base)
		veh.audioParams = p
	end
	-- audioCruisePow: cruise control's power trim (sv_cruise.lua, sv_handling.lua)
	-- audioTC: launch traction control's power trim; audioSteerLock: the lock at speed (sv_handling.lua)
	p.engine.horsepower = base.engine.horsepower * accel * (veh.audioTC or 1) * (veh.audioCruisePow or 1)
	if p.steering and p.steering.degreesFast and veh.audioSteerLock then
		p.steering.degreesFast = base.steering.degreesFast * veh.audioSteerLock
	end
	p.engine.maxSpeed = vmax > 0 and vmax / KMH_PER_MPH * HU_PER_MPH or base.engine.maxSpeed
	E.SetParams(veh, p)
end

local function track(ent)
	if not isOurs(ent) then return end
	tracked[ent] = true
	-- PERP physics on the test script and the anti-spin setup (sv_handling.lua), before the
	-- car's physics are captured as the base the tuning menu works from
	E.PrepareHandling(ent)
	captureBase(ent)
	-- after a lua refresh, a car that is already running stays drivable
	if ent.audioDrivable == nil then ent.audioDrivable = ent:GetNW2Bool("audio_on", false) end
	local prof = E.DecodeProfile(ent:GetNW2String("audio_prof", ""))
	if prof then E.ApplyPerformance(ent, prof) end
	-- a moment of attention as it spawns: wings tuck into their resting place
	activate(ent)
end

hook.Add("OnEntityCreated", "perpheads/audio-engine/track-cars", function(ent)
	if not ent:IsVehicle() then return end
	timer.Simple(0, function()
		track(ent)
	end)
end)

--[[
	Ignition. With the engine off the car is silent and can't drive. Switching it on runs the
	start-up sequence (crank, catch, rev flare, settle to idle); the car only drives once that
	has finished. The server runs the same start-up model as the clients (sh_drivetrain.lua),
	so the car is released exactly when the sound reaches idle.
]]
local DT = E.Drivetrain

-- whether Source may drive the car: engine on and the start-up sequence finished
local function setDrivable(veh, ok)
	veh.audioDrivable = ok
	veh:EnableEngine(ok)
	veh:StartEngine(ok)
end

-- rev flare on start-up: only cars listed as high-powered (sh_carlist.lua CAR_EMOTION)
local function wantsEmotion(veh)
	local car = E.GetCarConfig(veh)

	return cvEmotion:GetBool() and car ~= nil and car.emotionStart == true
end

local function setEngine(veh, on, instant)
	activate(veh)
	if not on then
		veh:SetNW2Bool("audio_on", false)
		veh.audioStart = nil
		setDrivable(veh, false)
		return
	end
	-- audio_on last: a client that sees it should find the rest already there
	local emotion = wantsEmotion(veh)
	veh:SetNW2Float("audio_on_t", CurTime())
	veh:SetNW2Bool("audio_emo", emotion)
	veh:SetNW2Bool("audio_on", true)
	if instant then
		veh.audioStart = nil
		setDrivable(veh, true)
		return
	end
	local st = DT.New()
	DT.Start(st, emotion)
	veh.audioStart = st
	setDrivable(veh, false)
end
E.SetEngine = setEngine

function E.ToggleEngine(veh)
	setEngine(veh, not veh:GetNW2Bool("audio_on", false))
end

hook.Add("PlayerEnteredVehicle", "perpheads/audio-engine/ignition", function(_, veh)
	if not isOurs(veh) then return end
	tracked[veh] = true
	activate(veh)
	veh.audioLeftT = nil
	local running = veh:GetNW2Bool("audio_on", false)
	if running then
		-- still idling (audio_engine_keeprunning): drive off straight away, unless it's mid start-up
		setDrivable(veh, veh.audioStart == nil)
	elseif cvAuto:GetBool() then
		setEngine(veh, true)
	else
		setDrivable(veh, false)
	end
	-- Source starts the engine as you get in; switch it back off after that has happened
	timer.Simple(0, function()
		if IsValid(veh) then setDrivable(veh, veh.audioDrivable and true or false) end
	end)
end)

hook.Add("PlayerLeaveVehicle", "perpheads/audio-engine/ignition", function(_, veh)
	if not tracked[veh] then return end
	activate(veh)
	veh.audioLeftT = CurTime()
	if not cvKeep:GetBool() then setEngine(veh, false) end
end)

-- the start key (audio_engine_startkey, read by cl_engine.lua) sends this too;
-- bindable: `bind <key> audio_engine_toggle`
-- Nothing is heard until the server's answer is back, so a second press can come in right after
-- the first: for START_LOCK s it doesn't count, or it would switch the engine straight off again
local START_LOCK = 1.5
local TOGGLE_COOLDOWN = 0.4
concommand.Add("audio_engine_toggle", function(ply)
	if not IsValid(ply) then return end
	local veh = ply:GetVehicle()
	if not IsValid(veh) or not tracked[veh] or veh:GetDriver() ~= ply then return end
	local now = CurTime()
	if (ply.audioKeyNext or 0) > now then return end
	ply.audioKeyNext = now + TOGGLE_COOLDOWN
	if veh:GetNW2Bool("audio_on", false) and now - veh:GetNW2Float("audio_on_t", 0) < START_LOCK then return end
	E.ToggleEngine(veh)
end, nil, "Switch the engine of the car you're driving on or off")

local function networkInputs(veh, drv)
	local bits = 0
	if IsValid(drv) then
		if drv:KeyDown(IN_FORWARD) then bits = bits + 1 end
		if drv:KeyDown(IN_BACK) then bits = bits + 2 end
		if drv:KeyDown(IN_JUMP) then bits = bits + 4 end
		if drv:KeyDown(IN_MOVELEFT) ~= drv:KeyDown(IN_MOVERIGHT) then bits = bits + 8 end -- steering
	end
	if bits == veh.audioInBits then return end
	veh.audioInBits = bits
	veh:SetNW2Int("audio_in", bits)
end

-- start-up in progress: release the car once it has settled to idle
local function runStartUp(veh, st)
	local cfg = E.GetEngineConfig(veh)
	if not cfg then return end
	DT.StartSequence(st, cfg, FrameTime())
	if st.phase ~= "run" then return end
	veh.audioStart = nil
	setDrivable(veh, veh:GetNW2Bool("audio_on", false))
end

hook.Add("Think", "perpheads/audio-engine/drive-cars", function()
	for veh in pairs(active) do
		if IsValid(veh) then
			local drv = veh:GetDriver()
			networkInputs(veh, drv)
			if veh.audioStart then runStartUp(veh, veh.audioStart) end
			-- keep Source from driving a car whose engine is off or still starting
			local want = veh.audioDrivable and true or false
			if IsValid(drv) and veh:IsEngineEnabled() ~= want then setDrivable(veh, want) end
		end
	end
end)

local function settled(veh, now)
	if IsValid(veh:GetDriver()) or veh.audioStart then return false end
	if now < (veh.audioSettleT or 0) or (veh.audioFlapShow or 0) > now then return false end
	local phys = veh:GetPhysicsObject()

	return not IsValid(phys) or phys:GetVelocity():Length() < SETTLE_SPEED
end

local function stopIdling(veh, now, timeout)
	if timeout <= 0 or not veh.audioLeftT or now - veh.audioLeftT < timeout then return end
	veh.audioLeftT = nil
	if veh:GetNW2Bool("audio_on", false) and not IsValid(veh:GetDriver()) then setEngine(veh, false) end
end

timer.Create("perpheads/audio-engine/housekeeping", HOUSEKEEPING_INTERVAL, 0, function()
	local now = CurTime()
	local timeout = cvIdleOff:GetFloat()
	for veh in pairs(tracked) do
		if not IsValid(veh) then
			tracked[veh], active[veh] = nil, nil
		else
			stopIdling(veh, now, timeout)
			if active[veh] and settled(veh, now) then active[veh] = nil end
		end
	end
end)

-- lua refresh
for _, ent in ents.Iterator() do
	track(ent)
end

---------------------------------------------------------------------------
-- engine tuning (the in-game Rev Bench menu)
---------------------------------------------------------------------------
local NET_SET_PROFILE = "perpheads/audio-engine/set-profile"
util.AddNetworkString(NET_SET_PROFILE)

local cvAccess = CreateConVar(
	"audio_engine_tuneaccess",
	"1",
	FCVAR_ARCHIVE + FCVAR_REPLICATED,
	"Who can retune car engines: 0 = whoever is driving, 1 = admins, 2 = superadmins"
)
local cvCooldown = CreateConVar(
	"audio_engine_tunecooldown",
	"5",
	FCVAR_ARCHIVE,
	"Seconds between engine changes per player (each change makes nearby clients generate sounds)"
)

local TUNE_REACH = 400 -- inches: must be in the car or standing this close
local TUNE_REQUEST_COOLDOWN = 0.25 -- s between requests, allowed or not

function E.CanTune(ply, veh)
	local access = cvAccess:GetInt()
	if access >= 2 then return ply:IsSuperAdmin() end
	if access == 1 then return ply:IsAdmin() end

	return ply:GetVehicle() == veh
end

net.Receive(NET_SET_PROFILE, function(_, ply)
	local now = CurTime()
	if (ply.audioTuneRequestNext or 0) > now then return end
	ply.audioTuneRequestNext = now + TUNE_REQUEST_COOLDOWN

	local veh = net.ReadEntity()
	local str = net.ReadString()
	if not IsValid(veh) or not tracked[veh] then return end
	if not E.CanTune(ply, veh) then
		ply:ChatPrint("[Audio Engine] You're not allowed to retune engines.")
		return
	end
	if ply:GetVehicle() ~= veh and ply:GetPos():DistToSqr(veh:GetPos()) > TUNE_REACH * TUNE_REACH then return end
	if (ply.audioTuneNext or 0) > now then
		local wait = ply.audioTuneNext - now
		ply:ChatPrint(string.format("[Audio Engine] Wait %.0f s before changing the engine again.", wait))
		return
	end
	ply.audioTuneNext = now + cvCooldown:GetFloat()

	if str == "" then
		veh:SetNW2String("audio_prof", "") -- back to stock
		E.ApplyPerformance(veh, nil)
		return
	end
	local prof = E.DecodeProfile(str)
	if not prof then return end
	veh:SetNW2String("audio_prof", E.EncodeProfile(prof))
	E.ApplyPerformance(veh, prof)
end)

hook.Add("PlayerSay", "perpheads/audio-engine/open-menu", function(ply, text)
	local t = string.lower(string.Trim(text))
	if t == "!engine" or t == "/engine" then
		ply:ConCommand("audio_engine_menu")
		return ""
	end
end)

hook.Add("PlayerSpawnedVehicle", "perpheads/audio-engine/job-skin", function(_, veh)
	local vt = veh.VehicleTable
	if istable(vt) and vt.AudioSkin and vt.AudioSkin > 0 then veh:SetSkin(vt.AudioSkin) end
end)

--[[
	Wings and vents (E.GAUGE_PARTS cars): their parts hang off the vehicle_guage pose, which
	Source sets from speed / the script's top speed in the driver's move (the Murcielago's vents
	opened from half its top speed, the R8 Plus folded its wing away near the top). That pose can't
	be held from here: on a real server Source's write and ours both reached the clients and the
	parts stuttered. So the server only picks the position, in steps so it's sent a few times a
	second at most, and cl_engine sets the pose right before the car is drawn, like the tach needle.
	Brake wings (E.BRAKE_WINGS: P1, SLR) are moved here too, through bone manipulation.
]]
local function glide(cur, want, up, down)
	return cur + math.Clamp(want - cur, -down, up)
end

local function vec(t)
	return t and Vector(t[1], t[2], t[3]) or nil
end
local function ang(t)
	return t and Angle(t[1], t[2], t[3]) or nil
end

-- bone manipulations scaled by frac, re-sent only when frac moved enough to see (they're networked)
local function manip(veh, key, bone, frac, pos, an)
	local id = veh:LookupBone(bone)
	if not id then return end
	veh.audioManipSent = veh.audioManipSent or {}
	local sent = veh.audioManipSent[key]
	if sent and math.abs(frac - sent) < 0.01 and (frac > 0 or sent == 0) then return end
	veh.audioManipSent[key] = frac
	if pos then veh:ManipulateBonePosition(id, vec(pos) * frac) end
	if an then veh:ManipulateBoneAngles(id, ang(an) * frac) end
end

local function brakeWing(veh, bw, kmh, top, dt, braking)
	local up = E.WingSpeedUp(veh, kmh, top)
	veh.audioBrakeT = braking and (veh.audioBrakeT or 0) + dt or 0
	local flapOn = veh.audioBrakeT >= E.WING_BRAKE_HOLD or (veh.audioFlapShow or 0) > CurTime() -- (wingflap preview)
	if bw.tuck then
		-- the wing rises out of its tucked place (speed rules, or the flap needs it up)
		local m = glide(veh.audioMainFrac or 0, (up or flapOn) and 1 or 0, dt * E.WING_MAIN_RATE, dt * E.WING_MAIN_RATE)
		veh.audioMainFrac = m
		for i, t in ipairs(bw.tuck) do
			manip(veh, "tuck" .. i, t.bone, 1 - m, t.pos, t.ang)
		end
	end
	local fl = glide(veh.audioFlapFrac or 0, flapOn and 1 or 0, dt * E.WING_FLAP_RATE, dt * E.WING_FLAP_RATE * 0.5)
	veh.audioFlapFrac = fl
	if bw.flapPose then
		veh:SetPoseParameter(bw.flapPose, fl)
	elseif bw.flapBone then
		manip(veh, "flap", bw.flapBone, fl, nil, bw.flapAng)
	end
end

local WING_STEP = 0.02
local KMH_PER_INCH_S = 0.09144

local function updateWings(veh, car, dt)
	local gp, bw = car.gaugeParts, car.brakeWing
	local phys = veh:GetPhysicsObject()
	local kmh = IsValid(phys) and phys:GetVelocity():Length() * KMH_PER_INCH_S or 0
	local top = E.CarTopSpeed(veh, car)
	if gp then veh:SetNW2Float("audio_wing", math.Round(E.WingPose(veh, gp, kmh, top) / WING_STEP) * WING_STEP) end
	if not bw then return end
	local drv = veh:GetDriver()
	local braking = IsValid(drv)
		and drv:KeyDown(IN_BACK)
		and not drv:KeyDown(IN_FORWARD)
		and kmh > E.WING_BRAKE_MPH * KMH_PER_MPH
	brakeWing(veh, bw, kmh, top, dt, braking)
end

hook.Add("Tick", "perpheads/audio-engine/wings", function()
	local dt = engine.TickInterval()
	for veh in pairs(active) do
		local car = IsValid(veh) and E.GetCarConfig(veh)
		if car and (car.gaugeParts or car.brakeWing) then updateWings(veh, car, dt) end
	end
end)

--[[
	Tuning wings in game (superadmin, or the host in single player), on the car you sit in or look at:
	  audio_engine_wingflap      shows the brake flap for 10 s
	  audio_engine_bonedump      the car's bone manipulations (e.g. from the sandbox bone editor),
	                             printed and written to data/audio_engine_bones.txt
	To place a tucked wing: park the car, move the bones with the bone editor, run bonedump and put
	the values into E.BRAKE_WINGS (tuck = { bone, pos, ang }).
]]
local function tuneTarget(ply)
	if IsValid(ply) and not ply:IsSuperAdmin() and not (game.SinglePlayer() or ply:IsListenServerHost()) then return end
	if not IsValid(ply) then return end
	local veh = ply:GetVehicle()
	if not (IsValid(veh) and E.GetCarConfig(veh)) then veh = ply:GetEyeTrace().Entity end
	return IsValid(veh) and veh or nil
end

concommand.Add("audio_engine_wingflap", function(ply)
	local veh = tuneTarget(ply)
	local car = veh and E.GetCarConfig(veh)
	if not (car and car.brakeWing) then
		if IsValid(ply) then
			ply:PrintMessage(HUD_PRINTTALK, "[Audio Engine] sit in or look at a brake-wing car (P1, SLR)")
		end
		return
	end
	veh.audioFlapShow = CurTime() + 10
	activate(veh)
end)

concommand.Add("audio_engine_bonedump", function(ply)
	local veh = tuneTarget(ply)
	if not veh then return end
	local car = E.GetCarConfig(veh)
	local lines = { string.format("%s  %s", car and car.name or veh:GetClass(), veh:GetModel()) }
	for id = 0, veh:GetBoneCount() - 1 do
		local p, a = veh:GetManipulateBonePosition(id), veh:GetManipulateBoneAngles(id)
		if not p:IsZero() or not a:IsZero() then
			lines[#lines + 1] = string.format(
				"{ bone = \"%s\", pos = { %g, %g, %g }, ang = { %g, %g, %g } },",
				veh:GetBoneName(id),
				math.Round(p.x, 2),
				math.Round(p.y, 2),
				math.Round(p.z, 2),
				math.Round(a.p, 2),
				math.Round(a.y, 2),
				math.Round(a.r, 2)
			)
		end
	end
	if #lines == 1 then lines[2] = "(no bone manipulations)" end
	file.Write("audio_engine_bones.txt", table.concat(lines, "\n") .. "\n")
	for _, l in ipairs(lines) do
		ply:PrintMessage(HUD_PRINTCONSOLE, l .. "\n")
	end
	ply:PrintMessage(HUD_PRINTTALK, "[Audio Engine] bones written to data/audio_engine_bones.txt")
end)
