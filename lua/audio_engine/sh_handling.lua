--[[
	Audio Engine - handling model (shared)

	Source simulates every car on the server only. On top of Source's jeep (engine, brakes,
	suspension and every collision), sv_handling.lua runs this model each tick: it takes over the
	car's rotation and sideways grip. The yaw rate follows what the steering asks (bicycle model,
	capped by the tyres' grip), and the sideways speed is held by a grip limit.

	Everything below is plain Lua on numbers (no Vector/Angle), so the server can run it for 40
	cars a tick without allocating, and dev/baker/test_handling.js runs it offline.

	Units: positions and velocities in inches (Source units) and inches/s; yaw rate in deg/s,
	left (counter-clockwise from above) = +; settings in m/s, g and degrees.
	A body is { px, py, pz  position; vx, vy, vz  velocity;
	            ax, ay, az  the model's x axis (Angle:Forward); bx, by, bz  its y axis (left);
	            cx, cy, cz  its z axis (up); yawRate; groundShare 0..1; controlShare 0..1 }.
]]
local AudioEngine = AUDIO_ENGINE
local Handling = AudioEngine.Handling or {}
AudioEngine.Handling = Handling

local abs, min, max, sqrt, floor = math.abs, math.min, math.max, math.sqrt, math.floor
local tan = math.tan
local atan2 = math.atan2 or math.atan
local DEG, RAD = 180 / math.pi, math.pi / 180

local INCH = 0.0254                 -- metres per Source unit
local GRAVITY = 9.81                -- m/s2
local GRAVITY_INCHES = GRAVITY / INCH
Handling.INCH = INCH

local function clamp(value, low, high) if value < low then return low elseif value > high then return high end return value end
local function sign(value) return value >= 0 and 1 or -1 end
local function approach(value, target, step)
	if value < target then return min(value + step, target) end
	return max(value - step, target)
end
Handling.Clamp = clamp

-- the server's switch (replicated: clients read it for audio_engine_settings)
Handling.driveModelConVar = Handling.driveModelConVar or CreateConVar("audio_engine_drivemodel", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED + FCVAR_NOTIFY,
	"1 = the addon's handling model on registered cars (rotation follows the steering, grip limit, handbrake drifts; "
		.. "sh_handling.lua); 0 = Source's own tyres alone")

