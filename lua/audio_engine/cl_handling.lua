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

local predictConVar = CreateClientConVar("audio_engine_predict", "1", true, false,
	"1 = the car you drive is shown where it will be when the server runs your keys (no input delay); 0 = as Source shows it")
-- (a tester asked to dial in how much of it they get)
local amountConVar = CreateClientConVar("audio_engine_predict_amount", "1", true, false,
	"How far ahead the prediction draws your car (and the other cars with it): 1 = where the server will have it (no input delay), "
		.. "0.5 = half way, 0 = where Source shows it", 0, 1)
local othersConVar = CreateClientConVar("audio_engine_predict_others", "1", true, false,
	"1 = while you drive with prediction, other moving cars are shown where they are now too, so close driving and crashes line up")
local debugConVar = CreateClientConVar("audio_engine_predict_debug", "0", false, false,
	"1 = draw the server's car (red), Source's (yellow) and the predicted one (green), and what the prediction does on screen")

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
	-- other cars: your car as drawn stops at their footprints, this share of their bounds (a bit
	-- under: mirrors stick out, and moving cars' drawn poses are an estimate)
	carShrink = 0.9,
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
local commandClock = Handling.NewClientClock()

local function commandKeyDown(command, key) return command:KeyDown(key) end

hook.Add("StartCommand", "audio_engine_predict", function(player, command)
	if player ~= LocalPlayer() then return end
	local number = command:CommandNumber()
	if number == 0 then return end
	local slot = number % HISTORY
	historyNumbers[slot], historyButtons[slot] = number, Handling.ButtonsFrom(commandKeyDown, command)
	if number > newestCommand then
		newestCommand, newestCommandAt = number, RealTime()
		Handling.ClientClockSeen(commandClock, number, newestCommandAt, engine.TickInterval())
	end
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
	if not predictConVar:GetBool() or game.SinglePlayer() then return false end
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
	own.vehicle, own.base, own.previousBase, own.fresh, own.shown, own.steerPose = vehicle, nil, nil, false, false, nil
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

---------------------------------------------------------------------------
-- audio_engine_predict_record [seconds]: writes data/audio_engine_predict_log.csv. A row "S" per
-- state from the server: what this client's replay from the previous state said the car would be
-- at the same command, next to what the server says (the error the smoother then hides). A row "F"
-- per frame: the yaw drawn, the prediction's own, Source's, and the smoother's offset
---------------------------------------------------------------------------
local record = nil   -- { untilTime, rows, startTime }
local recordCommands, recordBody, recordReplayState = {}, {}, {}
local DEG = 180 / math.pi
local function keysText(buttons)
	buttons = buttons or 0
	local text = ""
	for _, pair in ipairs({ { 1, "W" }, { 2, "S" }, { 4, "A" }, { 8, "D" }, { 16, "_" } }) do
		if math.floor(buttons / pair[1]) % 2 == 1 then text = text .. pair[2] end
	end
	return text == "" and "-" or text
end
local function yawOf(body) return math.deg(math.atan2(body.ay, body.ax)) end
-- the travel direction against the nose (deg, + = sliding to the right of it), and the speed (mph)
local function slipOf(body, spec)
	local noseX, noseY, _, rightX, rightY = Handling.NoseOf(body, spec)
	local forward, side = body.vx * noseX + body.vy * noseY, body.vx * rightX + body.vy * rightY
	local speed = math.sqrt(body.vx * body.vx + body.vy * body.vy)
	if speed < 50 then return 0, speed / 17.6 end
	return math.deg(math.atan2(side, math.abs(forward))), speed / 17.6
end
local function recordRow(row)
	if record then record.rows[#record.rows + 1] = row end
end

-- how much of the predicted rotation the server's car really turned from the previous state to
-- this one (Handling.LearnYaw: the prediction turns the car that much less)
local yawCommands, yawBody, yawState = {}, {}, {}
local function learnYaw(previous, state)
	if not previous or not own.spec or not own.learner or state.impact or previous.impact then return end
	if state.groundShare < 1 or previous.groundShare < 1 or state.drift or previous.drift then return end
	if state.command <= previous.command or state.command - previous.command > PREDICTION.maxCommands then return end
	local count = 0
	for number = previous.command + 1, state.command do
		count = count + 1
		yawCommands[count] = buttonsOf(number) or yawCommands[count - 1] or previous.buttons or 0
	end
	local predicted = Handling.Predict(previous, yawCommands, count, 0, own.spec, own.learner, engine.TickInterval(), yawBody, yawState)
	local previousYaw = math.deg(math.atan2(previous.ay, previous.ax))
	local predictedTurn = math.NormalizeAngle(math.deg(math.atan2(predicted.ay, predicted.ax)) - previousYaw)
	-- (too little turn to measure, or turning the other way: a kerb, a bump)
	if math.abs(predictedTurn) < 0.3 then return end
	local serverTurn = math.NormalizeAngle(math.deg(math.atan2(state.ay, state.ax)) - previousYaw)
	if serverTurn * predictedTurn <= 0 then return end
	local forwardSpeed = Handling.ForwardSpeed(previous, own.spec)
	Handling.LearnYaw(own.learner, forwardSpeed, Handling.YawShareAt(own.learner, forwardSpeed) * serverTurn / predictedTurn)
end

local function recordState(previous, state)
	if not record or not previous or not own.spec then return end
	local count = 0
	for number = previous.command + 1, math.min(state.command, previous.command + PREDICTION.maxCommands) do
		count = count + 1
		recordCommands[count] = buttonsOf(number) or recordCommands[count - 1] or previous.buttons or 0
	end
	local predicted, predictedState = Handling.Predict(previous, recordCommands, count, 0, own.spec, own.learner, engine.TickInterval(), recordBody, recordReplayState)
	local noseX, noseY, _, rightX, rightY = Handling.NoseOf(state, own.spec)
	local errorX, errorY = predicted.px - state.px, predicted.py - state.py
	local serverSlip, mph = slipOf(state, own.spec)
	local predictedSlip = slipOf(predicted, own.spec)
	local serverYaw, predictedYaw = yawOf(state), yawOf(predicted)
	recordRow(string.format("S,%.3f,%d,%d,%s,%s,%.0f,%.2f,%.2f,%.1f,%.1f,%.1f,%.1f,%.2f,%.2f,%.2f,%.1f,%.1f,%.1f,%.1f,%.2f,%.2f",
		state.time - record.startTime, state.command, count, keysText(state.buttons), keysText(recordCommands[count] or previous.buttons),
		mph, state.steer, predictedState.steer or 0, state.yawTarget or 0, predictedState.yawTarget or 0, state.yawRate, predicted.yawRate,
		serverYaw, predictedYaw, math.NormalizeAngle(predictedYaw - serverYaw),
		errorX * noseX + errorY * noseY, errorX * rightX + errorY * rightY, serverSlip, predictedSlip,
		state.controlShare, state.groundShare))
end

local function recordFrame(realNow, predicted, display, vehicle, keys)
	if not record then return end
	if realNow > record.untilTime then
		local lines = { "kind,time,command,replayed,keys_server,keys_client,mph,steer_server,steer_client,yawtarget_server,yawtarget_client,"
			.. "yawrate_server,yawrate_client,yaw_server,yaw_client,yaw_error,pos_error_forward_in,pos_error_side_in,slip_server,slip_client,control,ground",
			"# F rows: kind,time,keys,mph,yaw_drawn,yaw_predicted,yaw_source,drawn_minus_source,smoother_in,smoother_yaw_deg,lead_ms,commands,wheels_drawn,wheels_source" }
		for _, row in ipairs(record.rows) do lines[#lines + 1] = row end
		file.Write("audio_engine_predict_log.csv", table.concat(lines, "\n"))
		print(string.format("[Audio Engine] prediction log: %d rows -> garrysmod/data/audio_engine_predict_log.csv", #record.rows))
		record = nil
		return
	end
	local drawnYaw, sourceYaw = own.displayAngles and own.displayAngles.y or 0, vehicle:GetAngles().y
	local _, mph = slipOf(predicted, own.spec)
	recordRow(string.format("F,%.3f,%s,%.0f,%.1f,%.1f,%.1f,%.1f,%.1f,%.2f,%.0f,%d,%.2f,%.2f",
		CurTime() - record.startTime, keysText(keys), mph, drawnYaw, yawOf(predicted), sourceYaw,
		math.NormalizeAngle(drawnYaw - sourceYaw), Handling.SmootherSize(own.smoother), (own.smoother.rz or 0) * DEG,
		(own.lead or 0) * 1000, own.count or 0, own.steerPose or 0, own.sourceSteerPose or 0))
end

concommand.Add("audio_engine_predict_record", function(_, _, args)
	local seconds = math.Clamp(tonumber(args[1]) or 15, 1, 120)
	record = { untilTime = RealTime() + seconds, rows = {}, startTime = CurTime() }
	print(string.format("[Audio Engine] recording the prediction for %d s: drive, turn, let go", seconds))
end, nil, "audio_engine_predict_record [seconds]: log the server's states against this client's prediction to data/audio_engine_predict_log.csv")

net.Receive("audio_engine_drive", function()
	local index = net.ReadUInt(13)
	local state = { command = net.ReadUInt(32) }
	state.commandFraction = net.ReadUInt(8) / 256
	state.time = net.ReadDouble()
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
	recordState(base, state)
	learnYaw(base, state)
	learnFrom(base, state)
	own.previousBase, own.base, own.fresh = base, state, true
	own.stats.states = own.stats.states + 1
	local received = own.received
	received[#received + 1] = { time = state.time, x = state.px, y = state.py, z = state.pz }
	if #received > RECEIVED then table.remove(received, 1) end
end)

-- the commands the server hasn't run after `number`, into list; count, and how far into the next one the frame is
local function commandsAfter(base, list)
	local number, count = base.command, 0
	if number ~= 0 and newestCommand > number and buttonsOf(number + 1) then
		-- (from where the server's physics stands, Handling.CommandClock, to the command clock now)
		local tick = engine.TickInterval()
		local span = Handling.ClientClockNow(commandClock, RealTime(), tick, newestCommand) - number - (base.commandFraction or 0)
		span = clamp(span, 0, PREDICTION.maxCommands)
		local whole = math.floor(span)
		local last = base.buttons or 0
		for commandNumber = number + 1, number + whole do
			count = count + 1
			last = buttonsOf(commandNumber) or last
			list[count] = last
		end
		return count, span - whole, true, buttonsOf(number + whole + 1) or last
	end
	-- no command numbers to match (shouldn't happen in multiplayer): one ping of the keys held now
	local player = LocalPlayer()
	local buttons = Handling.ButtonsFrom(function(target, key) return target:KeyDown(key) end, player)
	count = clamp(math.Round(player:Ping() / 1000 / engine.TickInterval()), 0, PREDICTION.maxCommands)
	for i = 1, count do list[i] = buttons end
	return count, 0, false, buttons
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

local function sweep(fromPosition, toPosition, offset, height)
	traceData.start, traceData.endpos = fromPosition + offset + height, toPosition + offset + height
	util.TraceHull(traceData)
	return traceResult
end

--[[
	How far (0..1) one end of the car (`offset` from its origin) can go from `fromPosition` towards
	`toPosition` (`distance` apart). The end can already be in something: the server's car against a
	wall, nose first. That was taken as clear, and the prediction (no walls: still on the throttle)
	drew the car up to a whole lead deep into the wall. Then the box is swept from the car's middle
	instead, `pullback` further along the travel, and the end stops where the middle's box would put
	it. Ground under the box (see groundNormal) isn't a wall: looked at again higher
]]
local function endClearShare(fromPosition, toPosition, travelDirection, distance, offset, pullback, up)
	local result = 1
	for _, lift in ipairs({ 0, PREDICTION.traceRetryLift }) do
		local height = up * (PREDICTION.traceHeight + lift)
		local trace = sweep(fromPosition, toPosition, offset, height)
		if not trace.Hit then return 1 end
		if trace.StartSolid then
			trace = sweep(fromPosition, toPosition + travelDirection * pullback, vector_origin, height)
			if not trace.Hit then return 1 end
			if trace.StartSolid then
				result = 0
			elseif trace.HitNormal:Dot(up) < PREDICTION.groundNormal then
				return clamp((trace.Fraction * (distance + pullback) - pullback - 2) / distance, 0, 1)
			else
				result = 1
			end
		elseif trace.HitNormal:Dot(up) < PREDICTION.groundNormal then
			return math.max(0, trace.Fraction - 2 / distance)
		else
			result = 1
		end
	end
	return result
end

-- how far (0..1) the car can go from `fromPosition` towards `toPosition` before its leading end
-- (along `direction`, a unit vector) hits something. halfLength/halfWidth in inches, up = its up.
-- Moving mostly sideways (a slide, a drift) both ends lead: the rear went through walls
local SIDEWAYS_SHARE = 0.7   -- travel . nose under this share of the travel: both ends traced
local function clearShare(fromPosition, toPosition, direction, up, halfLength, halfWidth)
	local travel = toPosition - fromPosition
	local distance = travel:Length()
	if distance < 6 then return 1 end
	traceMins.x, traceMins.y, traceMins.z = -halfWidth, -halfWidth, -PREDICTION.traceHalfHeight
	traceMaxs.x, traceMaxs.y, traceMaxs.z = halfWidth, halfWidth, PREDICTION.traceHalfHeight
	local travelDirection = travel / distance
	local alongShare = travelDirection:Dot(direction)
	local reach = halfLength - halfWidth
	local pullback = reach * math.abs(alongShare)
	local leading = direction * (alongShare >= 0 and reach or -reach)
	local share = endClearShare(fromPosition, toPosition, travelDirection, distance, leading, pullback, up)
	if share > 0 and math.abs(alongShare) < SIDEWAYS_SHARE then
		share = math.min(share, endClearShare(fromPosition, toPosition, travelDirection, distance, -leading, pullback, up))
	end
	return share
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

-- the base gamemode's third-person vehicle camera sets its distance from the car's render bounds:
-- widened, it zoomed out (the user). The camera is worked out with the car's own bounds
local function withOwnBounds(entity, call, ...)
	local bounds = IsValid(entity) and originalBounds[entity]
	if not bounds or bounds.pad == 0 then return call(...) end
	entity:SetRenderBounds(bounds.mins, bounds.maxs)
	local results = { call(...) }
	local padding = Vector(bounds.pad, bounds.pad, bounds.pad)
	entity:SetRenderBounds(bounds.mins - padding, bounds.maxs + padding)
	return unpack(results)
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

--[[
	The front wheels and the steering wheel follow the "vehicle_steer" pose, which Source sets from
	its steering on the server: on your own car they turned ~a ping + interp after the drawn car did
	(the user: the model doesn't animate the steering the way you see it, but the server's way).
	While the car is drawn predicted, the pose is the prediction's steering (Source: -1 left .. 1
	right; the model's steer is + left), put back once the frame is drawn
]]
local STEER_POSE = "vehicle_steer"
local steerPose = nil   -- { entity, index, value (the pose's own units), restore }

local function putSteerPose()
	local vehicle, value = own.vehicle, own.steerPose
	if not value or not IsValid(vehicle) or not displaced[vehicle] then return end
	local index = vehicle:LookupPoseParameter(STEER_POSE)
	if not index or index < 0 then return end
	local low, high = vehicle:GetPoseParameterRange(index)
	if not low or high <= low then return end
	-- (the client reads a pose as 0..1 of its range and sets it in the range's own units)
	local restore = low + vehicle:GetPoseParameter(STEER_POSE) * (high - low)
	vehicle:SetPoseParameter(STEER_POSE, clamp(value, -1, 1) * math.max(math.abs(low), math.abs(high)))
	steerPose = { entity = vehicle, restore = restore }
end

--[[
	How far Source turns the wheels at a speed, as a share of full lock (the pose's 1): it draws
	the wheels' angle as a share of DegreesSlow, and the angle shrinks with speed (to DegreesFast,
	over FastCarSpeed the model's turn): the full pose at any speed turned them far too much (the
	user). Learned per speed band from Source's own pose while the server's steering has held full
	lock a while; until then the model's turn angle at that speed / its slow lock
]]
local WHEEL_BAND = 5            -- m/s
local WHEEL_BANDS = 16
local WHEEL_LEARN_RATE = 0.2
local WHEEL_STEADY = 0.4        -- s the server's steering held full lock before Source's pose is trusted
local wheelShares = {}          -- model -> { [band] = share }

-- Source's pose now, -1..1 (read while nothing of ours is on it)
local function sourceSteerPose(vehicle)
	local index = vehicle:LookupPoseParameter(STEER_POSE)
	if not index or index < 0 then return nil end
	local low, high = vehicle:GetPoseParameterRange(index)
	if not low or high <= low then return nil end
	return (low + vehicle:GetPoseParameter(STEER_POSE) * (high - low)) / math.max(math.abs(low), math.abs(high))
end

local function wheelShareAt(vehicle, spec, speed)
	local shares = wheelShares[vehicle:GetModel() or ""]
	local learned = shares and shares[clamp(math.floor(speed / WHEEL_BAND) + 1, 1, WHEEL_BANDS)]
	if learned then return learned end
	local settings = spec.settings
	return clamp(Handling.TurnAngle(settings, spec.wheelbase, speed) / settings.lockSlow, 0.05, 1)
end

local function learnWheelShare(vehicle, base, speed, realNow)
	if math.abs(base.steer or 0) < 0.99 then own.fullLockSince = nil return end
	own.fullLockSince = own.fullLockSince or realNow
	local pose = own.sourceSteerPose
	if realNow - own.fullLockSince < WHEEL_STEADY or not pose or pose * base.steer > 0 then return end
	local model = vehicle:GetModel() or ""
	local shares = wheelShares[model]
	if not shares then shares = {}; wheelShares[model] = shares end
	local band = clamp(math.floor(speed / WHEEL_BAND) + 1, 1, WHEEL_BANDS)
	local share = clamp(math.abs(pose), 0, 1)
	shares[band] = shares[band] and shares[band] + (share - shares[band]) * WHEEL_LEARN_RATE or share
end

--[[
	How fast the drawn wheels turn, in pose units (-1..1) a second. The model's steering reaches
	full lock in ~0.14 s (steerRate 7), and so do Source's wheels (sv_handling sets its steering
	rates to the model's): drawn at that, the wheels snapped to their full turn (the user). Drawn
	at a script's usual rate instead (SlowSteeringRate ~3), going towards the predicted steering
]]
local WHEEL_RATE = 3

local function takeSteerPoseOff()
	if not steerPose then return end
	if IsValid(steerPose.entity) then steerPose.entity:SetPoseParameter(STEER_POSE, steerPose.restore) end
	steerPose = nil
end

local function putPlacementsOn()
	if placementsOn then return end
	placementsOn = true
	putSteerPose()
	for entity, placement in pairs(placements) do
		if IsValid(entity) then
			entity:SetRenderOrigin(placement.position)
			setRenderAngles(entity, placement.angles)
			entity:InvalidateBoneCache()
		end
	end
end

local function takePlacementsOff()
	takeSteerPoseOff()
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
-- other cars: your car as drawn stops at them. The wall trace leaves cars out (your own, the
-- ones moved over the lead), so the prediction drew your car through a car it was pushing, or a
-- parked one, by up to the lead (~7 m at 30 m/s) until the server's crash came back. Drawn cars'
-- footprints (boxes on the ground, carShrink of their bounds) are tested against each other in
-- plain maths: no traces. Cars yours already overlaps at the server's pose are left out (contact
-- the server is playing out)
---------------------------------------------------------------------------
local carList, nextCarList = {}, 0
local function jeeps(realNow)
	if realNow >= nextCarList then
		nextCarList = realNow + 0.5
		carList = ents.FindByClass("prop_vehicle_jeep")
	end
	return carList
end

local footprintSizes = {}
local function footprintSizeOf(vehicle, spec)
	local model = vehicle:GetModel() or ""
	local size = footprintSizes[model]
	if size then return size end
	local mins, maxs = vehicle:OBBMins(), vehicle:OBBMaxs()
	local alongY = math.abs(spec.noseY) > math.abs(spec.noseX)
	local shrink = PREDICTION.carShrink
	size = {
		centre = (mins + maxs) * 0.5,
		halfLength = (alongY and (maxs.y - mins.y) or (maxs.x - mins.x)) * 0.5 * shrink,
		halfWidth = (alongY and (maxs.x - mins.x) or (maxs.y - mins.y)) * 0.5 * shrink,
		halfHeight = (maxs.z - mins.z) * 0.5,
	}
	footprintSizes[model] = size
	return size
end

-- a car's footprint at a pose, into box: centre, nose (unit, flat), half sizes. nil if it stands on its nose
local function footprint(vehicle, spec, position, angles, box)
	local size = footprintSizeOf(vehicle, spec)
	local centre = LocalToWorld(size.centre, angle_zero, position, angles)
	local forward, right, up = angles:Forward(), angles:Right(), angles:Up()
	-- (model x = forward, y = left, z = up)
	local noseX = forward.x * spec.noseX - right.x * spec.noseY + up.x * spec.noseZ
	local noseY = forward.y * spec.noseX - right.y * spec.noseY + up.y * spec.noseZ
	local length = math.sqrt(noseX * noseX + noseY * noseY)
	if length < 0.1 then return nil end
	box.x, box.y, box.z = centre.x, centre.y, centre.z
	box.noseX, box.noseY = noseX / length, noseY / length
	box.halfLength, box.halfWidth, box.halfHeight = size.halfLength, size.halfWidth, size.halfHeight
	return box
end

local function radiusAlong(box, axisX, axisY)
	return box.halfLength * math.abs(box.noseX * axisX + box.noseY * axisY) + box.halfWidth * math.abs(box.noseX * axisY - box.noseY * axisX)
end

-- two footprints overlap (separating axes: each box's nose and side; and their heights)
local function overlapping(first, second)
	if math.abs(first.z - second.z) >= first.halfHeight + second.halfHeight then return false end
	local deltaX, deltaY = second.x - first.x, second.y - first.y
	for axis = 1, 4 do
		local box = axis <= 2 and first or second
		local axisX, axisY = box.noseX, box.noseY
		if axis % 2 == 0 then axisX, axisY = -box.noseY, box.noseX end
		if math.abs(deltaX * axisX + deltaY * axisY) >= radiusAlong(first, axisX, axisY) + radiusAlong(second, axisX, axisY) then return false end
	end
	return true
end

local ownBox, blockerBoxes, blockerActive = {}, {}, {}
local blockerCount = 0

local function blockedAt(vehicle, spec, share, fromPosition, fromAngles, toPosition, toAngles)
	local box = footprint(vehicle, spec, LerpVector(share, fromPosition, toPosition), LerpAngle(share, fromAngles, toAngles), ownBox)
	if not box then return false end
	for i = 1, blockerCount do
		if blockerActive[i] and overlapping(box, blockerBoxes[i]) then return true end
	end
	return false
end

-- your car from the server's pose to where it's drawn: the pose it's drawn at, short of the
-- first car in the way (as drawn this frame), and whether one was
local function carStop(vehicle, spec, fromPosition, fromAngles, toPosition, toAngles, realNow)
	local reach = fromPosition:Distance(toPosition)
	if reach < 6 then return toPosition, toAngles, false end
	local ownSize = footprintSizeOf(vehicle, spec)
	blockerCount = 0
	for _, other in ipairs(jeeps(realNow)) do
		if IsValid(other) and other ~= vehicle and not other:IsDormant() then
			local entry = displaced[other]
			local position = entry and entry.toPosition or other:GetPos()
			local otherSpec = specOf(other)
			local otherSize = footprintSizeOf(other, otherSpec)
			local near = reach + ownSize.halfLength + ownSize.halfWidth + otherSize.halfLength + otherSize.halfWidth
			if position:DistToSqr(toPosition) < near * near then
				local box = footprint(other, otherSpec, position, entry and entry.toAngles or other:GetAngles(), blockerBoxes[blockerCount + 1] or {})
				if box then
					blockerCount = blockerCount + 1
					blockerBoxes[blockerCount] = box
				end
			end
		end
	end
	if blockerCount == 0 then return toPosition, toAngles, false end
	local startBox = footprint(vehicle, spec, fromPosition, fromAngles, ownBox)
	if not startBox then return toPosition, toAngles, false end
	local any = false
	for i = 1, blockerCount do
		blockerActive[i] = not overlapping(startBox, blockerBoxes[i])
		any = any or blockerActive[i]
	end
	if not any or not blockedAt(vehicle, spec, 1, fromPosition, fromAngles, toPosition, toAngles) then return toPosition, toAngles, false end
	local low, high = 0, 1
	for _ = 1, 7 do
		local middle = (low + high) * 0.5
		if blockedAt(vehicle, spec, middle, fromPosition, fromAngles, toPosition, toAngles) then high = middle else low = middle end
	end
	return LerpVector(low, fromPosition, toPosition), LerpAngle(low, fromAngles, toAngles), true
end

---------------------------------------------------------------------------
-- the road under a car as drawn. The prediction carries a car on along the slope it was on:
-- into a dip that line runs under the road, past a crest it floats and then sinks (the user:
-- "disappears into the ground"). Each axle is put as high over the road under it as Source has
-- it over the road where Source has the car (traces straight down, world only), which sets the
-- drawn car's height and pitch
---------------------------------------------------------------------------
local GROUND_ABOVE = 40       -- inches over an axle the trace starts
local GROUND_BELOW = 140      -- ...and under it it ends
local GROUND_MAX = 60         -- inches: a bigger difference isn't followed (a ledge, a ramp's end)
local GROUND_AIR = 40         -- inches over the road at Source's pose: in the air, not followed
local GROUND_SMOOTH = 0.03    -- s
local GROUND_CARS = 6         -- the nearest this many moved cars besides yours
local groundStart, groundEnd = Vector(), Vector()
local groundResult = {}
local groundData = { start = groundStart, endpos = groundEnd, mask = MASK_SOLID_BRUSHONLY, output = groundResult }

local function roadHeight(x, y, z)
	groundStart:SetUnpacked(x, y, z + GROUND_ABOVE)
	groundEnd:SetUnpacked(x, y, z - GROUND_BELOW)
	util.TraceLine(groundData)
	if groundResult.Hit and not groundResult.StartSolid and groundResult.HitNormal.z > 0.5 then return groundResult.HitPos.z end
end

-- the nose (flat-ish unit vector, world) of a car at angles
local function noseAt(spec, angles)
	local forward, right, up = angles:Forward(), angles:Right(), angles:Up()
	return forward * spec.noseX - right * spec.noseY + up * spec.noseZ
end

-- how high each axle stands over the road under it: front, rear (inches), or nil
local function axleClearances(spec, position, angles)
	local half = spec.wheelbase / Handling.INCH * 0.5
	local nose = noseAt(spec, angles)
	local frontX, frontY, frontZ = position.x + nose.x * half, position.y + nose.y * half, position.z + nose.z * half
	local rearX, rearY, rearZ = position.x - nose.x * half, position.y - nose.y * half, position.z - nose.z * half
	local front, rear = roadHeight(frontX, frontY, frontZ), roadHeight(rearX, rearY, rearZ)
	if not front or not rear then return nil end
	return frontZ - front, rearZ - rear, nose, half
end

local rotateSign = nil   -- Angle:RotateAroundAxis's sense about the car's right, found once

-- the drawn pose put on the road; record keeps the smoothing. Returns position, angles
local function followGround(spec, sourcePosition, sourceAngles, toPosition, toAngles, record, frameTime)
	local sourceFront, sourceRear = axleClearances(spec, sourcePosition, sourceAngles)
	local frontRaise, rearRaise = 0, 0
	if sourceFront and sourceFront < GROUND_AIR and sourceRear < GROUND_AIR then
		local drawnFront, drawnRear, nose, half = axleClearances(spec, toPosition, toAngles)
		if drawnFront then
			frontRaise, rearRaise = sourceFront - drawnFront, sourceRear - drawnRear
			if math.abs(frontRaise) > GROUND_MAX or math.abs(rearRaise) > GROUND_MAX then frontRaise, rearRaise = 0, 0 end
			record.half, record.nose = half, nose
		end
	end
	local keep = math.exp(-frameTime / GROUND_SMOOTH)
	record.front = (record.front or frontRaise) * keep + frontRaise * (1 - keep)
	record.rear = (record.rear or rearRaise) * keep + rearRaise * (1 - keep)
	local front, rear = record.front, record.rear
	if math.abs(front) + math.abs(rear) < 0.05 or not record.half then return toPosition, toAngles end
	local position = Vector(toPosition.x, toPosition.y, toPosition.z + (front + rear) * 0.5)
	local tilt = math.deg(math.atan((front - rear) / (2 * record.half)))
	if math.abs(tilt) < 0.01 then return position, toAngles end
	local nose = noseAt(spec, toAngles)
	local axis = nose:Cross(Vector(0, 0, 1))
	if axis:LengthSqr() < 0.01 then return position, toAngles end
	axis:Normalize()
	local angles = Angle(toAngles.p, toAngles.y, toAngles.r)
	if not rotateSign then
		local test = Angle(toAngles.p, toAngles.y, toAngles.r)
		test:RotateAroundAxis(axis, 5)
		rotateSign = noseAt(spec, test).z > nose.z and 1 or -1
	end
	angles:RotateAroundAxis(axis, tilt * rotateSign)
	return position, angles
end

---------------------------------------------------------------------------
-- other cars, carried on over the same lead
---------------------------------------------------------------------------
local motions = setmetatable({}, { __mode = "k" })
local othersShare = 0
local nearby = {}

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

--[[
	How far behind its newest received position Source draws a car, in seconds of its motion
	(smoothed; nil until it has moved). The other cars were carried on by your own car's lead,
	which assumes Source draws them as late as yours: at 100 mph they showed a whole car length
	behind (the user), ~0.1 s, an interpolation's worth. Measured the same way on every car, the
	snapshots' own age cancels out: a car's lead is yours + (its lag - your car's)
]]
local LAG_SMOOTH = 1          -- s
local LAG_MIN_SPEED = 300     -- inches/s
local function drawnLag(vehicle, velocity, record, frameTime)
	local speedSqr = velocity:LengthSqr()
	if speedSqr < LAG_MIN_SPEED * LAG_MIN_SPEED or frameTime <= 0 then return record.lag end
	local behind = clamp((vehicle:GetNetworkOrigin() - vehicle:GetPos()):Dot(velocity) / speedSqr, 0, PREDICTION.maxLead)
	record.lag = record.lag and record.lag + (behind - record.lag) * math.min(1, frameTime / LAG_SMOOTH) or behind
	return record.lag
end

local function updateOthers(ownVehicle, lead, frame, realNow, eyePosition, frameTime)
	table.Empty(nearby)
	local maxDistanceSqr = PREDICTION.othersDistance * PREDICTION.othersDistance
	for _, vehicle in ipairs(jeeps(realNow)) do
		if IsValid(vehicle) and vehicle ~= ownVehicle and not vehicle:IsDormant() then
			local distanceSqr = vehicle:GetPos():DistToSqr(eyePosition)
			if distanceSqr < maxDistanceSqr then nearby[#nearby + 1] = { vehicle = vehicle, distanceSqr = distanceSqr } end
		end
	end
	table.sort(nearby, function(first, second) return first.distanceSqr < second.distanceSqr end)
	for i = 1, math.min(#nearby, PREDICTION.othersMax) do
		local vehicle = nearby[i].vehicle
		local motion = motionOf(vehicle, realNow)
		local speed = motion.velocity:Length()
		local share = clamp((speed - PREDICTION.othersMinSpeed) / (PREDICTION.othersFullSpeed - PREDICTION.othersMinSpeed), 0, 1) * othersShare
		if share > 0 and motion.samples >= 3 then
			-- (drawn later than your car by Source: that much more lead)
			local lag = drawnLag(vehicle, motion.velocity, motion, frameTime)
			local extra = (lag and own.drawnLag) and clamp(lag - own.drawnLag, -lead, PREDICTION.maxLead) or 0
			motion.extraLead = extra
			local carLead = (lead + extra) * share * amountConVar:GetFloat()
			local turn = motion.yawRate * carLead
			local travel = motion.velocity * carLead
			travel:Rotate(Angle(0, turn * 0.5, 0))           -- along the arc it's turning on
			local position, angles = vehicle:GetPos(), vehicle:GetAngles()
			-- (along the ground only: its bumps carried over the lead made it bob, as your own did)
			local up = vehicle:GetUp()
			travel = travel - up * travel:Dot(up)
			local toPosition = position + travel
			local spec = specOf(vehicle)
			local size = sizeOf(vehicle, spec)
			local nose = vehicle:LocalToWorld(Vector(spec.noseX, spec.noseY, spec.noseZ)) - position
			local clear = clearShare(position, toPosition, nose, vehicle:GetUp(), size.halfLength, size.halfWidth)
			if clear < 1 then toPosition = position + travel * clear end
			local toAngles = Angle(angles.p, angles.y + turn * clear, angles.r)
			if i <= GROUND_CARS then
				motion.ground = motion.ground or {}
				toPosition, toAngles = followGround(spec, position, angles, toPosition, toAngles, motion.ground, frameTime)
			end
			displace(vehicle, toPosition, toAngles, frame, realNow)
		end
	end
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

	-- the other cars first: your car stops at them as they're drawn (carStop)
	if othersShare > 0 and own.lead then
		local player = LocalPlayer()
		updateOthers(vehicle, own.lead, frame, realNow, IsValid(player) and player:EyePos() or vector_origin, frameTime)
	end

	if running then
		local spec, learner, deltaTime = own.spec, own.learner, engine.TickInterval()
		local count, fraction, matched, fractionButtons = commandsAfter(base, own.commands)
		local stats = own.stats
		if matched then stats.matched = stats.matched + 1 else stats.fallback = stats.fallback + 1 end
		local predicted = Handling.Predict(base, own.commands, count, fraction, spec, learner, deltaTime, own.predicted, own.state, fractionButtons)
		own.count, own.fraction = count, fraction

		if own.fresh then
			own.fresh = false
			if own.shown and own.previousBase then
				-- where the earlier state put the car for this same moment: the difference is the correction
				local earlierCount, earlierFraction, _, earlierButtons = commandsAfter(own.previousBase, own.earlierCommands)
				local earlier = Handling.Predict(own.previousBase, own.earlierCommands, earlierCount, earlierFraction, spec, learner, deltaTime, own.earlier, own.earlierState, earlierButtons)
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
		-- not through other cars either (as they're drawn: moved over the lead, or parked)
		local stoppedByCar
		toPosition, displayAngles, stoppedByCar = carStop(vehicle, spec, basePosition, Handling.AnglesOf(base), toPosition, displayAngles, realNow)
		if stoppedByCar then stats.carStops = (stats.carStops or 0) + 1 end
		-- on the road under it (over crests, into dips)
		if base.groundShare >= 1 then
			own.ground = own.ground or {}
			toPosition, displayAngles = followGround(spec, vehicle:GetPos(), vehicle:GetAngles(), toPosition, displayAngles, own.ground, frameTime)
		else
			own.ground = nil
		end
		-- (audio_engine_predict_amount: part of the way from where Source shows the car)
		local amount = amountConVar:GetFloat()
		if amount < 1 then
			toPosition = LerpVector(amount, vehicle:GetPos(), toPosition)
			displayAngles = LerpAngle(amount, vehicle:GetAngles(), displayAngles)
		end
		own.displayPosition, own.displayAngles = toPosition, displayAngles
		-- (the wheels: the predicted steering x how far Source turns them at this speed, turning at
		-- WHEEL_RATE)
		own.sourceSteerPose = sourceSteerPose(vehicle)
		local wheelSpeed = math.abs(Handling.ForwardSpeed(base, spec)) * Handling.INCH
		learnWheelShare(vehicle, base, wheelSpeed, realNow)
		local wheelTarget = -(own.state.steer or 0) * wheelShareAt(vehicle, spec, math.abs(Handling.ForwardSpeed(predicted, spec)) * Handling.INCH)
		local wheelFrom = own.steerPose or own.sourceSteerPose or wheelTarget
		own.steerPose = math.Approach(wheelFrom, wheelTarget, WHEEL_RATE * frameTime)
		-- (for the readout: Source's pose now, before anything is drawn moved)
		own.sourcePosition, own.sourceYaw = vehicle:GetPos(), vehicle:GetAngles().y
		-- (how late Source draws your car, against the other cars': drawnLag)
		own.lagRecord = own.lagRecord or {}
		own.drawnLag = drawnLag(vehicle, Vector(base.vx, base.vy, base.vz), own.lagRecord, frameTime)
		own.velocity = own.velocity or Vector()
		own.velocity:SetUnpacked(predicted.vx, predicted.vy, predicted.vz)
		own.velocityAt = realNow
		displace(vehicle, toPosition, own.displayAngles, frame, realNow)
		if record then recordFrame(realNow, predicted, display, vehicle, own.count > 0 and own.commands[own.count] or base.buttons) end
		updateLead(vehicle, base.time + (count + fraction) * deltaTime, realNow, frameTime)
	else
		own.shown = false
		-- (the drawn wheels start again from Source's next time)
		own.steerPose = nil
		if not vehicle then own.vehicle = nil end
	end

	clearStale(frame)
end

---------------------------------------------------------------------------
-- the camera moves with your car as drawn. hook.Call is wrapped for CalcView only, so whatever
-- camera the gamemode or another addon makes (first person, third person) is moved after it
---------------------------------------------------------------------------
local ourCalls = setmetatable({}, { __mode = "k" })
local cameraFrame = -1

local function calcView(originalCall, gamemodeTable, player, origin, angles, fov, nearZ, farZ, ...)
	updateFrame()
	local view = withOwnBounds(own.vehicle, originalCall, "CalcView", gamemodeTable, player, origin, angles, fov, nearZ, farZ, ...)
	local entry = own.vehicle and displaced[own.vehicle]
	if not entry then return view end
	-- a copy: some cameras hand back the same table each frame
	local moved = {}
	if type(view) == "table" then for key, value in pairs(view) do moved[key] = value end end
	moved.fov, moved.znear, moved.zfar = moved.fov or fov, moved.znear or nearZ, moved.zfar or farZ
	moved.origin, moved.angles = mapPose(entry, moved.origin or origin, moved.angles or angles)
	own.cameraShift = moved.origin:Distance((type(view) == "table" and view.origin) or origin)
	cameraFrame = FrameNumber()
	return moved
end

local function wrapHookCall()
	if ourCalls[hook.Call] then return end
	local originalCall = hook.Call
	local function call(name, gamemodeTable, ...)
		if name ~= "CalcView" then return originalCall(name, gamemodeTable, ...) end
		return calcView(originalCall, gamemodeTable, ...)
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
	elseif own.vehicle and displaced[own.vehicle] and cameraFrame ~= frame then
		own.stats.cameraMissed = (own.stats.cameraMissed or 0) + 1
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

hook.Add("EntityRemoved", "audio_engine_predict", function(entity)
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

-- the same on screen, per second (audio_engine_predict_debug 1): a screenshot from the real server
-- says what the prediction does there (offline tests passed while it felt bad in game)
local live = { at = 0, lines = {} }
local function liveLine(format, ...) live.lines[#live.lines + 1] = string.format(format, ...) end
local function updateLive(realNow)
	local stats, last = own.stats, live.last
	local seconds = realNow - live.at
	if last and seconds < 1 then return end
	local snapshot = { states = stats.states, matched = stats.matched, fallback = stats.fallback, corrections = stats.corrections,
		correctionSum = stats.correctionSum, clamped = stats.clamped, cameraMissed = stats.cameraMissed or 0 }
	live.last, live.at = snapshot, realNow
	-- (the console command starts the counts again)
	if not last or snapshot.states < last.states or snapshot.matched < last.matched or snapshot.fallback < last.fallback then return end
	local function per(key) return (snapshot[key] - last[key]) / seconds end
	table.Empty(live.lines)
	local vehicle = own.vehicle
	local frames = per("matched") + per("fallback")
	liveLine("prediction %s | states from server %.0f/s (want ~33)", predictionAllowed() and "ON" or "OFF", per("states"))
	liveLine("frames matched %.0f%%, fallback %.0f%% | replaying %d commands + %.2f",
		frames > 0 and per("matched") / frames * 100 or 0, frames > 0 and per("fallback") / frames * 100 or 0, own.count or 0, own.fraction or 0)
	liveLine("lead %.0f ms | ping %d + interp %.0f = %.0f ms | server tick %.0f",
		(own.lead or 0) * 1000, LocalPlayer():Ping(), interpolationDelay() * 1000, LocalPlayer():Ping() + interpolationDelay() * 1000, 1 / engine.TickInterval())
	-- (other cars: how much later than yours Source draws them, added to their lead)
	local extras = {}
	for i = 1, math.min(#nearby, 4) do
		local motion = motions[nearby[i].vehicle]
		if motion and motion.extraLead then extras[#extras + 1] = string.format("%+.0f", motion.extraLead * 1000) end
	end
	liveLine("your car drawn %s ms behind its newest position | nearest cars drawn later than yours by %s ms",
		own.drawnLag and string.format("%.0f", own.drawnLag * 1000) or "?", #extras > 0 and table.concat(extras, " ") or "-")
	if own.learner and own.learner.yawShares then
		local shares = {}
		for band, share in ipairs(own.learner.yawShares) do shares[band] = string.format("%.2f", share) end
		liveLine("turn the server's car really makes, per 22 mph band: %s (%d samples)", table.concat(shares, " "), own.learner.yawSamples or 0)
	end
	local corrections = snapshot.corrections - last.corrections
	liveLine("corrections %.0f/s, mean %.1f in | wall stops %.0f%% of frames | camera not moved %.0f%% of frames",
		corrections / seconds, corrections > 0 and (snapshot.correctionSum - last.correctionSum) / corrections or 0,
		frames > 0 and per("clamped") / frames * 100 or 0, frames > 0 and per("cameraMissed") / frames * 100 or 0)
	if IsValid(vehicle) and own.displayPosition and own.sourcePosition and own.base then
		local speed = math.sqrt(own.base.vx * own.base.vx + own.base.vy * own.base.vy)
		local ahead = (own.displayPosition - own.sourcePosition):Length()
		liveLine("drawn %.1f m ahead of Source's car (speed x lead = %.1f m) | turned %.1f deg from it | camera moved %.1f m",
			ahead * 0.01905, speed * (own.lead or 0) * 0.01905, math.abs(math.NormalizeAngle(own.displayAngles.y - own.sourceYaw)),
			(own.cameraShift or 0) * 0.01905)
	end
end

hook.Add("HUDPaint", "audio_engine_predict_debug", function()
	if not debugConVar:GetBool() then return end
	updateLive(RealTime())
	local y = ScrH() * 0.3
	for _, line in ipairs(live.lines) do
		draw.SimpleTextOutlined(line, "DermaDefaultBold", 20, y, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, 1, color_black)
		y = y + 16
	end
	if #live.lines == 0 then draw.SimpleTextOutlined("prediction: waiting for a second of driving", "DermaDefaultBold", 20, y, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, 1, color_black) end
end)

concommand.Add("audio_engine_predict_stats", function()
	local stats = own.stats
	local learner = own.learner
	print(string.format("[Audio Engine] prediction %s, car %s | states %d | frames matched %d, fallback %d | replaying %d commands + %.2f",
		predictionAllowed() and "on" or "off", IsValid(own.vehicle) and tostring(AudioEngine.GetCarConfig(own.vehicle) and AudioEngine.GetCarConfig(own.vehicle).name) or "-",
		stats.states, stats.matched, stats.fallback, own.count or 0, own.fraction or 0))
	print(string.format("  corrections %d, mean %.1f in, largest %.1f in | wall stops %d, car stops %d | lead %.0f ms (ping %d, interp %.0f ms) | others %s | learned samples %d",
		stats.corrections, stats.corrections > 0 and stats.correctionSum / stats.corrections or 0, stats.largest, stats.clamped, stats.carStops or 0,
		(own.lead or 0) * 1000, LocalPlayer():Ping(), interpolationDelay() * 1000, othersConVar:GetBool() and "on" or "off", learner and learner.samples or 0))
	own.stats = { states = 0, matched = 0, fallback = 0, corrections = 0, correctionSum = 0, largest = 0, clamped = 0 }
end, nil, "Print how the driving prediction is doing (and start counting again)")
