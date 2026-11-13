--[[
	Passenger seats for the registered cars (AudioEngine.CAR_SEATS in sh_carlist.lua). The content
	packs define none, so they're laid out from the car's own driver attachment: the front passenger
	mirrors the driver across the centre line, the back row sits behind them.
	Use (E) on a car enters the free seat nearest to where you stand: at the driver's door that's the
	driver's seat (Source's own entering, untouched), at any other door, or with a driver in, a
	passenger seat. A seat is an invisible prisoner pod parented to the car, made only while someone
	sits in it (40 cars x 4 standing pods would be 160 networked entities for nothing). Getting out
	puts the passenger beside their door (else the other side, behind the car, on the roof).
]]
local AudioEngine = AUDIO_ENGINE

local seatsConVar = CreateConVar("audio_engine_seats", "1", FCVAR_ARCHIVE,
	"1 = passengers can get into the registered cars (E at a passenger door, or with a driver in)")

AudioEngine.SEAT_REAR_PITCH = 0.3   -- back row: this x wheelbase behind the front seats (0.25-0.36 in the meshes)
AudioEngine.SEAT_REAR_RISE = 4      -- ...and this many units higher

local SEAT_MODEL = "models/nova/airboat_seat.mdl"
local SEAT_SCRIPT = "scripts/vehicles/prisoner_pod.txt"
local SEAT_ATTACHMENT = "vehicle_feet_passenger0"   -- where the sitting player's hips go, on the car and the pod
local DEFAULT_SEATS = 4
local FRONT_PASSENGER = { -1, 0, 0 }
local USE_COOLDOWN = 0.75   -- s: holding E would otherwise get straight back in after getting out
local EXIT_GAP = 22         -- units between the car's side and the player's centre on getting out
local EXIT_DROP = 128       -- units searched below an exit point for the ground
local INCHES_PER_METRE = 1 / 0.0254
local UP = Vector(0, 0, 1)

local layoutCache = {}
local podAttachmentOffset

local function seatList(config)
	local seats = config.seats or DEFAULT_SEATS
	if istable(seats) then return seats end
	if seats <= 1 then return {} end
	if seats == 2 then return { FRONT_PASSENGER } end

	return { FRONT_PASSENGER, { 1 }, { -1 } }
end