---------------------------------------------------------------------------
-- settings (per car: AudioEngine.CAR_HANDLING[name] over these; tuned live by the debug menu)
---------------------------------------------------------------------------
local HANDLING_DEFAULTS = {
	-- steering: A/D are on/off keys, the wheel angle ramps to them
	steerRate = 7,          -- per second towards the pressed key (centre to full lock in 0.14 s; 4.5 felt slow to turn in)
	steerReturn = 8,        -- per second back to the centre with no key
	steerReverse = 9,       -- per second through the centre, from one lock to the other
	lockSlow = 32,          -- front wheel angle at full lock, parking speeds (degrees)
	lockFast = 5,           -- ... at lockFadeSpeed and over
	-- (the user: cars should turn way more from 40 mph and more at 80+. 30 m/s faded the lock to 5 by
	-- 67 mph and it, not the tyres, capped the turn at 40-60 mph; 52: full lock on a 3.4 m wheelbase
	-- 110 / 103 / 91 deg/s at 40 / 50 / 60 mph, was 67 / 60 / 49)
	lockFadeSpeed = 52,     -- m/s
	lockFadePower = 1.4,    -- (1 - speed / lockFadeSpeed) ^ this blends slow into fast
	-- the tyres: the most sideways acceleration they hold (g). Turns are capped at it (the yaw
	-- rate asked never needs more), and a slide loses its sideways speed at it
	grip = 1.15,
	-- downforce: extra grip that grows with speed squared, all of it from downforceSpeed (x grip:
	-- 0.5 = 1.5x the grip there). Nothing at town speeds, so only fast cars turn tighter at speed
	downforce = 0,
	downforceSpeed = 50,    -- m/s (112 mph)
	-- corner grip: extra grip on the keys' turn (not slides: handbrake, drift) at town speeds, all of
	-- it up to cornerGripFrom and none from cornerGripTo (smoothstep). With the tyres' 1.15 g alone the
	-- turn went from the lock's to the grip's at ~20 mph and the turning circle doubled by 30 (the
	-- user: "instantly stiff at 25 mph", it should get stiffer progressively)
	cornerGrip = 0.5,       -- x grip
	cornerGripFrom = 11,    -- m/s (25 mph)
	cornerGripTo = 36,      -- m/s (80 mph)
	-- the tyres hold sideways this much more than the turn asks (x grip), so a held turn tracks
	-- instead of drifting wide at the limit (the turn is held on its target every tick)
	sideHold = 1.15,
	-- obstructed: when the car turned less than it was set to last tick by over blockedYaw deg/s
	-- (+ blockedShare of it), something solid holds it (a wall, a car): for blockedTime s the turn
	-- only follows at yawFollow, as before the every-tick hold, instead of forcing it again.
	-- Only while the car touches something from the side (body.touching: a side collision within
	-- contactHold s, sv_handling): without it Source's own tyres pulling the rotation back counted
	-- as a wall and the car kept dropping to the gentle follow (it turned much less)
	blockedYaw = 15,
	blockedShare = 0.5,
	blockedTime = 0.3,
	contactHold = 0.5,      -- s a side collision counts as touching
	-- turn floor (arcade): the keys' full-lock turn never under turnFloor deg/s at turnFloorSpeed,
	-- x (turnFloorSpeed / speed) ^ turnFloorPower elsewhere (still the lock's at most). The tyres' grip
	-- alone gave the SLR ~26 deg/s at 80 mph (a 180 in 7 s); the user wanted a tight 180 at 80 mph.
	-- Every car the same (it was the high-powered ones': the user, lower tiers turned badly at 50 mph,
	-- the turn shouldn't follow a car's class). 0 = off
	-- (the user: more at 80 mph and over: 75 deg/s there, 65 at 100, 58 at 120; was 53 / 46 / 40)
	turnFloor = 75,
	turnFloorSpeed = 36,    -- m/s (80 mph)
	turnFloorPower = 0.66,  -- (0.5 left 50-60 mph short, the user)
	yawFollow = 12,         -- per second: how firmly the rotation follows the steering (8: ~0.5 s to the full turn, felt delayed)
	minSpeed = 1.5,         -- m/s: under this Source alone (parking, standing)...
	fadeSpeed = 3,          -- ...fully on minSpeed + this
	-- handbrake (Space): the rear lets go, the car rotates past what the steering asks
	handbrakeGrip = 0.35,   -- x grip while it's held
	handbrakeYaw = 1.6,     -- x the rotation asked
	handbrakeFollow = 2,    -- per second
	-- a drift started with the handbrake lasts while the car stays sideways
	driftMinSpeed = 7,      -- m/s for the handbrake to start one
	driftHold = 10,         -- degrees of slip angle it needs to keep going
	driftGrip = 0.6,        -- x grip during it
	driftFollow = 2.5,      -- per second (counter-steer holds the angle)
	spinAngle = 70,         -- slip angle (degrees) where a drift becomes a spin and is caught
	-- impacts (server; sent to the driver): a hit stops the model so the crash plays out on
	-- Source's physics, then it eases back
	impactSpeed = 120,      -- inches/s of velocity change in one collision that counts
	impactHold = 0.35,      -- s fully off
	impactEase = 0.5,       -- s back to full
}
-- the same table over a Lua refresh (cars hold it through Handling.SettingsFor), set to this file's
-- values on every load; values tuned live in the debug menu are put back on top by it
-- (EngineDebug.FollowGlobalHandling: it follows AudioEngine.HANDLING_DEFAULTS). Keeping the old
-- values over a refresh, a new key was nil (Control errored every tick) and a changed default
-- never reached a running server (the turn floor stayed off)
AudioEngine.HANDLING = AudioEngine.HANDLING or {}
for key, value in pairs(HANDLING_DEFAULTS) do AudioEngine.HANDLING[key] = value end
AudioEngine.HANDLING_DEFAULTS = HANDLING_DEFAULTS

-- per car overrides by car name (sh_carlist.lua names): { grip = 1.3, ... }
AudioEngine.CAR_HANDLING = AudioEngine.CAR_HANDLING or {}

-- the settings of one car: its own values (AudioEngine.CAR_HANDLING[name]) over AudioEngine.HANDLING,
-- both read live, so a value tuned or added later reaches cars already driving. (Its own values were
-- copied once: a car spawned before a Lua refresh kept the old ones, the SLR never got its turn floor)
local settingsCache = {}
function Handling.SettingsFor(carName)
	carName = carName or ""
	local cached = settingsCache[carName]
	if cached then return cached end
	cached = setmetatable({}, { __index = function(_, key)
		local own = AudioEngine.CAR_HANDLING[carName]
		local value = own and own[key]
		if value ~= nil then return value end
		return AudioEngine.HANDLING[key]
	end })
	settingsCache[carName] = cached
	return cached
end

-- the tyres' grip (g) in a slide at `speed` (m/s): downforce included
function Handling.SlideGripAt(settings, speed)
	local share = min(1, speed / settings.downforceSpeed)
	return settings.grip * (1 + settings.downforce * share * share)
end

-- the tyres' grip (g) on the keys' turn at `speed` (m/s): the slide's + corner grip
function Handling.GripAt(settings, speed)
	local fade = clamp((speed - settings.cornerGripFrom) / max(settings.cornerGripTo - settings.cornerGripFrom, 0.1), 0, 1)
	local corner = settings.cornerGrip * (1 - fade * fade * (3 - 2 * fade))
	return Handling.SlideGripAt(settings, speed) * (1 + corner)
end

-- the most the keys' turn may rotate the car at `speed` (m/s), deg/s: the tyres' grip, or the
-- car's turn floor where that's more
function Handling.TurnLimit(settings, speed)
	local limit = DEG * Handling.GripAt(settings, speed) * GRAVITY / max(speed, 1)
	if settings.turnFloor > 0 then
		limit = max(limit, settings.turnFloor * (settings.turnFloorSpeed / max(speed, 1)) ^ settings.turnFloorPower)
	end
	return limit
end

function Handling.Lock(settings, speed)
	local share = 1 - min(1, speed / settings.lockFadeSpeed)
	return settings.lockFast + (settings.lockSlow - settings.lockFast) * share ^ settings.lockFadePower
end

-- the front wheel angle (degrees) a full-lock turn at `speed` (m/s) amounts to: the lock, or less
-- where the tyres' grip caps the rotation (the bicycle model's angle for the yaw rate Control asks)
function Handling.TurnAngle(settings, wheelbase, speed)
	local lock = Handling.Lock(settings, speed)
	local gripAngle = DEG * math.atan(Handling.TurnLimit(settings, speed) * RAD * wheelbase / max(speed, 1))
	return min(lock, gripAngle)
