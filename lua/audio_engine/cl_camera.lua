--[[
	Audio Engine - third-person car camera (client)

	It orbits the middle of the car (CAMERA_RISE of its height up) at a fixed distance,
	CAMERA_DISTANCE x the car's render bounds diagonal (the user: 0.7, 1.7 was too far). There's
	no mouse-wheel zoom: the wheel sets the speed limiter (sv_cruise). Pulled in at once by a wall
	behind it, back out over CAMERA_REACH_RETURN (the base camera jumped in and out against walls
	in a crash). Only for registered cars in their third-person view; first person and other
	vehicles are left to the gamemode.
]]
local AudioEngine = AUDIO_ENGINE

local CAMERA_DISTANCE = 0.7         -- x the car's render bounds diagonal
local CAMERA_RISE = 0.35            -- the orbit's centre: this share of the car's height over its middle
local CAMERA_WALL_GAP = 4           -- inches kept off a wall behind the camera
local CAMERA_REACH_RETURN = 0.25    -- s: back out after a wall let go

local cameraHull = Vector(CAMERA_WALL_GAP, CAMERA_WALL_GAP, CAMERA_WALL_GAP)
local cameraResult = {}

-- walls and props stop the camera, not cars or players
local function notCar(entity)
	if entity:IsVehicle() or entity:IsPlayer() then return false end
	local parent = entity:GetParent()
	return not (IsValid(parent) and parent:IsVehicle())
end
local cameraTrace = { mins = -cameraHull, maxs = cameraHull, mask = MASK_SOLID, filter = notCar, output = cameraResult }
local cameraReach = { vehicle = nil, share = 1, at = 0 }

local function rootOf(entity)
	local parent = entity:GetParent()
	while IsValid(parent) do entity, parent = parent, parent:GetParent() end
	return entity
end

hook.Add("CalcView", "audio_engine_camera", function(player, _, angles, fov, nearZ, farZ)
	if not IsValid(player) or player:GetViewEntity() ~= player then return end
	local seat = player:GetVehicle()
	if not IsValid(seat) or not seat.GetThirdPersonMode or not seat:GetThirdPersonMode() then return end
	local car = rootOf(seat)
	if car:GetClass() ~= "prop_vehicle_jeep" or not AudioEngine.GetCarConfig(car) then return end
	local mins, maxs = car:GetRenderBounds()
	local radius = (maxs - mins):Length() * CAMERA_DISTANCE
	local centre = car:OBBCenter()
	centre.z = centre.z + (car:OBBMaxs().z - car:OBBMins().z) * CAMERA_RISE
	local pivot = car:LocalToWorld(centre)
	cameraTrace.start, cameraTrace.endpos = pivot, pivot - angles:Forward() * radius
	util.TraceHull(cameraTrace)
	local share = cameraResult.StartSolid and 0 or (cameraResult.Fraction or 1)
	local now = RealTime()
	if cameraReach.vehicle ~= car then cameraReach.vehicle, cameraReach.share = car, share end
	local deltaTime = math.Clamp(now - cameraReach.at, 0, 0.1)
	cameraReach.at = now
	if share < cameraReach.share then
		cameraReach.share = share
	else
		cameraReach.share = cameraReach.share + (share - cameraReach.share) * (1 - math.exp(-deltaTime / CAMERA_REACH_RETURN))
	end
	return { origin = pivot - angles:Forward() * (radius * cameraReach.share), angles = angles, fov = fov, znear = nearZ, zfar = farZ, drawviewer = true }
end)
