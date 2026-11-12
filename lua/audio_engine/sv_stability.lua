--[[
	Audio Engine - stability control (server)

	Works like a real car's stability control, but arcade-friendly. Every tick, for each driven
	registered car, it works out how fast the car SHOULD be rotating for the driver's steering keys
	(A/D) at this speed, and compares that with how fast it IS rotating:

	  * rotating more than asked (oversteer, a spin starting)  -> catches it. With the handbrake
	    held it allows a lot more, so handbrake drifts still work.
	  * rotating against the steering (a snap the other way)  -> helps stop the rotation
	  * rotating less than asked (pushing wide, understeer)    -> adds turn-in, up to turnShare of
	    the asked rotation; braking (locked front tyres plough on) up to brakeTurn, applied firmer
	  * last-resort guard: if the tail still slides out past the drift angle, it slows the
	    rotation down (it never turns a sliding car's travel: that launched it where the nose pointed)
	  * lateral grip: without the handbrake, extra tyre grip (gripAssist g) takes sideways speed
	    away at any slip angle; the forward speed is never touched, so it can't launch the car
	  * how much the car is sliding (0..1, veh.audioSlide) goes to traction control
	    (sv_handling.lua), which takes power away: a strong car stepping out under throttle
	    keeps sliding as long as it has full power, whatever the yaw correction does
	  * slip limit: steering without the handbrake keeps the tail-out slip angle near slipMax
	    (the nose rotates no faster than the car's path), so fast corners turn instead of drift
	  * straight-line hold: throttle with no steering (and no handbrake/drift) keeps the car
	    on its heading at any speed, from a standstill, and any rotation cuts the power

	A drift starts with the handbrake and lasts as long as the car stays sideways (past
	driftHold degrees), handbrake held or not. While drifting the car may slide and rotate
	freely, counter-steering holds the angle instead of being fought, and only a real spin
	(past handbrakeAngle) is caught.

	It never reacts to the normal angle of a car going round a tight bend (the body naturally
	points a little across its path at low speed), only to the tail stepping OUT.
	It only acts on the ground, moving forward, above minSpeed.
]]

local E = AUDIO_ENGINE

local cvOn = CreateConVar("audio_engine_stability", "1", FCVAR_ARCHIVE + FCVAR_NOTIFY,
	"1 = stability control on registered cars")

local DEFAULTS = {
	steerSlow = 35,        -- front wheel angle at full lock, parking speeds (degrees)
	steerFast = 10,        -- ... at speed (100+ km/h)
	grip = 1.5,            -- how many g of cornering the car may pull before it counts as sliding (arcade)
	yawAllow = 10,         -- deg/s of extra rotation allowed before it steps in
	driftYaw = 70,         -- ... with the handbrake held (drifting)
	overDamp = 9,          -- how firmly it catches oversteer (per second)
	turnHelp = 4,          -- how much turn-in it adds when the car pushes wide (per second)...
	turnShare = 0.9,       -- ...up to this share of the rotation the steering asks for
	-- braking (S held, rolling forward): the front tyres lock and the car ploughs straight on.
	-- It still turns, less: turn-in help up to brakeTurn of the asked rotation, applied firmer
	brakeTurn = 0.6,
	brakeHelp = 6,         -- per second
	driftAngle = 20,       -- last-resort guard: tail-out slide angle (degrees)
	handbrakeAngle = 70,   -- ... while drifting
	driftHold = 8,         -- a drift lasts while the car slides at least this many degrees
	-- (normal fast cornering has a few degrees of tail out: below slideFrom it keeps its power)
	slideFrom = 8,         -- tail-out slide angle (degrees) where it starts to count as sliding...
	slideFull = 16,        -- ...fully sliding here (power cut hardest)
	minSpeed = 8,          -- km/h
	-- slip limit (steering without the handbrake): no drifting out of fast corners
	slipMax = 4,           -- tail-out slip angle (degrees) it lets the car reach
	slipReturn = 4,        -- deg/s of nose turned back per degree beyond it
	slipDamp = 12,         -- how firmly (per second)
	gripAssist = 1.0,      -- extra sideways tyre grip without the handbrake (g): stops slides, turns fast cars
	-- straight-line hold (throttle with no steering): no spin-outs when accelerating
	straightDamp = 20,     -- how firmly it stops rotation (per second)
	straightHold = 3,      -- deg/s of turn back per degree off the held heading
	straightMax = 45,      -- further off than this (a crash) and it holds the new heading instead
	-- taken over from a turn (still rotating): it only damps the rotation, following the car's
	-- heading, until the rotation is under holdSettled (at most holdGrace), then holds that line
	holdGrace = 1,         -- s
	holdSettled = 3,       -- deg/s
}
E.STABILITY_DEFAULTS = DEFAULTS

local deg, rad, atan2, abs, min, max, sqrt, tan = math.deg, math.rad, math.atan2, math.abs, math.min, math.max, math.sqrt, math.tan
local function clamp(x, a, b) if x < a then return a elseif x > b then return b end return x end
local function sign(x) return x >= 0 and 1 or -1 end

-- nose direction and wheelbase, from the wheel attachments (cached per model)
local geoCache = {}
local function geometry(veh)
	local mdl = veh:GetModel()
	if geoCache[mdl] then return geoCache[mdl] end
	local p = {}
	for _, n in ipairs({ "wheel_fl", "wheel_fr", "wheel_rl", "wheel_rr" }) do
		local id = veh:LookupAttachment(n)
		local a = id and id > 0 and veh:GetAttachment(id)
		if not a then return { fwd = Vector(0, 1, 0), wheelbase = 2.6 } end
		p[n] = veh:WorldToLocal(a.Pos)
	end
	local f = ((p.wheel_fl + p.wheel_fr) - (p.wheel_rl + p.wheel_rr)) * 0.5
	f.z = 0
	local len = f:Length()
	if len < 1 then return { fwd = Vector(0, 1, 0), wheelbase = 2.6 } end
	local wb = clamp(len * 0.0254, 1.8, 4.5)
	f:Normalize()
	geoCache[mdl] = { fwd = f, wheelbase = wb }
	return geoCache[mdl]
end

-- is the car on the ground? (a short trace down from its floor)
local function onGround(veh)
	local up = veh:GetUp()
	local start = veh:GetPos() + up * 12
	local tr = util.TraceLine({ start = start, endpos = start - up * 40, filter = veh, mask = MASK_SOLID })
	return tr.Hit
end

-- extra tyre grip: takes up to `g` of sideways speed (vr, inches/s along `right`) away per
-- second, like a tyre's side force. The forward speed is never touched, so it can't launch a
-- sideways car where its nose points (turning the whole velocity toward the nose did that)
local function lateralGrip(phys, right, vr, g, dt)
	local cut = min(abs(vr), g * 9.81 / 0.0254 * dt)
	if cut > 0 then phys:AddVelocity(right * (-sign(vr) * cut)) end
end

local function assist(veh, cfg, dt)
	local drv = veh:GetDriver()
	if not IsValid(drv) then return end
	local phys = veh:GetPhysicsObject()
	if not IsValid(phys) or not phys:IsMotionEnabled() then return end
	if not onGround(veh) then return end

	local S = cfg.stability or {}
	local function P(k) local v = S[k]; if v == nil then v = DEFAULTS[k] end return v end

	local geo = geometry(veh)
	local up = veh:GetUp()
	local fwd = veh:LocalToWorld(geo.fwd) - veh:GetPos()
	fwd = fwd - up * fwd:Dot(up)
	fwd:Normalize()
	local right = fwd:Cross(up)

	local vel = phys:GetVelocity()
	local vf, vr = vel:Dot(fwd), vel:Dot(right)
	local speedIn = sqrt(vf * vf + vr * vr)            -- inches/s
	local v = speedIn * 0.0254                         -- m/s
	local kmh = v * 3.6
	local minSpeed = P("minSpeed")

	-- the driver's steering, smoothed like the wheels turn (left = +)
	local want = (drv:KeyDown(IN_MOVELEFT) and 1 or 0) - (drv:KeyDown(IN_MOVERIGHT) and 1 or 0)
	local s = veh.audioSteer or 0
	s = s + clamp(want - s, -dt * 4, dt * 4)
	veh.audioSteer = s

	veh.audioSlide, veh.audioSlideT, veh.audioSpin = 0, CurTime(), true

	-- straight-line hold: throttle, no steering, no handbrake or drift -> the car keeps the
	-- heading it had when the keys were let go, from a standstill up (launch spins start below
	-- minSpeed). Any rotation counts as sliding, so traction control cuts the power too
	if want == 0 and abs(s) < 0.05 and drv:KeyDown(IN_FORWARD) and not drv:KeyDown(IN_JUMP)
		and not veh.audioDrift and vf > -40 then
		local heading = deg(atan2(fwd.y, fwd.x))         -- left = +, like the yaw rate
		local err = veh.audioHeading and math.NormalizeAngle(veh.audioHeading - heading) or 0
		local yaw = phys:GetAngleVelocity().z
		if not veh.audioHeading or abs(err) > P("straightMax") then
			veh.audioHeading, err = heading, 0           -- (re)captured: after a crash or a spin it holds the new line
			veh.audioHoldGrace = abs(yaw) > P("holdSettled") and CurTime() + P("holdGrace") or nil
		end
		-- still rotating out of a turn: holding the line it had when the keys were let go turned it
		-- back against its tyres for seconds (read as a slide, power cut). Follow it until it settles
		local settling = veh.audioHoldGrace and CurTime() < veh.audioHoldGrace and abs(yaw) > P("holdSettled")
		if settling then
			veh.audioHeading, err = heading, 0
		else
			veh.audioHoldGrace = nil
		end
		local target = clamp(err * P("straightHold"), -30, 30)
		phys:AddAngleVelocity(Vector(0, 0, (target - yaw) * min(1, P("straightDamp") * dt)))
		local beta = v > 2 and abs(deg(atan2(vr, vf))) or 0
		lateralGrip(phys, right, vr, P("gripAssist") * clamp((kmh - minSpeed) / 12, 0, 1), dt)
		local yawSlide = settling and 0 or (abs(yaw - target) - 4) / 15
		veh.audioSlide = clamp(max(yawSlide, (beta - 3) / 10), 0, 1)
		veh.audioLogYaw, veh.audioLogBeta = yaw - target, beta
		return
	end
	veh.audioHeading, veh.audioLogYaw, veh.audioLogBeta = nil, nil, nil

	if kmh < minSpeed or vf <= 0 then return end
	local fade = clamp((kmh - minSpeed) / 12, 0, 1)
	local beta = deg(atan2(vr, vf))                      -- + = nose rotated left of the travel
	-- drifting: started with the handbrake, held while the car stays sideways
	if drv:KeyDown(IN_JUMP) then veh.audioDrift = true
	elseif abs(beta) < P("driftHold") then veh.audioDrift = false end
	local handbrake = veh.audioDrift

	-- rotation the driver is asking for (deg/s, left = +): what the steering angle would give
	-- at this speed, capped by what the tyres can actually hold
	-- (sv_handling may have widened the car's lock at speed: veh.audioSteerFast)
	local fast = P("steerFast") * (veh.audioSteerFast or 1)
	local lock = rad(P("steerSlow") + (fast - P("steerSlow")) * clamp((kmh - 20) / 80, 0, 1))
	local vv = max(v, 2)
	local wKin = deg(vv * tan(lock) / geo.wheelbase)
	local wGrip = deg(P("grip") * 9.81 / vv)
	local wRef = s * min(wKin, wGrip)

	local yaw = phys:GetAngleVelocity().z                -- deg/s, left = +
	local add = 0
	local a = abs(beta)
	local tailOut = beta * yaw > 0                       -- sliding the way it rotates (oversteer)

	-- how fast the slip angle changes (smoothed; a stale reading from an earlier pass is dropped)
	local now = CurTime()
	local dBeta = veh.audioBeta and now - veh.audioBetaT < dt * 2.5 and (beta - veh.audioBeta) / dt or 0
	veh.audioBeta, veh.audioBetaT = beta, now
	veh.audioBetaRate = (veh.audioBetaRate or 0) + (dBeta - (veh.audioBetaRate or 0)) * min(1, 15 * dt)

	local allow = handbrake and P("driftYaw") or (P("yawAllow") + 0.15 * abs(wRef))
	local kOver = P("overDamp")
	local braking = drv:KeyDown(IN_BACK) and not drv:KeyDown(IN_FORWARD)
	local share = braking and P("brakeTurn") or P("turnShare")

	if yaw * wRef >= 0 then
		-- turning the way the driver steers: catch only the part beyond what was asked
		local excess = abs(yaw) - abs(wRef) - allow
		if excess > 0 then
			add = add - sign(yaw) * excess * min(1, kOver * dt)
		elseif not handbrake and abs(wRef) > 4 and v > 5 and abs(yaw) < abs(wRef) * share
			and not (tailOut and a > P("slipMax") * 0.5) then
			-- pushing wide (or ploughing on under braking): help it turn in
			local k = braking and P("brakeHelp") or P("turnHelp")
			add = add + sign(wRef) * (abs(wRef) * share - abs(yaw)) * min(1, k * dt)
		end
	elseif not handbrake then
		-- rotating against the steering (a snap the other way): stop it. Not while drifting:
		-- there counter-steering is how the driver holds the angle
		local excess = abs(yaw) - allow * 0.5
		if excess > 0 then add = add - sign(yaw) * excess * min(1, kOver * dt) end
	end

	-- slip limit (no handbrake): steering at speed turns, it doesn't drift. Past slipMax the nose
	-- may only rotate as fast as the car's path does (yaw - dBeta/dt), less a little to bring the
	-- slip angle back. It only ever takes rotation away (the travel direction is never touched)
	if not handbrake and tailOut and a > P("slipMax") then
		local back = min(60, (a - P("slipMax")) * P("slipReturn"))
		local d = -veh.audioBetaRate - sign(beta) * back
		if d * beta < 0 then add = add + d * min(1, P("slipDamp") * dt) end
	end

	-- lateral grip (no handbrake): extra tyre grip that takes sideways speed away
	if not handbrake then lateralGrip(phys, right, vr, P("gripAssist") * fade, dt) end

	-- last-resort guard: tail stepping OUT (slide in the same direction as the rotation)
	local maxA = handbrake and P("handbrakeAngle") or P("driftAngle")
	if tailOut and a > maxA * 0.6 then
		local k = clamp((a - maxA * 0.6) / (maxA * 0.4), 0, 1)
		if a > maxA then
			k = 1 + (a - maxA) / 10
			add = add - sign(beta) * min(90, (a - maxA) * 4) * dt * 4    -- ease the nose back
		end
		add = add - yaw * min(1, kOver * 0.6 * k * dt)
	end

	-- how much it's sliding, for the power cut: the tail out past slideFrom, or rotating well
	-- beyond what the steering asks. Not in a drift: there the driver wants the power.
	-- audioSpin: over-rotating, cut hard; only the tail out (the car still turns as asked) is a
	-- corner taken fast, and it keeps enough power to pull through it (sv_handling slideTurnFloor)
	-- the keys just let go, the steering still coming back (until the straight-line hold takes
	-- over): the turn's own rotation isn't over-rotating, it read as a spin and dipped the power
	if not handbrake then
		local returning = want == 0
		local over = returning and 0
			or yaw * wRef >= 0 and (abs(yaw) - abs(wRef) - allow) / 20 or (abs(yaw) - allow * 0.5) / 20
		local tail = beta * yaw > 0 and (a - P("slideFrom")) / (P("slideFull") - P("slideFrom")) or 0
		veh.audioSlide = clamp(max(over, tail), 0, 1) * fade
		veh.audioSpin = over > 0
	end
	veh.audioLogYaw, veh.audioLogBeta = yaw - wRef, beta

	if add ~= 0 then
		phys:AddAngleVelocity(Vector(0, 0, add * fade))
	end
end

hook.Add("Tick", "audio_engine_stability", function()
	if not cvOn:GetBool() then return end
	local dt = engine.TickInterval()
	for veh in pairs(E.TrackedVehicles or {}) do
		if IsValid(veh) then
			local cfg = E.GetCarConfig(veh)
			-- not on spiked tyres (sv_handling.lua): a stinger is meant to make the car hard to drive
			if cfg and cfg.stability ~= false and not veh.audioSpiked then assist(veh, cfg, dt) end
		end
	end
end)