end

---------------------------------------------------------------------------
-- inputs: the keys as one number (no bit library: the same code runs under Lua 5.4 offline)
---------------------------------------------------------------------------
Handling.KEY_FORWARD, Handling.KEY_BACK, Handling.KEY_LEFT, Handling.KEY_RIGHT, Handling.KEY_HANDBRAKE = 1, 2, 4, 8, 16

local function has(buttons, key) return floor(buttons / key) % 2 == 1 end
Handling.Has = has

-- keyDown(IN_...) -> buttons (player:KeyDown, CUserCmd:KeyDown)
function Handling.ButtonsFrom(keyDown, target)
	return (keyDown(target, IN_FORWARD) and 1 or 0) + (keyDown(target, IN_BACK) and 2 or 0) + (keyDown(target, IN_MOVELEFT) and 4 or 0)
		+ (keyDown(target, IN_MOVERIGHT) and 8 or 0) + (keyDown(target, IN_JUMP) and 16 or 0)
end

---------------------------------------------------------------------------
-- the model
---------------------------------------------------------------------------
-- the car's nose and right (unit, world) from its axes and the nose in model space
-- (spec.noseX/Y/Z: TDM cars point along +y)
local function noseOf(body, spec)
	local nx = body.ax * spec.noseX + body.bx * spec.noseY + body.cx * spec.noseZ
	local ny = body.ay * spec.noseX + body.by * spec.noseY + body.cy * spec.noseZ
	local nz = body.az * spec.noseX + body.bz * spec.noseY + body.cz * spec.noseZ
	-- right = nose x up
	local rx, ry, rz = ny * body.cz - nz * body.cy, nz * body.cx - nx * body.cz, nx * body.cy - ny * body.cx
	return nx, ny, nz, rx, ry, rz
end
Handling.NoseOf = noseOf

