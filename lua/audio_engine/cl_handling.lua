--[[
	Audio Engine - driving prediction (client)

	The server is the only authority on where cars are (sv_handling.lua), so a key you press
	reaches your car ~half a ping later and its effect comes back the other half later, then waits
	in the interpolation buffer: at 150 ms ping ~0.25 s. This file hides that for the car you drive,
	the way Source predicts your own walking:

	  1. The server sends your car's state every other tick with the number of the last user
	     command it ran (net audio_engine_drive).
	  2. Each frame the client starts from that state and replays every command it sent since
	     through the handling model (sh_handling.lua): the same steering, rotation and grip the
	     server runs, plus how this car accelerates per key and speed, learned from those states.
	     That's where the car will be when the server runs your newest key.
	  3. The car (with its seats, lightbar, driver and passengers) is drawn there, and the camera
	     moves with it. A new state from the server moves the prediction a little; the jump goes
	     into an offset that dies away in ~0.1 s, so the car never snaps.
	  4. A wall the prediction would drive through stops it at the wall (a trace from the server's
	     car to the predicted one): crashes look right, and the server's crash takes over.
	  5. Other moving cars are drawn where they are now too (their speed and rotation carried on
	     over the same lead), not ~0.25 s behind: without it you'd see your car drive into one you
	     are only following.

	Nothing here moves a physics object: collisions, crashes and pushes between players are the
	server's alone, so everyone agrees on them. Only what's drawn (and your camera) runs ahead.
	Off in single player and for a listen server's host (no delay to hide).

	Client convars: audio_engine_predict (1), audio_engine_predict_others (1),
	audio_engine_predict_debug (0: boxes for the server's car, Source's and the predicted one).
	audio_engine_predict_stats prints how it's doing.
]]
local AudioEngine = AUDIO_ENGINE
local Handling = AudioEngine.Handling

-- (userinfo: the server sends the driving state only to clients that use it, sv_handling.lua)
local predictConVar = CreateClientConVar("audio_engine_predict", "1", true, true,
	"1 = the car you drive is shown where it will be when the server runs your keys (no input delay); 0 = as Source shows it")
-- (a tester asked to dial in how much of it they get)
local amountConVar = CreateClientConVar("audio_engine_predict_amount", "1", true, false,
	"How far ahead the prediction draws your car (and the other cars with it): 1 = where the server will have it (no input delay), "
		.. "0.5 = half way, 0 = where Source shows it", 0, 1)
local othersConVar = CreateClientConVar("audio_engine_predict_others", "1", true, false,
	"1 = while you drive with prediction, other moving cars are shown where they are now too, so close driving and crashes line up")
local debugConVar = CreateClientConVar("audio_engine_predict_debug", "0", false, false,
	"1 = draw the server's car (red), Source's (yellow) and the predicted one (green)")

AudioEngine.PREDICTION = {
	maxCommands = 32,         -- never replays more (~0.5 s at 66 tick: a longer gap shows that late)
	smoothTime = 0.1,         -- s: a correction dies away to 1/e in this...
	impactSmoothTime = 0.04,  -- ...while a crash plays out on the server (its outcome shows quickly)
	snapDistance = 250,       -- inches: a jump bigger than this (teleport, respawn) is shown at once
	easeTime = 0.35,          -- s: the other cars' lead eases in / out over this
	othersDistance = 5000,    -- inches: other cars further away are left where Source shows them
	othersMax = 16,           -- the nearest this many moving cars
	othersMinSpeed = 40,      -- inches/s: slower ones aren't moved...
	othersFullSpeed = 120,    -- ...fully from here
	othersSmooth = 0.08,      -- s: their speed / rotation estimate
	maxLead = 0.5,            -- s
	leadSmooth = 1.5,         -- s: the lead estimate follows the connection this slowly
	traceHeight = 20,         -- inches above the car's origin the obstacle trace runs at
	traceHalfHeight = 8,
	-- a hit facing up like ground (its normal within ~45 deg of the car's up: a crest, a bump, a
	-- slope) isn't a wall: the trace runs again traceRetryLift higher. Taken as a wall, uneven
	-- ground pulled the drawn car back by up to the lead and let it go the next frame, the
	-- camera with it: zooming in and out (the user, third person, other players than the host)
	groundNormal = 0.7,
	traceRetryLift = 24,
}
local PREDICTION = AudioEngine.PREDICTION

local HISTORY = 512
local MATCH_EVERY = 0.25    -- s between lead measurements
local RECEIVED = 48         -- own states kept for the lead measurement

local EntityMeta = FindMetaTable("Entity")
local setRenderAngles = EntityMeta.SetRenderAngles   -- (Player:SetRenderAngles is something else)

local function clamp(value, low, high) return value < low and low or (value > high and high or value) end

---------------------------------------------------------------------------
-- your keys, per command (StartCommand runs once per command as client prediction starts it,
-- and again on the server when it runs it: the same numbers)
---------------------------------------------------------------------------
local historyNumbers, historyButtons = {}, {}
local newestCommand, newestCommandAt = 0, 0

local function commandKeyDown(command, key) return command:KeyDown(key) end

hook.Add("StartCommand", "audio_engine_predict", function(player, command)
	if player ~= LocalPlayer() then return end
	local number = command:CommandNumber()
	if number == 0 then return end
	local slot = number % HISTORY
	historyNumbers[slot], historyButtons[slot] = number, Handling.ButtonsFrom(commandKeyDown, command)
	if number > newestCommand then newestCommand, newestCommandAt = number, RealTime() end
end)

local function buttonsOf(number)
	local slot = number % HISTORY
	if historyNumbers[slot] == number then return historyButtons[slot] end
end

---------------------------------------------------------------------------
-- your car
---------------------------------------------------------------------------
local own = {
	smoother = Handling.NewSmoother(), commands = {}, earlierCommands = {},
	predicted = {}, earlier = {}, display = {}, start = {}, state = {}, earlierState = {},
	received = {}, lead = nil, nextMatch = 0, stats = { states = 0, matched = 0, fallback = 0, corrections = 0, correctionSum = 0, largest = 0, clamped = 0 },
}
local learners = setmetatable({}, { __mode = "k" })

local function drivenCar()
	local player = LocalPlayer()
	if not IsValid(player) then return nil end
	local vehicle = player:GetVehicle()
	if not IsValid(vehicle) or vehicle:GetClass() ~= "prop_vehicle_jeep" or not AudioEngine.GetCarConfig(vehicle) then return nil end
	return vehicle
end

