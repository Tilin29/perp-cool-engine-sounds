--[[
	Audio Engine - server side
	Switches the engine on/off as drivers get in and out, and networks the driver's
	throttle/brake/handbrake keys so every client can run the rpm model and sound.
]]

local E = AUDIO_ENGINE

local cvKeep = CreateConVar("audio_engine_keeprunning", "0", FCVAR_ARCHIVE,
	"1 = cars keep idling after the driver gets out")
local cvEmotion = CreateConVar("audio_engine_emotionstart", "1", FCVAR_ARCHIVE,
	"1 = rev flare on start-up (Rev Bench 'emotion start')")
local cvAuto = CreateConVar("audio_engine_autostart", "0", FCVAR_ARCHIVE + FCVAR_REPLICATED,
	"1 = the engine starts by itself when a driver gets in; 0 = the driver starts it (start key or audio_engine_toggle)")

local tracked = {}
E.TrackedVehicles = tracked

local function isOurs(ent)
	return IsValid(ent) and ent:IsVehicle() and E.GetCarConfig(ent) ~= nil
end

---------------------------------------------------------------------------
-- real performance: the profile's acceleration and top speed are applied to the car's
-- physics (Source vehicle params), starting from what its own vehicle script set up
---------------------------------------------------------------------------
local HU_PER_MPH = E.HU_PER_MPH   -- GetVehicleParams speeds are inches/s (sv_handling.lua: E.SetParams)

local function captureBase(veh)
	if veh.audioBase then return veh.audioBase end
	local ok, params = pcall(veh.GetVehicleParams, veh)
	if not ok or not istable(params) or not istable(params.engine) then return nil end
	veh.audioBase = table.Copy(params)
	-- the car's own top speed, for "fit gearing" and the menu
	if (params.engine.maxSpeed or 0) > 0 then
		veh:SetNW2Float("audio_vmax", params.engine.maxSpeed / HU_PER_MPH * 1.609344)
	end
	return veh.audioBase
end

function E.ApplyPerformance(veh, prof)
	local base = captureBase(veh)
	if not base then return end
	local accel = prof and prof.accel or 1
	local vmax = prof and prof.vmax or 0
	local p = table.Copy(base)
	p.engine.horsepower = base.engine.horsepower * accel
	if vmax > 0 then p.engine.maxSpeed = vmax / 1.609344 * HU_PER_MPH end
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
end

