--[[
	Audio Engine - handling model (shared)

	Why it is shared: Source simulates every car on the server only. A driver's key reaches the
	server half a ping later, and what the server did comes back the other half later, then sits
	in the client's interpolation buffer (cl_interp, ~0.1 s). At 150 ms ping a steering key shows
	on screen ~0.25 s after it was pressed. Moving the car to the client would make crashes
	between players disagree, so the server stays the only authority, and this model is what
	lets the driver's client run ahead of it:

	  server (sv_handling.lua)  Source's jeep still does the engine, brakes, suspension and every
	                            collision. On top of it, each tick, this model takes over the
	                            car's rotation and sideways grip: the yaw rate follows what the
	                            steering asks (bicycle model, capped by the tyres' grip), and the
	                            sideways speed is held by a grip limit. A car's motion on the
	                            ground is then mostly this model, which both sides know exactly.
	                            The driver gets the car's state every other tick, tagged with the
	                            last user command the server ran.
	  client (cl_handling.lua)  runs the same model from that state through every command it
	                            sent since (Source's own player prediction, for the car), shows
	                            the car there, and blends in each correction. Crashes, kerbs and
	                            other cars are still the server's: they show up one ping late,
	                            blended, never as a different outcome.

	Everything below is plain Lua on numbers (no Vector/Angle), so the server can run it for 40
	cars a tick without allocating, the client can replay ~25 commands a frame, and dev/baker/
	test_prediction.js runs it offline with a simulated 150 ms connection.

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
local sin, cos, tan, exp = math.sin, math.cos, math.tan, math.exp
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

-- the server's switch (replicated: the clients' prediction reads it too)
Handling.driveModelConVar = Handling.driveModelConVar or CreateConVar("audio_engine_drivemodel", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED + FCVAR_NOTIFY,
	"1 = the addon's handling model on registered cars (rotation follows the steering, grip limit, handbrake drifts; "
		.. "sh_handling.lua); 0 = Source's own tyres alone. The driver's prediction runs either way")

---------------------------------------------------------------------------
-- settings (per car: AudioEngine.CAR_HANDLING[name] over these; tuned live by the debug menu)
---------------------------------------------------------------------------
AudioEngine.HANDLING = AudioEngine.HANDLING or {
	-- steering: A/D are on/off keys, the wheel angle ramps to them
	steerRate = 4.5,        -- per second towards the pressed key (centre to full lock in 0.22 s)
	steerReturn = 6,        -- per second back to the centre with no key
	steerReverse = 9,       -- per second through the centre, from one lock to the other
	lockSlow = 32,          -- front wheel angle at full lock, parking speeds (degrees)
	lockFast = 5,           -- ... at lockFadeSpeed and over
	lockFadeSpeed = 30,     -- m/s
	lockFadePower = 1.4,    -- (1 - speed / lockFadeSpeed) ^ this blends slow into fast
	-- the tyres: the most sideways acceleration they hold (g). Turns are capped at it (the yaw
	-- rate asked never needs more), and a slide loses its sideways speed at it
	grip = 1.15,
	yawFollow = 8,          -- per second: how firmly the rotation follows the steering
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

-- per car overrides by car name (sh_carlist.lua names): { grip = 1.3, ... }
AudioEngine.CAR_HANDLING = AudioEngine.CAR_HANDLING or {}

-- the settings of one car: its own values over AudioEngine.HANDLING (read through, so a value
-- tuned live reaches every car at once)
local settingsCache = {}
function Handling.SettingsFor(carName)
	carName = carName or ""
	local cached = settingsCache[carName]
	if cached then return cached end
	local own = {}
	for key, value in pairs(AudioEngine.CAR_HANDLING[carName] or {}) do own[key] = value end
	cached = setmetatable(own, { __index = function(_, key) return AudioEngine.HANDLING[key] end })
	settingsCache[carName] = cached
	return cached
end

function Handling.Lock(settings, speed)
	local share = 1 - min(1, speed / settings.lockFadeSpeed)
	return settings.lockFast + (settings.lockSlow - settings.lockFast) * share ^ settings.lockFadePower
end

-- the front wheel angle (degrees) a full-lock turn at `speed` (m/s) amounts to: the lock, or less
-- where the tyres' grip caps the rotation (the bicycle model's angle for the yaw rate Control asks)
function Handling.TurnAngle(settings, wheelbase, speed)
	local lock = Handling.Lock(settings, speed)
	local gripAngle = DEG * math.atan(settings.grip * GRAVITY * wheelbase / max(speed * speed, 1))
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
	change to the yaw rate (deg/s, about the car's up) and to the sideways speed (inches/s along
	the car's right) that the car should get. It never touches the speed along the nose: a car
	can't be launched by it, and corners don't scrub speed. The caller applies them (server:
	the physics object; client: its predicted body). Also returns the yaw rate asked (logs).
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
		return 0, 0, 0
	end
	share = share * fade

	local slipAngle = DEG * atan2(abs(sideSpeed), max(abs(forwardSpeed), 1))
	local handbrake = has(buttons, 16) and forwardSpeed > 0
	if handbrake and speed > settings.driftMinSpeed then state.drift = true
	elseif state.drift and (slipAngle < settings.driftHold or forwardSpeed <= 0) then state.drift = false end

	-- the rotation the steering asks for: what the wheel angle gives at this speed (backwards
	-- too), never more than the tyres can hold
	local lock = Handling.Lock(settings, speed)
	local kinematic = DEG * forwardSpeed * INCH * tan(lock * RAD) / spec.wheelbase * steer
	local gripLimit = DEG * settings.grip * GRAVITY / max(speed, 1)
	local asked = clamp(kinematic, -gripLimit, gripLimit)
	local target, follow, grip = asked, settings.yawFollow, settings.grip
	if slipAngle > settings.spinAngle then
		-- spinning: caught, whatever the keys
		state.drift = false
	elseif handbrake then
		target, follow, grip = asked * settings.handbrakeYaw, settings.handbrakeFollow, grip * settings.handbrakeGrip
	elseif state.drift then
		follow, grip = settings.driftFollow, grip * settings.driftGrip
	end

	local yawChange = (target - body.yawRate) * min(1, follow * deltaTime) * share
	local removed = min(abs(sideSpeed), grip * GRAVITY_INCHES * deltaTime) * share
	return yawChange, -sign(sideSpeed) * removed, asked
end

-- the yaw and sideways changes onto a body (prediction; the server puts them on the physics object)
function Handling.ApplyControl(body, spec, yawChange, sideChange)
	body.yawRate = body.yawRate + yawChange
	if sideChange ~= 0 then
		local _, _, _, rx, ry, rz = noseOf(body, spec)
		body.vx, body.vy, body.vz = body.vx + rx * sideChange, body.vy + ry * sideChange, body.vz + rz * sideChange
	end
end

-- rotate (x, y, z) about the unit axis (ux, uy, uz) by angle (radians), Rodrigues
local function rotate(x, y, z, ux, uy, uz, angle)
	local c, s = cos(angle), sin(angle)
	local dot = (x * ux + y * uy + z * uz) * (1 - c)
	return x * c + (uy * z - uz * y) * s + ux * dot,
		y * c + (uz * x - ux * z) * s + uy * dot,
		z * c + (ux * y - uy * x) * s + uz * dot
end
Handling.Rotate = rotate

--[[
	Moves a predicted body one step: gravity (along the ground while the wheels are on it, all of
	it in the air), `acceleration` (m/s2) along the nose while on the ground, then position and
	rotation about the car's up. The velocity is not turned with the body (the tyres do that,
	through Control's grip), as in the real thing. stopping: the acceleration only slows the car
	(brakes, rolling resistance): it doesn't drive it backwards.
]]
function Handling.Integrate(body, spec, acceleration, deltaTime, stopping)
	local ground = body.groundShare
	-- gravity minus what the ground holds up (g . up taken out on the ground)
	local gravityAlongUp = -GRAVITY_INCHES * body.cz
	local gx = -(gravityAlongUp * body.cx) * ground
	local gy = -(gravityAlongUp * body.cy) * ground
	local gz = -GRAVITY_INCHES - (gravityAlongUp * body.cz) * ground
	local nx, ny, nz = noseOf(body, spec)
	local push = acceleration / INCH * ground
	local forwardBefore = body.vx * nx + body.vy * ny + body.vz * nz
	body.vx = body.vx + (gx + nx * push) * deltaTime
	body.vy = body.vy + (gy + ny * push) * deltaTime
	body.vz = body.vz + (gz + nz * push) * deltaTime
	if stopping and forwardBefore ~= 0 then
		local forwardAfter = body.vx * nx + body.vy * ny + body.vz * nz
		if forwardAfter * forwardBefore < 0 then
			body.vx, body.vy, body.vz = body.vx - nx * forwardAfter, body.vy - ny * forwardAfter, body.vz - nz * forwardAfter
		end
	end
	body.px, body.py, body.pz = body.px + body.vx * deltaTime, body.py + body.vy * deltaTime, body.pz + body.vz * deltaTime
	local turn = body.yawRate * RAD * deltaTime
	if turn ~= 0 then
		local ux, uy, uz = body.cx, body.cy, body.cz
		body.ax, body.ay, body.az = rotate(body.ax, body.ay, body.az, ux, uy, uz, turn)
		body.bx, body.by, body.bz = rotate(body.bx, body.by, body.bz, ux, uy, uz, turn)
	end
end

---------------------------------------------------------------------------
-- the speed along the nose, learned (client): Source's engine, gears, brakes and drag aren't
-- modelled here, so the driver's client learns how its car accelerates per key and speed from
-- the states the server sends, minus the slope. Starts from a guess from the car's power to
-- weight and top speed.
---------------------------------------------------------------------------
Handling.MODE_COAST, Handling.MODE_THROTTLE, Handling.MODE_BRAKE, Handling.MODE_REVERSE = 1, 2, 3, 4
Handling.MODE_HANDBRAKE, Handling.MODE_LIMITED, Handling.MODE_IDLE = 5, 6, 7
local MODE_COUNT = 7
-- modes that only slow the car (the value is along the travel, and never reverses it)
local STOPPING = { [1] = true, [3] = true, [5] = true, [6] = false, [7] = true }
Handling.STOPPING = STOPPING

local LEARN_BIN = 2.5     -- m/s per speed bin
local LEARN_BINS = 32     -- up to 80 m/s
local LEARN_RATE = 0.2    -- share of each new sample

-- forwardSpeed m/s along the nose; driving = the engine may drive (started); limiter = sv_cruise state
function Handling.DriveMode(buttons, forwardSpeed, driving, limiter)
	local forward, back = has(buttons, 1), has(buttons, 2)
	if has(buttons, 16) then return 5 end
	if forward and not back then
		if not driving then return 7 end
		if forwardSpeed < -0.5 then return 3 end          -- W while rolling backwards: braking
		if (limiter or 0) >= 1 then return 6 end
		return 2
	end
	if back and not forward then
		if forwardSpeed > 0.5 then return 3 end
		return driving and 4 or 7
	end
	if (limiter or 0) == 2 then return 3 end
	return 1
end

-- a guess before anything is learned (m/s2): power to weight in W/kg, top speed in m/s
local function guess(mode, speed, powerToWeight, topSpeed)
	if mode == 2 then
		local traction = 5.5
		local fromPower = powerToWeight * 0.55 / max(speed, 2)
		return max(0, min(traction, fromPower) * (1 - (speed / topSpeed) ^ 3))
	elseif mode == 3 then return -7.5
	elseif mode == 4 then return speed > 8 and 0 or -3
	elseif mode == 5 then return -4.5
	elseif mode == 6 then return 0
	end
	return -(0.35 + 0.0005 * speed * speed)
end

function Handling.NewLearner(powerToWeight, topSpeed)
	local learner = { powerToWeight = powerToWeight or 120, topSpeed = max(topSpeed or 50, 10), samples = 0 }
	for mode = 1, MODE_COUNT do
		local bins = {}
		for bin = 1, LEARN_BINS do bins[bin] = guess(mode, (bin - 0.5) * LEARN_BIN, learner.powerToWeight, learner.topSpeed) end
		learner[mode] = bins
	end
	return learner
end

local function binOf(speed) return clamp(floor(abs(speed) / LEARN_BIN) + 1, 1, LEARN_BINS) end

-- acceleration along the nose (m/s2) for a mode at forwardSpeed (m/s, signed)
function Handling.LearnedAcceleration(learner, mode, forwardSpeed)
	local speed = abs(forwardSpeed)
	local position = clamp(speed / LEARN_BIN - 0.5, 0, LEARN_BINS - 1)
	local low = floor(position)
	local share = position - low
	local bins = learner[mode]
	local value = bins[low + 1] + ((bins[min(low + 2, LEARN_BINS)]) - bins[low + 1]) * share
	if STOPPING[mode] then
		if speed < 0.3 then return 0 end
		return value * sign(forwardSpeed)              -- along the travel: against it
	end
	return value
end

-- one observed acceleration along the nose (m/s2, slope taken out) in a mode at forwardSpeed
function Handling.Learn(learner, mode, forwardSpeed, acceleration)
	if STOPPING[mode] then
		if abs(forwardSpeed) < 0.5 then return end
		acceleration = acceleration * sign(forwardSpeed)
	end
	local bins = learner[mode]
	local bin = binOf(forwardSpeed)
	bins[bin] = bins[bin] + (acceleration - bins[bin]) * LEARN_RATE
	-- a little into the neighbours: a bin nobody drove through yet still moves towards the car
	if bin > 1 then bins[bin - 1] = bins[bin - 1] + (acceleration - bins[bin - 1]) * LEARN_RATE * 0.25 end
	if bin < LEARN_BINS then bins[bin + 1] = bins[bin + 1] + (acceleration - bins[bin + 1]) * LEARN_RATE * 0.25 end
	learner.samples = learner.samples + 1
end

-- the slope's pull along the nose (m/s2) on a body on the ground
function Handling.SlopeAcceleration(body, spec)
	local nx, ny, nz = noseOf(body, spec)
	local gravityAlongUp = -GRAVITY * body.cz
	-- gravity in the ground plane, along the nose
	return (-GRAVITY * nz) - gravityAlongUp * (body.cx * nx + body.cy * ny + body.cz * nz)
end

---------------------------------------------------------------------------
-- prediction (client): from the server's state through the commands it hasn't run yet
---------------------------------------------------------------------------
local BODY_FIELDS = { "px", "py", "pz", "vx", "vy", "vz", "ax", "ay", "az", "bx", "by", "bz", "cx", "cy", "cz", "yawRate", "groundShare", "controlShare" }
Handling.BODY_FIELDS = BODY_FIELDS

function Handling.CopyBody(source, target)
	target = target or {}
	for i = 1, #BODY_FIELDS do local key = BODY_FIELDS[i]; target[key] = source[key] end
	return target
end

local function forwardSpeedOf(body, spec)
	local nx, ny, nz = noseOf(body, spec)
	return (body.vx * nx + body.vy * ny + body.vz * nz) * INCH
end
Handling.ForwardSpeed = forwardSpeedOf

-- one predicted command: the server's order (physics, then the model)
local function step(body, state, buttons, spec, learner, base, deltaTime)
	local forwardSpeed = forwardSpeedOf(body, spec)
	local mode = Handling.DriveMode(buttons, forwardSpeed, base.driving, base.limiter)
	Handling.Integrate(body, spec, Handling.LearnedAcceleration(learner, mode, forwardSpeed), deltaTime, STOPPING[mode])
	local yawChange, sideChange = Handling.Control(body, state, buttons, spec, deltaTime)
	Handling.ApplyControl(body, spec, yawChange, sideChange)
end

--[[
	base: the server's state (a body + steer, drift, driving, limiter, impact), commands: the
	buttons of each command after the one it ran, in order (count of them), fraction: how far into
	the next command the frame is (0..1, with the last buttons). Returns the predicted body (into
	`out`) and the steering state it ends with.
]]
function Handling.Predict(base, commands, count, fraction, spec, learner, deltaTime, out, outState)
	local body = Handling.CopyBody(base, out)
	local state = outState or {}
	state.steer, state.drift = base.steer, base.drift
	for i = 1, count do step(body, state, commands[i], spec, learner, base, deltaTime) end
	if fraction > 0 then
		local buttons = count > 0 and commands[count] or base.buttons or 0
		local savedSteer, savedDrift = state.steer, state.drift
		step(body, state, buttons, spec, learner, base, deltaTime * fraction)
		state.steer, state.drift = savedSteer, savedDrift
	end
	return body, state
end

---------------------------------------------------------------------------
-- smoothing (client): what's on screen = the prediction + an offset that dies away. A new state
-- from the server moves the prediction; the offset takes the jump, so the car never snaps
---------------------------------------------------------------------------
function Handling.NewSmoother()
	return { x = 0, y = 0, z = 0, rx = 0, ry = 0, rz = 0, last = 0 }
end

-- a jump of the prediction from `before` to `after`: kept on screen as offset, faded out later
function Handling.SmootherAbsorb(smoother, before, after)
	smoother.x = smoother.x + before.px - after.px
	smoother.y = smoother.y + before.py - after.py
	smoother.z = smoother.z + before.pz - after.pz
	-- the small rotation from after's axes to before's: 1/2 sum(after_i x before_i)
	local function cross(ax, ay, az, bx, by, bz) return ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx end
	local x1, y1, z1 = cross(after.ax, after.ay, after.az, before.ax, before.ay, before.az)
	local x2, y2, z2 = cross(after.bx, after.by, after.bz, before.bx, before.by, before.bz)
	local x3, y3, z3 = cross(after.cx, after.cy, after.cz, before.cx, before.cy, before.cz)
	smoother.rx = smoother.rx + (x1 + x2 + x3) * 0.5
	smoother.ry = smoother.ry + (y1 + y2 + y3) * 0.5
	smoother.rz = smoother.rz + (z1 + z2 + z3) * 0.5
end

-- let it die away over deltaTime (timeConstant: s to 1/e); snapDistance: a bigger jump is dropped
function Handling.SmootherDecay(smoother, deltaTime, timeConstant, snapDistance)
	if smoother.x * smoother.x + smoother.y * smoother.y + smoother.z * smoother.z > snapDistance * snapDistance then
		smoother.x, smoother.y, smoother.z, smoother.rx, smoother.ry, smoother.rz = 0, 0, 0, 0, 0, 0
		return
	end
	local keep = exp(-deltaTime / timeConstant)
	smoother.x, smoother.y, smoother.z = smoother.x * keep, smoother.y * keep, smoother.z * keep
	smoother.rx, smoother.ry, smoother.rz = smoother.rx * keep, smoother.ry * keep, smoother.rz * keep
end

-- the body on screen: `body` moved and turned by the offset (into out)
function Handling.SmootherApply(smoother, body, out)
	out = Handling.CopyBody(body, out)
	out.px, out.py, out.pz = body.px + smoother.x, body.py + smoother.y, body.pz + smoother.z
	local angle = sqrt(smoother.rx * smoother.rx + smoother.ry * smoother.ry + smoother.rz * smoother.rz)
	if angle > 1e-6 then
		local ux, uy, uz = smoother.rx / angle, smoother.ry / angle, smoother.rz / angle
		out.ax, out.ay, out.az = rotate(body.ax, body.ay, body.az, ux, uy, uz, angle)
		out.bx, out.by, out.bz = rotate(body.bx, body.by, body.bz, ux, uy, uz, angle)
		out.cx, out.cy, out.cz = rotate(body.cx, body.cy, body.cz, ux, uy, uz, angle)
	end
	return out
end

function Handling.SmootherSize(smoother)
	return sqrt(smoother.x * smoother.x + smoother.y * smoother.y + smoother.z * smoother.z)
end

---------------------------------------------------------------------------
-- the car's shape (Garry's Mod; both realms): nose direction and wheelbase from the wheel
-- attachments, cached per model
---------------------------------------------------------------------------
local geometryCache = {}
function AudioEngine.CarGeometry(vehicle)
	local model = vehicle:GetModel()
	if geometryCache[model] then return geometryCache[model] end
	local wheelPositions = {}
	for _, attachmentName in ipairs({ "wheel_fl", "wheel_fr", "wheel_rl", "wheel_rr" }) do
		local attachmentId = vehicle:LookupAttachment(attachmentName)
		local attachment = attachmentId and attachmentId > 0 and vehicle:GetAttachment(attachmentId)
		if not attachment then return { forward = Vector(0, 1, 0), wheelbase = 2.6 } end
		wheelPositions[attachmentName] = vehicle:WorldToLocal(attachment.Pos)
	end
	local forward = ((wheelPositions.wheel_fl + wheelPositions.wheel_fr) - (wheelPositions.wheel_rl + wheelPositions.wheel_rr)) * 0.5
	forward.z = 0
	local length = forward:Length()
	if length < 1 then return { forward = Vector(0, 1, 0), wheelbase = 2.6 } end
	local wheelbase = clamp(length * INCH, 1.8, 4.5)
	forward:Normalize()
	geometryCache[model] = { forward = forward, wheelbase = wheelbase }
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

-- the Angle of a body's axes (Garry's Mod)
function Handling.AnglesOf(body)
	return Vector(body.ax, body.ay, body.az):AngleEx(Vector(body.cx, body.cy, body.cz))
end