local function predictionAllowed()
	if not predictConVar:GetBool() or not Handling.predictServerConVar:GetBool() or game.SinglePlayer() then return false end
	local player = LocalPlayer()
	return IsValid(player) and not (player.IsListenServerHost and player:IsListenServerHost())
end

-- the model's numbers per car model (its shape doesn't change)
local specCache = {}
local function specOf(vehicle)
	local model = vehicle:GetModel() or ""
	local spec = specCache[model]
	if not spec then spec = Handling.SpecFor(vehicle); specCache[model] = spec end
	return spec
end

local function resetOwn(vehicle)
	own.vehicle, own.base, own.previousBase, own.fresh, own.shown = vehicle, nil, nil, false, false
	own.spec = IsValid(vehicle) and specOf(vehicle) or nil
	if IsValid(vehicle) and not learners[vehicle] then
		learners[vehicle] = Handling.NewLearner(vehicle:GetNW2Float("audio_pwr", 120), vehicle:GetNW2Float("audio_vmax", 180) / 3.6)
	end
	own.learner = IsValid(vehicle) and learners[vehicle] or nil
	own.smoother = Handling.NewSmoother()
	own.received = {}
end

-- what the server's states show of how the car accelerates along its nose
local function learnFrom(previous, current)
	if not previous or not own.learner then return end
	local deltaTime = current.time - previous.time
	if deltaTime <= 0 or deltaTime > 0.15 or current.impact or previous.impact then return end
	if current.groundShare < 1 or previous.groundShare < 1 then return end
	local before, after = Handling.ForwardSpeed(previous, own.spec), Handling.ForwardSpeed(current, own.spec)
	local acceleration = (after - before) / deltaTime - Handling.SlopeAcceleration(current, own.spec)
	local mode = Handling.DriveMode(current.buttons, after, current.driving, current.limiter)
	Handling.Learn(own.learner, mode, (before + after) * 0.5, acceleration)
end