--[[
	One tick of the model: moves the steering (state.steer) and the drift flag, and returns the
	change to the yaw rate (deg/s, about the car's up), to the sideways speed (inches/s along the
	car's right) and to the speed along the nose that keeps the car's speed as it was: it only
	turns the velocity, so a car can't be launched by it and corners don't scrub speed. The caller applies them (the server:
	the physics object; the offline tests: ApplyControl). Also returns the yaw rate asked (logs).
]]
function Handling.Control(body, state, buttons, spec, deltaTime)
	local settings = spec.settings
	local wanted = (has(buttons, 4) and 1 or 0) - (has(buttons, 8) and 1 or 0)
	local steer = state.steer
	local rate = wanted == 0 and settings.steerReturn or (steer * wanted < 0 and settings.steerReverse or settings.steerRate)
	steer = approach(steer, wanted, rate * deltaTime)
	state.steer = steer

	local share = body.controlShare * body.groundShare
	local nx, ny, nz, rx, ry, rz = noseOf(body, spec)
	local forwardSpeed = body.vx * nx + body.vy * ny + body.vz * nz
	local sideSpeed = body.vx * rx + body.vy * ry + body.vz * rz
	local speed = sqrt(forwardSpeed * forwardSpeed + sideSpeed * sideSpeed) * INCH
	local fade = clamp((speed - settings.minSpeed) / settings.fadeSpeed, 0, 1)
	if share <= 0 or fade <= 0 then
		if fade <= 0 then state.drift = false end
		state.yawTarget, state.yawSet, state.blockedFor = nil, nil, nil
		return 0, 0, 0, 0
	end
	share = share * fade

	-- the sideways speed of a car rolling on its wheels: its rear axle runs along the rear wheels,
	-- so the middle of the car moves into the turn at half the wheelbase x the yaw rate. Holding it
	-- at 0 (as this did) set the rear tyres a few degrees across their path (8 at 10 m/s): Source's
	-- tyres pushed one way, the model the other, and the scrub took the grip the car drives on.
	-- (The old sv_stability's turn-in help and side grip were switched off for the same bleed.)
	-- Slip angles are measured from it: the rear axle's
	local rollingSide = -0.5 * spec.wheelbase / INCH * body.yawRate * RAD
	local slipAngle = DEG * atan2(abs(sideSpeed - rollingSide), max(abs(forwardSpeed), 1))
	local handbrake = has(buttons, 16) and forwardSpeed > 0
	if handbrake and speed > settings.driftMinSpeed then state.drift = true
	elseif state.drift and (slipAngle < settings.driftHold or forwardSpeed <= 0) then state.drift = false end

	-- the rotation the steering asks for: what the wheel angle gives at this speed (backwards
	-- too), never more than the tyres can hold
	local lock = Handling.Lock(settings, speed)
	local kinematic = DEG * forwardSpeed * INCH * tan(lock * RAD) / spec.wheelbase * steer
	local turnLimit = Handling.TurnLimit(settings, speed)
	local asked = clamp(kinematic, -turnLimit, turnLimit)
	-- (the sideways grip covers the turn: over the tyres' own where the turn floor asks more)
	local grip = max(Handling.GripAt(settings, speed), abs(asked) * RAD * speed / GRAVITY)
	local target, follow = asked, settings.yawFollow
	if slipAngle > settings.spinAngle then
		-- spinning: caught, whatever the keys
		state.drift = false
	elseif handbrake then
		target, follow = asked * settings.handbrakeYaw, settings.handbrakeFollow
		grip = Handling.SlideGripAt(settings, speed) * settings.handbrakeGrip
	elseif state.drift then
		follow, grip = settings.driftFollow, Handling.SlideGripAt(settings, speed) * settings.driftGrip
	else
		grip = grip * settings.sideHold
	end

	local yawChange
	if handbrake or state.drift then
		-- a slide: the rotation only drawn towards the target, the car's own momentum does the rest
		state.yawTarget = nil
		yawChange = (target - body.yawRate) * min(1, follow * deltaTime) * share
	else
		-- on grip: the target eases in at yawFollow and the car is put on it every tick. Source's own
		-- tyres resist the rotation between ticks: closing a share of the gap a tick (as this did:
		-- 12%), the car settled well short of the turn asked (the user: fast cars "barely turn" at
		-- 40-70 mph once Source's front wheels no longer pulled it round)
		local eased = state.yawTarget or body.yawRate
		eased = eased + (target - eased) * min(1, follow * deltaTime)
		state.yawTarget = eased
		-- held against something (a wall: the front corner stopped every tick, slammed round again by
		-- the next and the car climbed the wall, the user, on the Furai): back to following gently
		local set = state.yawSet
		if set and body.touching and abs(body.yawRate - set) > settings.blockedYaw + settings.blockedShare * abs(set) then
			state.blockedFor = settings.blockedTime
		end
		if (state.blockedFor or 0) > 0 then
			state.blockedFor = state.blockedFor - deltaTime
			state.yawTarget = body.yawRate + (eased - body.yawRate) * min(1, follow * deltaTime)
			yawChange = (eased - body.yawRate) * min(1, follow * deltaTime) * share
		else
			yawChange = (eased - body.yawRate) * share
		end
	end
	state.yawSet = (not (handbrake or state.drift)) and body.yawRate + yawChange or nil
	-- (a handbrake slide or a drift lets the rear go: there the sideways speed goes towards 0)
	local wantedSide = (handbrake or state.drift) and 0 or -0.5 * spec.wheelbase / INCH * (body.yawRate + yawChange) * RAD
	local sideError = sideSpeed - wantedSide
	local removed = min(abs(sideError), grip * GRAVITY_INCHES * deltaTime) * share
	local sideChange = -sign(sideError) * removed
	-- no speed gained: where the sideways change adds speed, as much comes off the nose's. Pushed
	-- along the car's right alone, a held turn gained speed (the car travels a little into the turn
	-- of its nose, so each tick's turn moved some of that into forward speed: the SLR circling from
	-- 20 mph was at 60 after 10 s, offline, with no throttle). Never the other way: taking a slide
	-- out costs its speed, as tyres scrub. (Keeping the speed both ways turned a slide's velocity
	-- back along the nose at full speed: scraping a wall, the car was thrown back into it every
	-- tick, kept its speed and climbed it, the user, on the Furai)
	local newSide = sideSpeed + sideChange
	local squared = forwardSpeed * forwardSpeed + sideSpeed * sideSpeed - newSide * newSide
	local forwardChange = squared > 0 and sign(forwardSpeed) * sqrt(squared) - forwardSpeed or 0
	if forwardChange * sign(forwardSpeed) > 0 then forwardChange = 0 end
	return yawChange, sideChange, asked, forwardChange
end

-- the yaw, sideways and forward changes onto a body (offline tests; the server puts them on the physics object)
function Handling.ApplyControl(body, spec, yawChange, sideChange, forwardChange)
	body.yawRate = body.yawRate + yawChange
	forwardChange = forwardChange or 0
	if sideChange ~= 0 or forwardChange ~= 0 then
		local nx, ny, nz, rx, ry, rz = noseOf(body, spec)
		body.vx = body.vx + rx * sideChange + nx * forwardChange
		body.vy = body.vy + ry * sideChange + ny * forwardChange
		body.vz = body.vz + rz * sideChange + nz * forwardChange
	end
end

---------------------------------------------------------------------------
-- the car's shape (Garry's Mod; both realms): nose direction, wheelbase and the middle of the
-- rear axle (model space) from the wheel attachments,
-- cached per model
---------------------------------------------------------------------------
local geometryCache = {}
local function unknownShape() return { forward = Vector(0, 1, 0), wheelbase = 2.6, rearAxle = Vector(0, 0, 0) } end
function AudioEngine.CarGeometry(vehicle)
	local model = vehicle:GetModel()
	if geometryCache[model] then return geometryCache[model] end
	local wheelPositions = {}
	for _, attachmentName in ipairs({ "wheel_fl", "wheel_fr", "wheel_rl", "wheel_rr" }) do
		local attachmentId = vehicle:LookupAttachment(attachmentName)
		local attachment = attachmentId and attachmentId > 0 and vehicle:GetAttachment(attachmentId)
		if not attachment then return unknownShape() end
		wheelPositions[attachmentName] = vehicle:WorldToLocal(attachment.Pos)
	end
	local rearAxle = (wheelPositions.wheel_rl + wheelPositions.wheel_rr) * 0.5
	local forward = (wheelPositions.wheel_fl + wheelPositions.wheel_fr) * 0.5 - rearAxle
	forward.z = 0
	local length = forward:Length()
	if length < 1 then return unknownShape() end
	local wheelbase = clamp(length * INCH, 1.8, 4.5)
	forward:Normalize()
	geometryCache[model] = { forward = forward, wheelbase = wheelbase, rearAxle = rearAxle }
	return geometryCache[model]
end

-- the model's numbers for a car: { settings, wheelbase, noseX/Y/Z }
function Handling.SpecFor(vehicle)
	local carConfig = AudioEngine.GetCarConfig(vehicle)
	local geometry = AudioEngine.CarGeometry(vehicle)
	return {
		settings = Handling.SettingsFor(carConfig and carConfig.name),
		wheelbase = geometry.wheelbase,
		noseX = geometry.forward.x, noseY = geometry.forward.y, noseZ = geometry.forward.z,
	}
end

-- a body's axes from an Angle (Garry's Mod)
function Handling.SetAxes(body, angles)
	local forward, right, up = angles:Forward(), angles:Right(), angles:Up()
	body.ax, body.ay, body.az = forward.x, forward.y, forward.z
	body.bx, body.by, body.bz = -right.x, -right.y, -right.z
	body.cx, body.cy, body.cz = up.x, up.y, up.z
end