-- the seats' hip positions in the car's space, per model: { position, side }
local function layout(vehicle, config)
	local model = vehicle:GetModel()
	if layoutCache[model] then return layoutCache[model] end
	local attachmentId = vehicle:LookupAttachment(SEAT_ATTACHMENT)
	local attachment = attachmentId and attachmentId > 0 and vehicle:GetAttachment(attachmentId)
	if not attachment then
		layoutCache[model] = {}
		return layoutCache[model]
	end
	local driverPosition = vehicle:WorldToLocal(attachment.Pos)
	local geometry = AudioEngine.CarGeometry(vehicle)
	local forward = geometry.forward
	local right = forward:Cross(UP)
	local driverLateral = driverPosition:Dot(right)
	local driverSign = driverLateral >= 0 and 1 or -1
	local rearPitch = geometry.wheelbase * INCHES_PER_METRE * AudioEngine.SEAT_REAR_PITCH
	local seats = { driver = driverPosition, forward = forward, right = right }
	for _, seat in ipairs(seatList(config)) do
		local side, back, up, width = seat[1], seat[2], seat[3], seat[4]
		local lateral = side * driverSign * (width or math.abs(driverLateral))
		local position = driverPosition + right * (lateral - driverLateral)
			- forward * (back or rearPitch) + UP * (up or (back and 0 or AudioEngine.SEAT_REAR_RISE))
		seats[#seats + 1] = { position = position, side = lateral >= 0 and 1 or -1 }
	end
	layoutCache[model] = seats

	return seats
end

local function seatTaken(vehicle, index)
	local pod = vehicle.audioSeats and vehicle.audioSeats[index]

	return IsValid(pod) and IsValid(pod:GetDriver())
end

-- index of the free seat nearest the player (0 = the driver's), nil when all are taken
local function nearestFreeSeat(vehicle, seats, player)
	local standing = vehicle:WorldToLocal(player:GetPos())
	standing.z = 0
	local function distance(position) return standing:DistToSqr(Vector(position.x, position.y, 0)) end
	local bestIndex, bestDistance
	if not IsValid(vehicle:GetDriver()) then bestIndex, bestDistance = 0, distance(seats.driver) end
	for index, seat in ipairs(seats) do
		local seatDistance = distance(seat.position)
		if not seatTaken(vehicle, index) and (not bestDistance or seatDistance < bestDistance) then
			bestIndex, bestDistance = index, seatDistance
		end
	end

	return bestIndex
end

local function isLocked(vehicle)
	return vehicle:GetInternalVariable("VehicleLocked") == true or vehicle:GetInternalVariable("m_bLocked") == true
end

-- the pod's own hip attachment, in its space (same for every pod)
local function podOffset(pod)
	if podAttachmentOffset then return podAttachmentOffset end
	local attachmentId = pod:LookupAttachment(SEAT_ATTACHMENT)
	local attachment = attachmentId and attachmentId > 0 and pod:GetAttachment(attachmentId)
	podAttachmentOffset = attachment and pod:WorldToLocal(attachment.Pos) or Vector(0, 0, 0)

	return podAttachmentOffset
end

local function createPod(vehicle, seats, index)
	local pod = ents.Create("prop_vehicle_prisoner_pod")
	if not IsValid(pod) then return end
	local hips = vehicle:LocalToWorld(seats[index].position)
	pod:SetModel(SEAT_MODEL)
	pod:SetKeyValue("vehiclescript", SEAT_SCRIPT)
	pod:SetKeyValue("limitview", "0")
	pod:SetPos(hips)
	pod:SetAngles(vehicle:LocalToWorldAngles(Angle(0, seats.forward:Angle().y - 90, 0)))
	pod:Spawn()
	pod:Activate()
	pod:SetPos(hips - (pod:LocalToWorld(podOffset(pod)) - pod:GetPos()))
	pod:SetParent(vehicle)
	pod:SetNoDraw(true)
	pod:SetNotSolid(true)
	pod:DrawShadow(false)
	pod.audioSeatCar = vehicle
	pod.audioSeatIndex = index
	vehicle:DeleteOnRemove(pod)
	vehicle.audioSeats = vehicle.audioSeats or {}
	vehicle.audioSeats[index] = pod

	return pod
end

local function enterSeat(player, vehicle, seats, index)
	local pod = vehicle.audioSeats and vehicle.audioSeats[index]
	if not IsValid(pod) then pod = createPod(vehicle, seats, index) end
	if not pod then return end
	player:EnterVehicle(pod)
	-- turned away (CanPlayerEnterVehicle): no empty pod left behind
	if player:GetVehicle() ~= pod then pod:Remove() end
end

hook.Add("PlayerUse", "audio_engine_seats", function(player, entity)
	if not seatsConVar:GetBool() or entity:GetClass() ~= "prop_vehicle_jeep" then return end
	if (player.audioSeatUseAt or 0) > CurTime() then return end
	local config = AudioEngine.GetCarConfig(entity)
	if not config then return end
	local seats = layout(entity, config)
	if #seats == 0 then return end
	local index = nearestFreeSeat(entity, seats, player)
	if not index or index == 0 or isLocked(entity) then return end
	player.audioSeatUseAt = CurTime() + USE_COOLDOWN
	enterSeat(player, entity, seats, index)

	return false
end)

local function hullClear(player, vehicle, position)
	local mins, maxs = player:GetHull()
	local trace = util.TraceHull({
		start = position,
		endpos = position,
		mins = mins,
		maxs = maxs,
		filter = { vehicle, player },
		mask = MASK_PLAYERSOLID,
	})

	return not trace.Hit
end

local function groundBelow(player, vehicle, position)
	local mins, maxs = player:GetHull()
	local trace = util.TraceHull({
		start = position,
		endpos = position - UP * EXIT_DROP,
		mins = mins,
		maxs = maxs,
		filter = { vehicle, player },
		mask = MASK_PLAYERSOLID,
	})

	return trace.HitPos
end

-- the car's reach from its origin along a direction of its space (its box's furthest corner)
local function extent(vehicle, direction)
	local mins, maxs = vehicle:OBBMins(), vehicle:OBBMaxs()

	return math.max(math.abs(mins:Dot(direction)), math.abs(maxs:Dot(direction)))
end

local function exitPoints(vehicle, seats, seat)
	local forward, right = seats.forward, seats.right
	local position = seat.position
	local lateral = position:Dot(right)
	local besideDistance = extent(vehicle, right) + EXIT_GAP
	local behind = position:Dot(forward) + extent(vehicle, forward) + EXIT_GAP
	local roofHeight = vehicle:OBBMaxs().z + 2

	return {
		position + right * (seat.side * besideDistance - lateral),
		position + right * (-seat.side * besideDistance - lateral),
		position - forward * behind - right * lateral,
		Vector(position.x, position.y, roofHeight),
	}
end

local function placeBeside(player, vehicle, seatIndex)
	local config = AudioEngine.GetCarConfig(vehicle)
	local seats = config and layout(vehicle, config)
	local seat = seats and seats[seatIndex]
	if not seat then return end
	for _, localPosition in ipairs(exitPoints(vehicle, seats, seat)) do
		local position = vehicle:LocalToWorld(localPosition)
		if hullClear(player, vehicle, position) then
			player:SetPos(groundBelow(player, vehicle, position))
			return
		end
	end
end

hook.Add("PlayerLeaveVehicle", "audio_engine_seats", function(player, pod)
	local vehicle = pod.audioSeatCar
	if not vehicle then return end
	player.audioSeatUseAt = CurTime() + USE_COOLDOWN
	local seatIndex = pod.audioSeatIndex
	-- after Source has put the player at the pod's own exit (inside the car, or nowhere)
	timer.Simple(0, function()
		if IsValid(player) and IsValid(vehicle) and not player:InVehicle() then
			placeBeside(player, vehicle, seatIndex)
		end
		if IsValid(pod) and not IsValid(pod:GetDriver()) then pod:Remove() end
	end)
end)

hook.Add("PlayerDisconnected", "audio_engine_seats", function(player)
	local pod = player:GetVehicle()
	if IsValid(pod) and pod.audioSeatCar then SafeRemoveEntityDelayed(pod, 0) end
end)