hook.Add("OnEntityCreated", "audio_engine", function(ent)
	timer.Simple(0, function() track(ent) end)
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
	if veh.EnableEngine then pcall(veh.EnableEngine, veh, ok) end
	if veh.StartEngine then pcall(veh.StartEngine, veh, ok) end
end

-- rev flare on start-up: only cars listed as high-powered (sh_carlist.lua CAR_EMOTION)
local function wantsEmotion(veh)
	local car = E.GetCarConfig(veh)
	return cvEmotion:GetBool() and car ~= nil and car.emotionStart == true
end

local function setEngine(veh, on, instant)
	veh:SetNW2Bool("audio_on", on)
	if on then
		local emotion = wantsEmotion(veh)
		veh:SetNW2Float("audio_on_t", CurTime())
		veh:SetNW2Bool("audio_emo", emotion)
		if instant then
			veh.audioStart = nil
			setDrivable(veh, true)
		else
			local st = DT.New()
			DT.Start(st, emotion)
			veh.audioStart = st
			setDrivable(veh, false)
		end
	else
		veh.audioStart = nil
		setDrivable(veh, false)
	end
end
E.SetEngine = setEngine

function E.ToggleEngine(veh)
	setEngine(veh, not veh:GetNW2Bool("audio_on", false))
end

hook.Add("PlayerEnteredVehicle", "audio_engine", function(ply, veh)
	if not isOurs(veh) then return end
	tracked[veh] = true
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

hook.Add("PlayerLeaveVehicle", "audio_engine", function(ply, veh)
	if not tracked[veh] then return end
	if not cvKeep:GetBool() then setEngine(veh, false) end
end)

-- bindable: `bind <key> audio_engine_toggle`
concommand.Add("audio_engine_toggle", function(ply)
	if not IsValid(ply) then return end
	local veh = ply:GetVehicle()
	if not tracked[veh] or veh:GetDriver() ~= ply then return end
	E.ToggleEngine(veh)
end, nil, "Switch the engine of the car you're driving on or off")

-- the start key: each player picks theirs with audio_engine_startkey (default I)
hook.Add("PlayerButtonDown", "audio_engine", function(ply, button)
	local veh = ply:GetVehicle()
	if not IsValid(veh) or not tracked[veh] or veh:GetDriver() ~= ply then return end
	local name = string.upper(ply:GetInfo("audio_engine_startkey") or "I")
	if name == "" or name == "NONE" then return end
	local key = _G["KEY_" .. name]
	if key and button == key then
		if (ply.audioKeyNext or 0) > CurTime() then return end
		ply.audioKeyNext = CurTime() + 0.4
		E.ToggleEngine(veh)
	end
end)

hook.Add("Think", "audio_engine", function()
	for veh in pairs(tracked) do
		if not IsValid(veh) then
			tracked[veh] = nil
		else
			local drv = veh:GetDriver()
			local bits = 0
			if IsValid(drv) then
				if drv:KeyDown(IN_FORWARD) then bits = bits + 1 end
				if drv:KeyDown(IN_BACK) then bits = bits + 2 end
				if drv:KeyDown(IN_JUMP) then bits = bits + 4 end
			end
			if bits ~= veh.audioInBits then
				veh.audioInBits = bits
				veh:SetNW2Int("audio_in", bits)
			end
			-- start-up in progress: release the car once it has settled to idle
			local st = veh.audioStart
			if st then
				local cfg = E.GetEngineConfig(veh)
				if cfg then
					DT.StartSequence(st, cfg, FrameTime())
					if st.phase == "run" then
						veh.audioStart = nil
						setDrivable(veh, veh:GetNW2Bool("audio_on", false))
					end
				end
			end
			-- keep Source from driving a car whose engine is off or still starting
			if IsValid(drv) and veh.IsEngineEnabled then
				local want = veh.audioDrivable and true or false
				local okE, en = pcall(veh.IsEngineEnabled, veh)
				if okE and en ~= want then setDrivable(veh, want) end
			end
		end
	end
end)

-- lua refresh
for _, ent in ipairs(ents.GetAll()) do track(ent) end

---------------------------------------------------------------------------
-- engine tuning (the in-game Rev Bench menu)
---------------------------------------------------------------------------
util.AddNetworkString("audio_engine_set")

local cvAccess = CreateConVar("audio_engine_tuneaccess", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED,
	"Who can retune car engines: 0 = whoever is driving, 1 = admins, 2 = superadmins")
local cvCooldown = CreateConVar("audio_engine_tunecooldown", "5", FCVAR_ARCHIVE,
	"Seconds between engine changes per player (each change makes nearby clients generate sounds)")

function E.CanTune(ply, veh)
	local access = cvAccess:GetInt()
	if access >= 2 then return ply:IsSuperAdmin() end
	if access == 1 then return ply:IsAdmin() end
	return ply:GetVehicle() == veh
end

net.Receive("audio_engine_set", function(_, ply)
	local veh = net.ReadEntity()
	local str = net.ReadString()
	if not IsValid(veh) or not tracked[veh] then return end
	if not E.CanTune(ply, veh) then
		ply:ChatPrint("[Audio Engine] You're not allowed to retune engines.")
		return
	end
	-- must be in the car or standing next to it
	if ply:GetVehicle() ~= veh and ply:GetPos():DistToSqr(veh:GetPos()) > 400 * 400 then return end
	local now = CurTime()
	if (ply.audioTuneNext or 0) > now then
		ply:ChatPrint(string.format("[Audio Engine] Wait %.0f s before changing the engine again.", ply.audioTuneNext - now))
		return
	end
	ply.audioTuneNext = now + cvCooldown:GetFloat()

	if str == "" then
		veh:SetNW2String("audio_prof", "")      -- back to stock
		E.ApplyPerformance(veh, nil)
		return
	end
	local prof = E.DecodeProfile(str)
	if not prof then return end
	veh:SetNW2String("audio_prof", E.EncodeProfile(prof))
	E.ApplyPerformance(veh, prof)
end)

hook.Add("PlayerSay", "audio_engine", function(ply, text)
	local t = string.lower(string.Trim(text))
	if t == "!engine" or t == "/engine" then
		ply:ConCommand("audio_engine_menu")
		return ""
	end
end)
