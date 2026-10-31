--[[
	Audio Engine - stability control (server)

	Works like a real car's stability control, but arcade-friendly. Every tick, for each driven
	registered car, it works out how fast the car SHOULD be rotating for the driver's steering keys
	(A/D) at this speed, and compares that with how fast it IS rotating:

	  * rotating more than asked (oversteer, a spin starting)  -> catches it. With the handbrake
	    held it allows a lot more, so handbrake drifts still work.
	  * rotating against the steering (counter-steering)      -> helps stop the rotation
	  * rotating less than asked (pushing wide, understeer)    -> adds a little turn-in
	  * last-resort guard: if the tail still slides out past the drift angle, it pulls the
	    car's travel back toward the nose without losing speed

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
	grip = 1.25,           -- how many g of cornering the car may pull before it counts as sliding (arcade)
	yawAllow = 10,         -- deg/s of extra rotation allowed before it steps in
	driftYaw = 70,         -- ... with the handbrake held (drifting)
	overDamp = 9,          -- how firmly it catches oversteer (per second)
	turnHelp = 2.5,        -- how much turn-in it adds when the car pushes wide (per second)
	driftAngle = 30,       -- last-resort guard: tail-out slide angle (degrees)
	handbrakeAngle = 55,   -- ... with the handbrake held
	gripAssist = 3,        -- how firmly the guard pulls the travel back toward the nose
	minSpeed = 8,          -- km/h
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

	if kmh < minSpeed or vf <= 0 then return end
	local fade = clamp((kmh - minSpeed) / 12, 0, 1)
	local handbrake = drv:KeyDown(IN_JUMP)

	-- rotation the driver is asking for (deg/s, left = +): what the steering angle would give
	-- at this speed, capped by what the tyres can actually hold
	local lock = rad(P("steerSlow") + (P("steerFast") - P("steerSlow")) * clamp((kmh - 20) / 80, 0, 1))
	local vv = max(v, 2)
	local wKin = deg(vv * tan(lock) / geo.wheelbase)
	local wGrip = deg(P("grip") * 9.81 / vv)
	local wRef = s * min(wKin, wGrip)

	local yaw = phys:GetAngleVelocity().z                -- deg/s, left = +
	local beta = deg(atan2(vr, vf))                      -- + = nose rotated left of the travel
	local add = 0

	local allow = handbrake and P("driftYaw") or (P("yawAllow") + 0.15 * abs(wRef))
	local kOver = P("overDamp")

	if yaw * wRef >= 0 then
		-- turning the way the driver steers: catch only the part beyond what was asked
		local excess = abs(yaw) - abs(wRef) - allow
		if excess > 0 then
			add = add - sign(yaw) * excess * min(1, kOver * dt)
		elseif not handbrake and abs(wRef) > 4 and v > 5 and abs(yaw) < abs(wRef) * 0.8 then
			-- pushing wide: a little help to turn in
			add = add + sign(wRef) * (abs(wRef) * 0.8 - abs(yaw)) * min(1, P("turnHelp") * dt)
		end
	else
		-- rotating against the steering (counter-steering, or a snap the other way): stop it
		local excess = abs(yaw) - allow * 0.5
		if excess > 0 then add = add - sign(yaw) * excess * min(1, kOver * dt) end
	end

	-- last-resort guard: tail stepping OUT (slide in the same direction as the rotation)
	local a = abs(beta)
	local maxA = handbrake and P("handbrakeAngle") or P("driftAngle")
	if beta * yaw > 0 and a > maxA * 0.6 then
		local k = clamp((a - maxA * 0.6) / (maxA * 0.4), 0, 1)
		if a > maxA then
			k = 1 + (a - maxA) / 10
			add = add - sign(beta) * min(90, (a - maxA) * 4) * dt * 4    -- ease the nose back
		end
		add = add - yaw * min(1, kOver * 0.6 * k * dt)
		-- turn the travel toward the nose (same speed, new direction)
		local turn = min(a * 0.5, a * P("gripAssist") * k * dt) * fade
		if turn > 0 then
			local nb = rad(sign(beta) * (a - turn))
			local vUp = vel:Dot(up)
			local newVel = fwd * (speedIn * math.cos(nb)) + right * (speedIn * math.sin(nb)) + up * vUp
			phys:AddVelocity(newVel - vel)
		end
	end

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
			if cfg and cfg.stability ~= false then assist(veh, cfg, dt) end
		end
	end
end)
