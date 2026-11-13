--[[
	Emergency lights (sh_police.lua, sv_police.lua): the flashing. The bar's LEDs and the built-in
	lamps' lenses are plain textures, so a lit module gets a glowing lens quad and a glow sprite that
	fades as it turns away from the viewer; the nearest cars also light their surroundings (one
	dynamic light per side). The light key (audio_engine_lightkey, default left shift) steps the
	driver's lights off -> CODE 2 -> CODE 3 -> off.

	Patterns (each car offset in time, so a row of cars doesn't flash in step):
	  CODE 2: slow wig-wag, the driver's outer modules and corners with the passenger's inner ones,
	          then the other way round
	  CODE 3: the same split as quad flashes, twice as fast, plus double flashes in the middle

	Colours by the car's scheme (NW2 audio_lightscheme): on the bar per side, built-in lamps keep
	their lens's own colour. A car whose audio_lightbar is itself has built-in lamps
	(AudioEngine.BUILTIN_LIGHTS), placed by its body bone.
]]
local AudioEngine = AUDIO_ENGINE

local lightKeyConVar = CreateClientConVar("audio_engine_lightkey", "lshift", true, false,
	"Key that switches the emergency lights of the car you drive (a key name such as lshift, l or f2; none = off)")

local CODE2 = { period = 1.2, onTime = 0.4 }
local CODE3 = { period = 0.5, flashPeriod = 0.0625, flashOnTime = 0.04, centreFlashTime = 0.035 }
local LIST_REFRESH = 0.5
local DRAW_DIST = 6000
local DLIGHT_DIST = 2500
local MAX_DLIGHT_CARS = 4
local DLIGHT_BASE = 0x40000
local LENS_HEIGHT = 1.7
local GLOW_SIZE = 18
local GLOW_PER_UNIT = 0.012
local GLOW_MAX = 90
local GLOW_OUT = 2
local PHASE_PER_INDEX = 0.37
local DLIGHT = { brightness = 2, decay = 4000, size = 300, life = 0.05 }
local SIDE_LIGHT_OFFSETS = { [-1] = Vector(0, -20, 14), [1] = Vector(0, 20, 14) }

local GLOW_MATERIAL = Material("sprites/light_glow02_add")
local LENS_MATERIAL = CreateMaterial("audio_engine_lightbar_lens", "UnlitGeneric", {
	["$basetexture"] = "color/white",
	["$additive"] = "1",
	["$vertexcolor"] = "1",
	["$vertexalpha"] = "1",
})
local COLORS = {
	red = Color(255, 25, 15),
	white = Color(255, 255, 255),
	blue = Color(25, 70, 255),
	yellow = Color(255, 170, 10),
}
-- the bar's colour per side (-1 driver's, 0 centre, 1 passenger's) by scheme
local SCHEME_SIDES = {
	police = { [-1] = COLORS.red, [0] = COLORS.white, [1] = COLORS.blue },
	fire = { [-1] = COLORS.red, [0] = COLORS.yellow, [1] = COLORS.yellow },
	medical = { [-1] = COLORS.red, [0] = COLORS.white, [1] = COLORS.white },
}
local glowColor = Color(255, 255, 255)

-- which half of the wig-wag a module flashes in: -1 or 1 (the centre modules have their own timing)
local function wigWagHalf(lamp)
	if lamp.group == "i" then return -lamp.side end

	return lamp.side
end

local function isLit(lamp, mode, phaseTime)
	if mode == 1 then
		local phase = phaseTime % CODE2.period
		local litHalf = phase < CODE2.period / 2 and -1 or 1
		if lamp.side == 0 or wigWagHalf(lamp) ~= litHalf then return false end

		return phase % (CODE2.period / 2) < CODE2.onTime
	end
	local phase = phaseTime % CODE3.period
	local timeInHalf = phase % (CODE3.period / 2)
	if lamp.side == 0 then
		return timeInHalf < CODE3.centreFlashTime or (timeInHalf > 2 * CODE3.centreFlashTime and timeInHalf < 3 * CODE3.centreFlashTime)
	end
	local litHalf = phase < CODE3.period / 2 and -1 or 1
	if wigWagHalf(lamp) ~= litHalf then return false end

	return timeInHalf % CODE3.flashPeriod < CODE3.flashOnTime
end

-- cars with lights near enough to matter, refreshed now and then rather than searched every frame
local emergencyCars = {}
local nextRefresh = 0

local function refreshList()
	emergencyCars = {}
	for _, vehicle in ipairs(ents.FindByClass("prop_vehicle_jeep")) do
		local lightbar = vehicle:GetNW2Entity("audio_lightbar")
		if IsValid(lightbar) then
			local entry = { vehicle = vehicle, lightbar = lightbar, sides = SCHEME_SIDES[vehicle:GetNW2String("audio_lightscheme", "police")] or SCHEME_SIDES.police }
			if lightbar == vehicle then
				local builtinSet = AudioEngine.BUILTIN_LIGHTS[string.lower(vehicle:GetModel() or "")]
				local bone = builtinSet and vehicle:LookupBone(builtinSet.bone)
				if bone then
					entry.lamps, entry.bone = builtinSet.lamps, bone
					table.insert(emergencyCars, entry)
				end
			else
				table.insert(emergencyCars, entry)
			end
		end
	end
end

local function lightModeOf(entry)
	local vehicle, lightbar = entry.vehicle, entry.lightbar
	if not IsValid(vehicle) or not IsValid(lightbar) or lightbar:IsDormant() then return 0 end

	return vehicle:GetNW2Int("audio_lights", 0)
end

local function drawLens(worldPosition, worldNormal, width, height, color, eyePosition)
	render.SetMaterial(LENS_MATERIAL)
	render.DrawQuadEasy(worldPosition, worldNormal, width, height, color, 0)
	local toEye = eyePosition - worldPosition
	local distance = toEye:Length()
	local facing = worldNormal:Dot(toEye) / math.max(distance, 1)
	if facing <= 0 then return end
	local size = math.min(GLOW_SIZE + distance * GLOW_PER_UNIT, GLOW_MAX) * (0.35 + 0.65 * facing)
	glowColor.r, glowColor.g, glowColor.b, glowColor.a = color.r, color.g, color.b, 255 * facing
	render.SetMaterial(GLOW_MATERIAL)
	render.DrawSprite(worldPosition + worldNormal * GLOW_OUT, size, size, glowColor)
end

-- a direction in a frame given by its forward / right / up (right = -y, as Entity:GetRight)
local function turned(forward, right, up, direction)
	return forward * direction.x - right * direction.y + up * direction.z
end

local function drawBar(entry, mode, phaseTime, eyePosition)
	local lightbar = entry.lightbar
	local angles = lightbar:GetAngles()
	local forward, right, up = angles:Forward(), angles:Right(), angles:Up()
	for _, lamp in ipairs(AudioEngine.LIGHTBAR_MODULES) do
		if isLit(lamp, mode, phaseTime) then
			drawLens(lightbar:LocalToWorld(lamp.position), turned(forward, right, up, lamp.normal), lamp.width, LENS_HEIGHT, entry.sides[lamp.side], eyePosition)
		end
	end
end

-- built-in lamps follow the body bone (nil while the car hasn't set up its bones: not drawn)
local function drawBuiltin(entry, mode, phaseTime, eyePosition)
	local boneMatrix = entry.vehicle:GetBoneMatrix(entry.bone)
	if not boneMatrix then return end
	local forward, right, up = boneMatrix:GetForward(), boneMatrix:GetRight(), boneMatrix:GetUp()
	for _, lamp in ipairs(entry.lamps) do
		if isLit(lamp, mode, phaseTime) then
			drawLens(boneMatrix * lamp.position, turned(forward, right, up, lamp.normal), lamp.width, lamp.height, COLORS[lamp.color] or COLORS.white, eyePosition)
		end
	end
end

hook.Add("PostDrawTranslucentRenderables", "audio_engine_police", function(drawingDepth, drawingSkybox)
	if drawingDepth or drawingSkybox then return end
	local eyePosition = EyePos()
	local now = CurTime()
	for _, entry in ipairs(emergencyCars) do
		local mode = lightModeOf(entry)
		if mode > 0 and entry.lightbar:GetPos():DistToSqr(eyePosition) < DRAW_DIST * DRAW_DIST then
			local phaseTime = now + entry.vehicle:EntIndex() * PHASE_PER_INDEX
			if entry.lamps then drawBuiltin(entry, mode, phaseTime, eyePosition) else drawBar(entry, mode, phaseTime, eyePosition) end
		end
	end
end)

-- the colour a side lights its surroundings with right now, or nil
local function sideColor(entry, side, mode, phaseTime)
	if entry.lamps then
		for _, lamp in ipairs(entry.lamps) do
			if lamp.side == side and lamp.group == "o" and isLit(lamp, mode, phaseTime) then return COLORS[lamp.color] or COLORS.white end
		end

		return nil
	end
	for _, lamp in ipairs(AudioEngine.LIGHTBAR_MODULES) do
		if lamp.side == side and lamp.group == "o" and isLit(lamp, mode, phaseTime) then return entry.sides[side] end
	end

	return nil
end

-- where a side's light comes from: beside the bar, or the middle of that side's built-in lamps
local function sideLightPosition(entry, side)
	if not entry.lamps then return entry.lightbar:LocalToWorld(SIDE_LIGHT_OFFSETS[side]) end
	entry.sidePositions = entry.sidePositions or {}
	local localPosition = entry.sidePositions[side]
	if not localPosition then
		local lampCount = 0
		localPosition = Vector(0, 0, 0)
		for _, lamp in ipairs(entry.lamps) do
			if lamp.side == side then localPosition, lampCount = localPosition + lamp.position, lampCount + 1 end
		end
		localPosition = lampCount > 0 and localPosition / lampCount or localPosition
		entry.sidePositions[side] = localPosition
	end
	local boneMatrix = entry.vehicle:GetBoneMatrix(entry.bone)

	return boneMatrix and boneMatrix * localPosition
end

local function lightSurroundings(entry, mode, phaseTime)
	local vehicle = entry.vehicle
	for side in pairs(SIDE_LIGHT_OFFSETS) do
		local color = sideColor(entry, side, mode, phaseTime)
		local position = color and sideLightPosition(entry, side)
		if position then
			local dynamicLight = DynamicLight(DLIGHT_BASE + vehicle:EntIndex() * 2 + (side + 1) / 2)
			if dynamicLight then
				dynamicLight.pos = position
				dynamicLight.r, dynamicLight.g, dynamicLight.b = color.r, color.g, color.b
				dynamicLight.brightness = DLIGHT.brightness
				dynamicLight.decay = DLIGHT.decay
				dynamicLight.size = DLIGHT.size
				dynamicLight.dietime = CurTime() + DLIGHT.life
			end
		end
	end
end

local litCarsByDistance = {}
hook.Add("Think", "audio_engine_police", function()
	local now = CurTime()
	if now >= nextRefresh then
		nextRefresh = now + LIST_REFRESH
		refreshList()
	end
	if #emergencyCars == 0 then return end
	local eyePosition = EyePos()
	table.Empty(litCarsByDistance)
	for _, entry in ipairs(emergencyCars) do
		if lightModeOf(entry) > 0 then
			entry.distanceSqr = entry.lightbar:GetPos():DistToSqr(eyePosition)
			if entry.distanceSqr < DLIGHT_DIST * DLIGHT_DIST then table.insert(litCarsByDistance, entry) end
		end
	end
	table.sort(litCarsByDistance, function(first, second) return first.distanceSqr < second.distanceSqr end)
	for i = 1, math.min(#litCarsByDistance, MAX_DLIGHT_CARS) do
		local entry = litCarsByDistance[i]
		lightSurroundings(entry, lightModeOf(entry), now + entry.vehicle:EntIndex() * PHASE_PER_INDEX)
	end
end)

-- the light key, sent as a console command like the start key (cl_engine.lua)
local lightKeyHeld = false
hook.Add("Think", "audio_engine_lightkey", function()
	local keyCode = _G["KEY_" .. string.upper(lightKeyConVar:GetString())]
	local isDown = keyCode ~= nil and input.IsKeyDown(keyCode)
	local pressed = isDown and not lightKeyHeld
	lightKeyHeld = isDown
	if not pressed then return end
	local player = LocalPlayer()
	local vehicle = IsValid(player) and player:GetVehicle()
	if not IsValid(vehicle) or not IsValid(vehicle:GetNW2Entity("audio_lightbar")) or player:IsTyping() then return end
	if gui.IsGameUIVisible() or IsValid(vgui.GetKeyboardFocus()) then return end
	RunConsoleCommand("audio_engine_lights")
end)