net.Receive("audio_engine_drive", function()
	local index = net.ReadUInt(13)
	local state = { command = net.ReadUInt(32), time = net.ReadDouble() }
	state.px, state.py, state.pz = net.ReadFloat(), net.ReadFloat(), net.ReadFloat()
	local pitch, yaw, roll = net.ReadFloat(), net.ReadFloat(), net.ReadFloat()
	Handling.SetAxes(state, Angle(pitch, yaw, roll))
	state.vx, state.vy, state.vz = net.ReadFloat(), net.ReadFloat(), net.ReadFloat()
	state.yawRate = net.ReadFloat()
	state.yawTarget = net.ReadFloat()
	state.steer = net.ReadInt(8) / 127
	state.drift, state.driving, state.impact = net.ReadBool(), net.ReadBool(), net.ReadBool()
	state.groundShare, state.controlShare = net.ReadUInt(7) / 100, net.ReadUInt(7) / 100
	state.buttons, state.limiter = net.ReadUInt(5), net.ReadUInt(2)

	local vehicle = drivenCar()
	if not vehicle or vehicle:EntIndex() ~= index then return end
	if own.vehicle ~= vehicle then resetOwn(vehicle) end
	local base = own.base
	-- (unreliable: an older one can arrive after a newer one)
	if base and state.time <= base.time then return end
	learnFrom(base, state)
	own.previousBase, own.base, own.fresh, own.baseAt = base, state, true, RealTime()
	own.stats.states = own.stats.states + 1
	local received = own.received
	received[#received + 1] = { time = state.time, x = state.px, y = state.py, z = state.pz }
	if #received > RECEIVED then table.remove(received, 1) end
end)

-- the commands the server hasn't run after `number`, into list; count, and how far into the next one the frame is
local function commandsAfter(number, list)
	local count = 0
	if number ~= 0 and newestCommand > number and buttonsOf(number + 1) then
		local last = own.base and own.base.buttons or 0
		for commandNumber = number + 1, math.min(newestCommand, number + PREDICTION.maxCommands) do
			count = count + 1
			last = buttonsOf(commandNumber) or last
			list[count] = last
		end
		return count, clamp((RealTime() - newestCommandAt) / engine.TickInterval(), 0, 1), true
	end
	-- no command numbers to match (shouldn't happen in multiplayer): one ping of the keys held now
	local player = LocalPlayer()
	local buttons = Handling.ButtonsFrom(function(target, key) return target:KeyDown(key) end, player)
	count = clamp(math.Round(player:Ping() / 1000 / engine.TickInterval()), 0, PREDICTION.maxCommands)
	for i = 1, count do list[i] = buttons end
	return count, 0, false
end

local function bodyFromEntity(entity, out)
	local position = entity:GetPos()
	out.px, out.py, out.pz = position.x, position.y, position.z
	Handling.SetAxes(out, entity:GetAngles())
	return out
end

---------------------------------------------------------------------------
-- obstacles: the prediction stops at a wall instead of driving through it
---------------------------------------------------------------------------
local traceMins, traceMaxs = Vector(), Vector()
local traceData = { mins = traceMins, maxs = traceMaxs, mask = MASK_SOLID_BRUSHONLY }
local traceResult = {}
traceData.output = traceResult

local function notCar(entity)
	if entity:IsVehicle() or entity:IsPlayer() then return false end
	local parent = entity:GetParent()
	return not (IsValid(parent) and parent:IsVehicle())
end
traceData.filter = notCar

-- how far (0..1) the car can go from `fromPosition` towards `toPosition` before its leading end
-- (along `direction`, a unit vector) hits something. halfLength/halfWidth in inches, up = its up
local function clearShare(fromPosition, toPosition, direction, up, halfLength, halfWidth)
	local travel = toPosition - fromPosition
	local distance = travel:Length()
	if distance < 6 then return 1 end
	traceMins.x, traceMins.y, traceMins.z = -halfWidth, -halfWidth, -PREDICTION.traceHalfHeight
	traceMaxs.x, traceMaxs.y, traceMaxs.z = halfWidth, halfWidth, PREDICTION.traceHalfHeight
	local along = direction * (travel:Dot(direction) >= 0 and (halfLength - halfWidth) or -(halfLength - halfWidth))
	for _, lift in ipairs({ 0, PREDICTION.traceRetryLift }) do
		local lead = along + up * (PREDICTION.traceHeight + lift)
		traceData.start, traceData.endpos = fromPosition + lead, toPosition + lead
		util.TraceHull(traceData)
		if not traceResult.Hit or traceResult.StartSolid then return 1 end
		-- ground under the box (see groundNormal): not a wall, look again higher
		if traceResult.HitNormal:Dot(up) < PREDICTION.groundNormal then
			return math.max(0, traceResult.Fraction - 2 / distance)
		end
	end
	return 1
end

-- the car's half length along its nose and half width (inches), per model
local sizeCache = {}
local function sizeOf(vehicle, spec)
	local model = vehicle:GetModel()
	local size = sizeCache[model]
	if size then return size end
	local mins, maxs = vehicle:OBBMins(), vehicle:OBBMaxs()
	local alongY = math.abs(spec.noseY) > math.abs(spec.noseX)
	local length = alongY and (maxs.y - mins.y) or (maxs.x - mins.x)
	local width = alongY and (maxs.x - mins.x) or (maxs.y - mins.y)
	size = { halfLength = length * 0.5, halfWidth = clamp(width * 0.4, 8, 36) }
	sizeCache[model] = size
	return size
end

---------------------------------------------------------------------------
-- drawing cars where they're shown: render origin / angles on the car and what's parented to it
---------------------------------------------------------------------------
local displaced = {}      -- car -> { fromPosition, fromAngles, toPosition, toAngles } (this frame)
local overridden = {}     -- entity -> frame it was last placed in
local childrenCache = {}  -- car -> { list, at }
local updatedFrame = -1

local originalBounds = {}  -- entity -> { mins, maxs, pad } while moved

-- the game culls an entity by where Source has it: drawn up to a few metres ahead (with your
-- camera), its bounds are widened by that much, or your own car could vanish from in front of you
local function widenBounds(entity, pad)
	local bounds = originalBounds[entity]
	if not bounds then
		local mins, maxs = entity:GetRenderBounds()
		bounds = { mins = mins, maxs = maxs, pad = 0 }
		originalBounds[entity] = bounds
	end
	if math.abs(pad - bounds.pad) < 24 and pad <= bounds.pad then return end
	bounds.pad = pad + 24
	local padding = Vector(bounds.pad, bounds.pad, bounds.pad)
	entity:SetRenderBounds(bounds.mins - padding, bounds.maxs + padding)
end

--[[
	The render origin moves an entity's bones, so its attachments too, and the game builds the
	driver's view from the car's eye attachment (and parents children to it). Left on between
	frames, the view the game handed to CalcView was already moved by last frame's offset and
	calcView moved it again: the camera ran ~2x the lead ahead of the car (out of sight, shaking
	with every change of the lead), and attached children were moved twice. So the poses are only
	worked out at CalcView (everything at Source's pose then), put on once drawing starts
	(PreDrawOpaqueRenderables) and taken off when the frame is done (PostRender).
]]
local placements = {}     -- entity -> { position, angles } to draw it at this frame
local placementsOn = false

local function place(entity, position, angles, frame, pad)
	local placement = placements[entity]
	if not placement then placement = {}; placements[entity] = placement end
	placement.position, placement.angles = position, angles
	widenBounds(entity, pad)
	overridden[entity] = frame
end

local function putPlacementsOn()
	if placementsOn then return end
	placementsOn = true
	for entity, placement in pairs(placements) do
		if IsValid(entity) then
			entity:SetRenderOrigin(placement.position)
			setRenderAngles(entity, placement.angles)
			entity:InvalidateBoneCache()
		end
	end
end

local function takePlacementsOff()
	if placementsOn then
		for entity in pairs(placements) do
			if IsValid(entity) then
				entity:SetRenderOrigin(nil)
				setRenderAngles(entity, nil)
				entity:InvalidateBoneCache()
			end
		end
	end
	placementsOn = false
	table.Empty(placements)
end

local function childrenOf(vehicle, now)
	local cached = childrenCache[vehicle]
	if cached and now - cached.at < 0.5 then return cached.list end
	local list = {}
	for _, child in ipairs(vehicle:GetChildren()) do
		if IsValid(child) and not child:IsPlayer() then
			list[#list + 1] = child
			for _, grandchild in ipairs(child:GetChildren()) do
				if IsValid(grandchild) and not grandchild:IsPlayer() then list[#list + 1] = grandchild end
			end
		end
	end
	childrenCache[vehicle] = { list = list, at = now }
	return list
end

-- a pose in Source's frame of the car -> the same pose on the car as shown
local function mapPose(entry, position, angles)
	local localPosition, localAngles = WorldToLocal(position, angles, entry.fromPosition, entry.fromAngles)
	return LocalToWorld(localPosition, localAngles, entry.toPosition, entry.toAngles)
end

local function displace(vehicle, toPosition, toAngles, frame, now)
	local entry = { fromPosition = vehicle:GetPos(), fromAngles = vehicle:GetAngles(), toPosition = toPosition, toAngles = toAngles }
	displaced[vehicle] = entry
	local pad = toPosition:Distance(entry.fromPosition)
	place(vehicle, toPosition, toAngles, frame, pad)
	vehicle:MarkShadowAsDirty()
	for _, child in ipairs(childrenOf(vehicle, now)) do
		if IsValid(child) and not child:IsDormant() then
			local position, angles = mapPose(entry, child:GetPos(), child:GetAngles())
			place(child, position, angles, frame, pad)
		end
	end
end

local function clearStale(frame)
	for entity, placedFrame in pairs(overridden) do
		if placedFrame ~= frame then
			placements[entity] = nil
			if IsValid(entity) then
				entity:SetRenderOrigin(nil)
				setRenderAngles(entity, nil)
				entity:InvalidateBoneCache()
				local bounds = originalBounds[entity]
				if bounds then entity:SetRenderBounds(bounds.mins, bounds.maxs) end
			end
			overridden[entity], originalBounds[entity] = nil, nil
		end
	end
end

-- the velocity (inches/s, world) of the car you drive where it's predicted, or nil without a
-- recent prediction (cl_engine's revs and gears: Source's position shows the speed ~a ping late)
function AudioEngine.PredictedVelocity(vehicle)
	if vehicle ~= own.vehicle or not own.velocity or RealTime() - (own.velocityAt or 0) > 0.1 then return nil end
	return own.velocity
end

-- the speed (inches/s) the server's physics gave the car you drive in its latest state, or nil
-- without one in the last 0.3 s (single player, the listen host, prediction off): cl_hud's
-- speedometer. Exact, ~33 a second and a ping old; the positions' speed jittered more the faster
local SERVER_SPEED_FRESH = 0.3
function AudioEngine.ServerSpeed(vehicle)
	local base = own.base
	if vehicle ~= own.vehicle or not base or not own.baseAt or RealTime() - own.baseAt > SERVER_SPEED_FRESH then return nil end
	return math.sqrt(base.vx * base.vx + base.vy * base.vy + base.vz * base.vz)
end

-- where an entity is drawn (other code drawing at a car: cl_police's lights). Its own pose when
-- it isn't moved
function AudioEngine.DisplayPose(entity)
	local root = entity
	local parent = entity:GetParent()
	while IsValid(parent) do root, parent = parent, parent:GetParent() end
	local entry = displaced[root]
	if not entry then return entity:GetPos(), entity:GetAngles() end
	return mapPose(entry, entity:GetPos(), entity:GetAngles())
end

---------------------------------------------------------------------------
-- the lead: how far ahead of what Source shows your car is drawn (s). Measured by finding where
-- Source's interpolated car sits among the states the server sent (the server time it shows),
-- against the server time the prediction is for. Until then: one ping + the interpolation delay
---------------------------------------------------------------------------
local interpConVar, interpRatioConVar, updateRateConVar = GetConVar("cl_interp"), GetConVar("cl_interp_ratio"), GetConVar("cl_updaterate")
local function interpolationDelay()
	local interp = interpConVar and interpConVar:GetFloat() or 0.1
	local ratio, rate = interpRatioConVar and interpRatioConVar:GetFloat() or 2, updateRateConVar and updateRateConVar:GetFloat() or 30
	return math.max(interp, ratio / math.max(rate, 1))
end

local function shownServerTime(vehicle)
	local received = own.received
	if #received < 4 then return nil end
	local position = vehicle:GetPos()
	local bestDistance, bestTime
	for i = 1, #received - 1 do
		local first, second = received[i], received[i + 1]
		local segmentX, segmentY, segmentZ = second.x - first.x, second.y - first.y, second.z - first.z
		local lengthSqr = segmentX * segmentX + segmentY * segmentY + segmentZ * segmentZ
		if lengthSqr > 1 then
			local share = clamp(((position.x - first.x) * segmentX + (position.y - first.y) * segmentY + (position.z - first.z) * segmentZ) / lengthSqr, 0, 1)
			local offX, offY, offZ = first.x + segmentX * share - position.x, first.y + segmentY * share - position.y, first.z + segmentZ * share - position.z
			local distance = offX * offX + offY * offY + offZ * offZ
			if not bestDistance or distance < bestDistance then bestDistance, bestTime = distance, first.time + (second.time - first.time) * share end
		end
	end
	if bestDistance and bestDistance < 100 * 100 then return bestTime end
end

local function updateLead(vehicle, predictedTime, realNow, frameTime)
	if not own.lead then own.lead = clamp(LocalPlayer():Ping() / 1000 + interpolationDelay(), 0, PREDICTION.maxLead) end
	if realNow < own.nextMatch then return end
	own.nextMatch = realNow + MATCH_EVERY
	local base = own.base
	if not base or base.vx * base.vx + base.vy * base.vy < 200 * 200 then return end   -- (needs a moving car)
	local shownTime = shownServerTime(vehicle)
	if not shownTime then return end
	local measured = clamp(predictedTime - shownTime, 0, PREDICTION.maxLead)
	own.lead = own.lead + (measured - own.lead) * math.min(1, MATCH_EVERY / PREDICTION.leadSmooth)
end

---------------------------------------------------------------------------
-- other cars, carried on over the same lead
---------------------------------------------------------------------------
local motions = setmetatable({}, { __mode = "k" })
local carList, nextCarList = {}, 0
local othersShare = 0
local nearby = {}
-- (the entries are reused: a new table per car per frame was garbage for nothing)
local nearbyEntries = {}
-- a car whose path was clear is traced again only every OTHERS_TRACE_EVERY frames (1-2 hull traces
-- per car per frame for up to 16 cars); one blocked by a wall is traced every frame
local OTHERS_TRACE_EVERY = 3
local function nearerFirst(first, second) return first.distanceSqr < second.distanceSqr end
local turnAngle = Angle(0, 0, 0)

local function motionOf(vehicle, realNow)
	local position, angles = vehicle:GetPos(), vehicle:GetAngles()
	local motion = motions[vehicle]
	if not motion or realNow - motion.at > 0.3 then
		motion = { position = position, yaw = angles.y, at = realNow, velocity = Vector(0, 0, 0), yawRate = 0, samples = 0 }
		motions[vehicle] = motion
		return motion
	end
	local deltaTime = realNow - motion.at
	if deltaTime < 0.02 then return motion end
	local keep = math.exp(-deltaTime / PREDICTION.othersSmooth)
	local velocity = (position - motion.position) / deltaTime
	-- (a teleport or respawn is not a speed)
	if velocity:LengthSqr() > 4000 * 4000 then velocity = Vector(0, 0, 0) end
	motion.velocity = motion.velocity * keep + velocity * (1 - keep)
	motion.yawRate = motion.yawRate * keep + math.NormalizeAngle(angles.y - motion.yaw) / deltaTime * (1 - keep)
	motion.position, motion.yaw, motion.at, motion.samples = position, angles.y, realNow, motion.samples + 1
	return motion
end

local function updateOthers(ownVehicle, lead, frame, realNow, eyePosition)
	if realNow >= nextCarList then
		nextCarList = realNow + 0.5
		carList = ents.FindByClass("prop_vehicle_jeep")
	end
	table.Empty(nearby)
	local maxDistanceSqr = PREDICTION.othersDistance * PREDICTION.othersDistance
	for _, vehicle in ipairs(carList) do
		if IsValid(vehicle) and vehicle ~= ownVehicle and not vehicle:IsDormant() then
			local distanceSqr = vehicle:GetPos():DistToSqr(eyePosition)
			if distanceSqr < maxDistanceSqr then
				local index = #nearby + 1
				local entry = nearbyEntries[index]
				if not entry then entry = {}; nearbyEntries[index] = entry end
				entry.vehicle, entry.distanceSqr = vehicle, distanceSqr
				nearby[index] = entry
			end
		end
	end
	table.sort(nearby, nearerFirst)
	for i = 1, math.min(#nearby, PREDICTION.othersMax) do
		local vehicle = nearby[i].vehicle
		local motion = motionOf(vehicle, realNow)
		local speed = motion.velocity:Length()
		local share = clamp((speed - PREDICTION.othersMinSpeed) / (PREDICTION.othersFullSpeed - PREDICTION.othersMinSpeed), 0, 1) * othersShare
		if share > 0 and motion.samples >= 3 then
			local carLead = lead * share * amountConVar:GetFloat()
			local turn = motion.yawRate * carLead
			local travel = motion.velocity * carLead
			turnAngle.y = turn * 0.5
			travel:Rotate(turnAngle)                         -- along the arc it's turning on
			local position, angles = vehicle:GetPos(), vehicle:GetAngles()
			-- (along the ground only: its bumps carried over the lead made it bob, as your own did)
			local up = vehicle:GetUp()
			travel = travel - up * travel:Dot(up)
			local toPosition = position + travel
			local spec = specOf(vehicle)
			local size = sizeOf(vehicle, spec)
			local clear = motion.clear or 1
			if clear < 1 or frame - (motion.clearFrame or -OTHERS_TRACE_EVERY) >= OTHERS_TRACE_EVERY then
				local nose = vehicle:LocalToWorld(Vector(spec.noseX, spec.noseY, spec.noseZ)) - position
				clear = clearShare(position, toPosition, nose, up, size.halfLength, size.halfWidth)
				motion.clear, motion.clearFrame = clear, frame
			end
			if clear < 1 then toPosition = position + travel * clear end
			displace(vehicle, toPosition, Angle(angles.p, angles.y + turn * clear, angles.r), frame, realNow)
		end
	end
end

---------------------------------------------------------------------------
-- drawn less leaning: cars in AudioEngine.CAR_LEAN_LEVEL (sh_carlist.lua) have that share of their
-- lean against the road taken out where they're drawn, turned about the axis of their lower side's
-- wheels on the road, so those stay on it and the raised side comes down. Drawing only: the
-- physics, the server and everyone's collisions are as they were
---------------------------------------------------------------------------
local LEAN_DISTANCE = 4000      -- inches from your eyes: further out a car is left as it is
local LEAN_REACH = 96           -- inches the traces look down from each wheel's centre
local LEAN_FOLLOW = 0.08        -- s: the correction's smoothing (the ground under a wheel jumps at kerbs)
local LEAN_MAX = math.rad(15)   -- never turned more than this
local LEAN_INSET = 0.8           -- the corners measured: this share of the body's half length / width out
local LEAN_START = 24            -- inches above the bottom of the body the traces start
local leanCars, nextLeanScan = {}, 0
local leanAngles = setmetatable({}, { __mode = "k" })   -- vehicle -> the correction (radians, + = first side high)
local leanSeen = setmetatable({}, { __mode = "k" })     -- vehicle -> what the last frame measured (audio_engine_lean_info)
local cornerLayouts = {}   -- model -> 4 points at the bottom of the body, in the car's space: one side front, back, then the other
local groundResult = {}
local groundTrace = { mask = MASK_SOLID, filter = notCar, output = groundResult }
local wheelPoints, groundPoints = {}, {}

-- The corners come from the model's bounds, which are there from the start. (The wheel attachments
-- ride on the wheel bones: read before the car has been drawn they can all be one point, and a
-- layout cached from that corrected nothing.) The long axis is the longer side of the bounds
local function wheelLayoutOf(vehicle)
	local model = vehicle:GetModel()
	local layout = cornerLayouts[model]
	if layout then return layout end
	local mins, maxs = vehicle:OBBMins(), vehicle:OBBMaxs()
	local centreX, centreY = (mins.x + maxs.x) * 0.5, (mins.y + maxs.y) * 0.5
	local halfX, halfY = (maxs.x - mins.x) * 0.5 * LEAN_INSET, (maxs.y - mins.y) * 0.5 * LEAN_INSET
	if halfX < 8 or halfY < 8 then return nil end
	local z = mins.z + LEAN_START
	if halfY >= halfX then
		-- long along y: the sides are -x and +x
		layout = { Vector(centreX - halfX, centreY + halfY, z), Vector(centreX - halfX, centreY - halfY, z),
			Vector(centreX + halfX, centreY + halfY, z), Vector(centreX + halfX, centreY - halfY, z) }
	else
		layout = { Vector(centreX + halfX, centreY - halfY, z), Vector(centreX - halfX, centreY - halfY, z),
			Vector(centreX + halfX, centreY + halfY, z), Vector(centreX - halfX, centreY + halfY, z) }
	end
	cornerLayouts[model] = layout
	return layout
end

-- point turned about the axis (unit vector) through pivot, by angle (radians)
local function turnedAbout(point, pivot, axis, angle)
	local x, y, z = Handling.Rotate(point.x - pivot.x, point.y - pivot.y, point.z - pivot.z, axis.x, axis.y, axis.z, angle)
	return Vector(pivot.x + x, pivot.y + y, pivot.z + z)
end

local function levelCar(vehicle, share, frame, realNow, frameTime)
	local layout = wheelLayoutOf(vehicle)
	if not layout then return end
	-- from where it's drawn already (the prediction), else where Source has it
	local entry = displaced[vehicle]
	local position = entry and entry.toPosition or vehicle:GetPos()
	local angles = entry and entry.toAngles or vehicle:GetAngles()
	local target, onGround = 0, true
	local seen = leanSeen[vehicle] or {}
	leanSeen[vehicle] = seen
	for index = 1, 4 do
		local wheel = LocalToWorld(layout[index], angle_zero, position, angles)
		wheelPoints[index] = wheel
		groundTrace.start, groundTrace.endpos = wheel, wheel - Vector(0, 0, LEAN_REACH)
		util.TraceLine(groundTrace)
		if not groundResult.Hit or groundResult.StartSolid then
			onGround, seen.missed = false, index
			break
		end
		groundPoints[index] = Vector(groundResult.HitPos)
	end
	local leftMid, rightMid, axis
	if onGround then
		-- each side's height over the road, and the car's long axis from its wheels
		local leftHeight = (wheelPoints[1].z - groundPoints[1].z + wheelPoints[2].z - groundPoints[2].z) * 0.5
		local rightHeight = (wheelPoints[3].z - groundPoints[3].z + wheelPoints[4].z - groundPoints[4].z) * 0.5
		leftMid, rightMid = (wheelPoints[1] + wheelPoints[2]) * 0.5, (wheelPoints[3] + wheelPoints[4]) * 0.5
		axis = (wheelPoints[1] + wheelPoints[3]) - (wheelPoints[2] + wheelPoints[4])
		axis:Normalize()
		local across = rightMid - leftMid
		local track = (across - axis * across:Dot(axis)):Length()
		if track > 1 then target = clamp(math.atan((leftHeight - rightHeight) / track) * share, -LEAN_MAX, LEAN_MAX) end
		seen.leftHeight, seen.rightHeight, seen.track, seen.missed = leftHeight, rightHeight, track, nil
	end
	seen.onGround, seen.target, seen.at = onGround, target, realNow
	-- (off the ground, a jump: eased back to none)
	local current = leanAngles[vehicle] or 0
	current = current + (target - current) * math.min(1, frameTime / LEAN_FOLLOW)
	leanAngles[vehicle] = current
	seen.current = current
	if not onGround or math.abs(current) < 0.002 then return end
	-- about the lower side's wheels on the road: the raised side comes down to it
	local pivot = current > 0 and (groundPoints[3] + groundPoints[4]) * 0.5 or (groundPoints[1] + groundPoints[2]) * 0.5
	local raised = current > 0 and leftMid or rightMid
	local turn = math.abs(current)
	if turnedAbout(raised, pivot, axis, turn).z > raised.z then turn = -turn end
	local newPosition = turnedAbout(position, pivot, axis, turn)
	local forward, up = angles:Forward(), angles:Up()
	local forwardX, forwardY, forwardZ = Handling.Rotate(forward.x, forward.y, forward.z, axis.x, axis.y, axis.z, turn)
	local upX, upY, upZ = Handling.Rotate(up.x, up.y, up.z, axis.x, axis.y, axis.z, turn)
	displace(vehicle, newPosition, Vector(forwardX, forwardY, forwardZ):AngleEx(Vector(upX, upY, upZ)), frame, realNow)
end

local function levelLeaningCars(frame, realNow, eyePosition, frameTime)
	local levels = AudioEngine.CAR_LEAN_LEVEL
	if not levels or next(levels) == nil then return end
	if realNow >= nextLeanScan then
		nextLeanScan = realNow + 0.5
		table.Empty(leanCars)
		for _, vehicle in ipairs(ents.FindByClass("prop_vehicle_jeep")) do
			local carConfig = AudioEngine.GetCarConfig(vehicle)
			local share = carConfig and levels[carConfig.name]
			if share and share > 0 then leanCars[vehicle] = share end
		end
	end
	local maxDistanceSqr = LEAN_DISTANCE * LEAN_DISTANCE
	for vehicle, share in pairs(leanCars) do
		if IsValid(vehicle) and not vehicle:IsDormant() and vehicle:GetPos():DistToSqr(eyePosition) < maxDistanceSqr then
			levelCar(vehicle, share, frame, realNow, frameTime)
		end
	end
end

-- what the lean correction sees on the cars it handles (to check it runs)
concommand.Add("audio_engine_lean_info", function()
	if not AudioEngine.CAR_LEAN_LEVEL then
		print("[Audio Engine] lean correction: AudioEngine.CAR_LEAN_LEVEL is missing: this client has an older sh_carlist.lua loaded "
			.. "(a Lua refresh reloads only the files that changed). Restart or change the map")
		return
	end
	local levels = AudioEngine.CAR_LEAN_LEVEL
	print(string.format("[Audio Engine] lean correction: %d car kinds listed, %d such cars in the scan", table.Count(levels), table.Count(leanCars)))
	for vehicle, share in pairs(leanCars) do
		local seen = IsValid(vehicle) and leanSeen[vehicle]
		if not seen then
			print(string.format("  %s: not measured (too far, out of view or no bounds)", tostring(vehicle)))
		elseif not seen.onGround then
			print(string.format("  %s: corner %s found no road under it (%.1f s ago)", tostring(vehicle), tostring(seen.missed), RealTime() - seen.at))
		else
			print(string.format("  %s: share %.2f | sides %.1f / %.1f in over the road, %.0f in apart | lean taken out %.1f deg (now %.1f) | %.1f s ago",
				tostring(vehicle), share, seen.leftHeight or 0, seen.rightHeight or 0, seen.track or 0, math.deg(seen.target or 0),
				math.deg(seen.current or 0), RealTime() - seen.at))
		end
	end
end, nil, "Print what the drawn lean correction (AudioEngine.CAR_LEAN_LEVEL) measures on the cars near you")

-- try a share on the car you sit in, live and on this client only (0 = off, 1 = drawn level)
concommand.Add("audio_engine_lean_set", function(player, _, arguments)
	local car = IsValid(player) and AudioEngine.RiddenCar(player)
	local carConfig = IsValid(car) and AudioEngine.GetCarConfig(car)
	if not carConfig or not carConfig.name then
		print("[Audio Engine] lean correction: sit in a car from the car list first")
		return
	end
	local share = tonumber(arguments[1])
	AudioEngine.CAR_LEAN_LEVEL = AudioEngine.CAR_LEAN_LEVEL or {}
	if not share then
		print(string.format("[Audio Engine] lean correction for %s: %s (audio_engine_lean_set <0..1>)", carConfig.name,
			tostring(AudioEngine.CAR_LEAN_LEVEL[carConfig.name] or 0)))
		return
	end
	share = clamp(share, 0, 1)
	AudioEngine.CAR_LEAN_LEVEL[carConfig.name] = share > 0 and share or nil
	nextLeanScan = 0
	print(string.format("[Audio Engine] lean correction for %s set to %.2f on this client (until a reload; the lasting value is AudioEngine.CAR_LEAN_LEVEL in sh_carlist.lua)", carConfig.name, share))
end, nil, "Set the drawn lean correction (0..1 of the lean taken out) for the car you sit in, on this client, to try values")

-- the car the camera rides with: the one you drive with the prediction, else the one you sit in
local function cameraCar()
	if own.vehicle then return own.vehicle end
	local player = LocalPlayer()
	return IsValid(player) and AudioEngine.RiddenCar(player) or nil
end

---------------------------------------------------------------------------
-- each frame (from CalcView, before anything is drawn)
---------------------------------------------------------------------------
local lastRealTime = RealTime()

local function updateFrame()
	local frame = FrameNumber()
	if updatedFrame == frame then return end
	updatedFrame = frame
	-- (everything at Source's pose while the new poses are worked out)
	takePlacementsOff()
	local realNow = RealTime()
	local frameTime = clamp(realNow - lastRealTime, 0, 0.1)
	lastRealTime = realNow
	table.Empty(displaced)

	local vehicle = predictionAllowed() and drivenCar() or nil
	if vehicle and own.vehicle ~= vehicle then resetOwn(vehicle) end
	local base = vehicle and own.base
	local running = base ~= nil and own.spec ~= nil
	othersShare = clamp(othersShare + ((running and othersConVar:GetBool()) and 1 or -1) * frameTime / PREDICTION.easeTime, 0, 1)

	if running then
		local spec, learner, deltaTime = own.spec, own.learner, engine.TickInterval()
		local count, fraction, matched = commandsAfter(base.command, own.commands)
		local stats = own.stats
		if matched then stats.matched = stats.matched + 1 else stats.fallback = stats.fallback + 1 end
		local predicted = Handling.Predict(base, own.commands, count, fraction, spec, learner, deltaTime, own.predicted, own.state)
		own.count, own.fraction = count, fraction

		if own.fresh then
			own.fresh = false
			if own.shown and own.previousBase then
				-- where the earlier state put the car for this same moment: the difference is the correction
				local earlierCount, earlierFraction = commandsAfter(own.previousBase.command, own.earlierCommands)
				local earlier = Handling.Predict(own.previousBase, own.earlierCommands, earlierCount, earlierFraction, spec, learner, deltaTime, own.earlier, own.earlierState)
				local before = Handling.SmootherSize(own.smoother)
				Handling.SmootherAbsorb(own.smoother, earlier, predicted)
				local jump = math.abs(Handling.SmootherSize(own.smoother) - before)
				stats.corrections, stats.correctionSum, stats.largest = stats.corrections + 1, stats.correctionSum + jump, math.max(stats.largest, jump)
			elseif not own.shown then
				-- starting: from where Source shows it
				Handling.SmootherAbsorb(own.smoother, bodyFromEntity(vehicle, own.start), predicted)
			end
		end
		own.shown = true
		Handling.SmootherDecay(own.smoother, frameTime, base.impact and PREDICTION.impactSmoothTime or PREDICTION.smoothTime, PREDICTION.snapDistance)
		local display = Handling.SmootherApply(own.smoother, predicted, own.display)

		-- not through walls: stop where the leading end would hit something
		local basePosition = Vector(base.px, base.py, base.pz)
		local toPosition = Vector(display.px, display.py, display.pz)
		local noseX, noseY, noseZ = Handling.NoseOf(display, spec)
		local size = sizeOf(vehicle, spec)
		local clear = clearShare(basePosition, toPosition, Vector(noseX, noseY, noseZ), Vector(display.cx, display.cy, display.cz), size.halfLength, size.halfWidth)
		if clear < 1 then
			toPosition = basePosition + (toPosition - basePosition) * clear
			stats.clamped = stats.clamped + 1
		end
		local displayAngles = Handling.AnglesOf(display)
		-- (audio_engine_predict_amount: part of the way from where Source shows the car)
		local amount = amountConVar:GetFloat()
		if amount < 1 then
			toPosition = LerpVector(amount, vehicle:GetPos(), toPosition)
			displayAngles = LerpAngle(amount, vehicle:GetAngles(), displayAngles)
		end
		own.displayPosition, own.displayAngles = toPosition, displayAngles
		own.velocity = own.velocity or Vector()
		own.velocity:SetUnpacked(predicted.vx, predicted.vy, predicted.vz)
		own.velocityAt = realNow
		displace(vehicle, toPosition, own.displayAngles, frame, realNow)
		updateLead(vehicle, base.time + (count + fraction) * deltaTime, realNow, frameTime)
	else
		own.shown = false
		if not vehicle then own.vehicle = nil end
	end

	local player = LocalPlayer()
	local eyePosition = IsValid(player) and player:EyePos() or vector_origin
	if othersShare > 0 and own.lead then
		updateOthers(vehicle, own.lead, frame, realNow, eyePosition)
	end
	-- (after the prediction: it starts from where that draws a car)
	levelLeaningCars(frame, realNow, eyePosition, frameTime)
	clearStale(frame)
end

---------------------------------------------------------------------------
-- the camera moves with your car as drawn. hook.Call is wrapped for CalcView only, so whatever
-- camera the gamemode or another addon makes (first person, third person) is moved after it
---------------------------------------------------------------------------
local cameraFrame = -1

--[[
	The vehicle's third-person camera, ours: it orbits the middle of the car as drawn (the base
	gamemode's orbits the driver's eyes), at a fixed distance (no mouse-wheel zoom: the base one
	reads the wheel, which is the speed limiter's), from the car's own render bounds. The base
	camera's distance follows the render bounds, which are widened while the car is drawn moved:
	as the lean correction came and went the camera jumped in and out
]]
local CAMERA_RISE = 0.35        -- the orbit's centre: this share of the car's height over its middle
local CAMERA_DISTANCE = 1       -- x the car's render bounds diagonal (the base camera at zoom 0)
local CAMERA_WALL_GAP = 4       -- inches kept off a wall behind the camera
local cameraHull = Vector(CAMERA_WALL_GAP, CAMERA_WALL_GAP, CAMERA_WALL_GAP)
local cameraResult = {}
local cameraTrace = { mins = -cameraHull, maxs = cameraHull, mask = MASK_SOLID, filter = notCar, output = cameraResult }

local function thirdPersonOrigin(player, car, angles)
	local seat = player:GetVehicle()
	if not IsValid(seat) or not seat.GetThirdPersonMode or not seat:GetThirdPersonMode() then return nil end
	if player:GetViewEntity() ~= player then return nil end
	local bounds = originalBounds[car]
	local mins, maxs
	if bounds then mins, maxs = bounds.mins, bounds.maxs else mins, maxs = car:GetRenderBounds() end
	local radius = (maxs - mins):Length() * CAMERA_DISTANCE
	local centre = car:OBBCenter()
	centre.z = centre.z + (car:OBBMaxs().z - car:OBBMins().z) * CAMERA_RISE
	local position, carAngles = AudioEngine.DisplayPose(car)
	local pivot = LocalToWorld(centre, angle_zero, position, carAngles)
	cameraTrace.start, cameraTrace.endpos = pivot, pivot - angles:Forward() * radius
	util.TraceHull(cameraTrace)
	return cameraResult.HitPos and Vector(cameraResult.HitPos) or cameraTrace.endpos
end

-- an error in the prediction must not take every addon's camera with it: CalcView still runs
-- (unmoved), the error is printed once
local predictionErrorPrinted = false
local function calcView(originalCall, gamemodeTable, player, origin, angles, fov, nearZ, farZ, ...)
	local updated, message = pcall(updateFrame)
	if not updated and not predictionErrorPrinted then
		predictionErrorPrinted = true
		ErrorNoHalt("[audio_engine] driving prediction: " .. tostring(message) .. "\n")
	end
	local view = originalCall("CalcView", gamemodeTable, player, origin, angles, fov, nearZ, farZ, ...)
	-- (the car you sit in drawn moved, by the prediction or less leaning: the camera with it)
	local car = updated and cameraCar()
	local entry = car and displaced[car]
	local thirdPerson = IsValid(car) and IsValid(player) and thirdPersonOrigin(player, car, (type(view) == "table" and view.angles) or angles)
	if not entry and not thirdPerson then return view end
	-- a copy: some cameras hand back the same table each frame
	local moved = {}
	if type(view) == "table" then for key, value in pairs(view) do moved[key] = value end end
	moved.fov, moved.znear, moved.zfar = moved.fov or fov, moved.znear or nearZ, moved.zfar or farZ
	if thirdPerson then
		-- (already from the car as drawn; the look direction is the player's own, not turned with the car)
		moved.origin, moved.angles, moved.drawviewer = thirdPerson, moved.angles or angles, true
	else
		moved.origin, moved.angles = mapPose(entry, moved.origin or origin, moved.angles or angles)
	end
	cameraFrame = FrameNumber()
	return moved
end

--[[
	Our wrappers can end up nested: another addon wrapping hook.Call after us (and calling through
	to ours), our timer wrapping theirs again, or a Lua refresh wrapping the last load's. Each
	CalcView then went through calcView twice and the camera moved by the lead twice. So:
	  * every wrapper we ever made is known (AudioEngine.predictHookCalls, kept over a refresh), and
	    hook.Call is wrapped again only if it isn't one of ours;
	  * the wrappers call the newest calcView (AudioEngine.PredictCalcView), not their own load's;
	  * inside a CalcView we're already moving, the next wrapper down just passes it on.
]]
AudioEngine.predictHookCalls = AudioEngine.predictHookCalls or setmetatable({}, { __mode = "k" })
AudioEngine.PredictCalcView = calcView
local ourCalls = AudioEngine.predictHookCalls

local function wrapHookCall()
	if ourCalls[hook.Call] then return end
	local originalCall = hook.Call
	local function call(name, gamemodeTable, ...)
		if name ~= "CalcView" or AudioEngine.predictInCalcView then return originalCall(name, gamemodeTable, ...) end
		AudioEngine.predictInCalcView = true
		local succeeded, view = pcall(AudioEngine.PredictCalcView, originalCall, gamemodeTable, ...)
		AudioEngine.predictInCalcView = false
		if not succeeded then error(view, 0) end
		return view
	end
	ourCalls[call] = true
	hook.Call = call
end
wrapHookCall()
-- (a hook library loaded later may replace hook.Call: wrap it again)
timer.Create("audio_engine_predict_wrap", 2, 0, wrapHookCall)

-- before anything is drawn: if the camera didn't run through us this frame, nothing may be moved
-- (the car would leave the camera behind)
-- (another view drawn before the main one, a mirror or camera, finds nothing moved yet: it's
-- drawn at Source's poses, and the main view's CalcView still works this frame out)
hook.Add("PreDrawOpaqueRenderables", "audio_engine_predict", function()
	local frame = FrameNumber()
	if updatedFrame ~= frame then
		table.Empty(displaced)
		takePlacementsOff()
		clearStale(frame)
		return
	elseif cameraCar() and displaced[cameraCar()] and cameraFrame ~= frame then
		table.Empty(displaced)
		takePlacementsOff()
		clearStale(frame + 1)
		return
	end
	putPlacementsOn()
end)

hook.Add("PostRender", "audio_engine_predict", takePlacementsOff)

---------------------------------------------------------------------------
-- drivers and passengers sit in the car as drawn
---------------------------------------------------------------------------
local movedPlayers = {}
hook.Add("PrePlayerDraw", "audio_engine_predict", function(player)
	local car = AudioEngine.RiddenCar(player)
	local entry = car and displaced[car]
	if not entry then return end
	local position = mapPose(entry, player:GetPos(), player:GetAngles())
	player:SetRenderOrigin(position)
	player:InvalidateBoneCache()
	movedPlayers[player] = true
end)

hook.Add("PostPlayerDraw", "audio_engine_predict", function(player)
	if not movedPlayers[player] then return end
	movedPlayers[player] = nil
	player:SetRenderOrigin(nil)
	player:InvalidateBoneCache()
end)

-- (fullUpdate: the game "removes" every entity on a full update, but they stay: see cl_engine)
hook.Add("EntityRemoved", "audio_engine_predict", function(entity, fullUpdate)
	if fullUpdate then return end
	displaced[entity], overridden[entity], childrenCache[entity], originalBounds[entity], placements[entity] = nil, nil, nil, nil, nil
	if own.vehicle == entity then own.vehicle, own.base = nil, nil end
end)

---------------------------------------------------------------------------
-- checking it
---------------------------------------------------------------------------
local RED, YELLOW, GREEN = Color(255, 60, 60), Color(255, 220, 40), Color(60, 255, 90)
hook.Add("PostDrawTranslucentRenderables", "audio_engine_predict_debug", function(drawingDepth, drawingSkybox)
	if drawingDepth or drawingSkybox or not debugConVar:GetBool() then return end
	local vehicle, base = own.vehicle, own.base
	if not IsValid(vehicle) or not base then return end
	local mins, maxs = vehicle:OBBMins(), vehicle:OBBMaxs()
	render.DrawWireframeBox(Vector(base.px, base.py, base.pz), Handling.AnglesOf(base), mins, maxs, RED, false)
	render.DrawWireframeBox(vehicle:GetPos(), vehicle:GetAngles(), mins, maxs, YELLOW, false)
	if own.displayPosition then render.DrawWireframeBox(own.displayPosition, own.displayAngles, mins, maxs, GREEN, false) end
end)

concommand.Add("audio_engine_predict_stats", function()
	local stats = own.stats
	local learner = own.learner
	print(string.format("[Audio Engine] prediction %s, car %s | states %d | frames matched %d, fallback %d | replaying %d commands + %.2f",
		predictionAllowed() and "on" or "off", IsValid(own.vehicle) and tostring(AudioEngine.GetCarConfig(own.vehicle) and AudioEngine.GetCarConfig(own.vehicle).name) or "-",
		stats.states, stats.matched, stats.fallback, own.count or 0, own.fraction or 0))
	print(string.format("  corrections %d, mean %.1f in, largest %.1f in | wall stops %d | lead %.0f ms (ping %d, interp %.0f ms) | others %s | learned samples %d",
		stats.corrections, stats.corrections > 0 and stats.correctionSum / stats.corrections or 0, stats.largest, stats.clamped,
		(own.lead or 0) * 1000, LocalPlayer():Ping(), interpolationDelay() * 1000, othersConVar:GetBool() and "on" or "off", learner and learner.samples or 0))
	own.stats = { states = 0, matched = 0, fallback = 0, corrections = 0, correctionSum = 0, largest = 0, clamped = 0 }
end, nil, "Print how the driving prediction is doing (and start counting again)")
