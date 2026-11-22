--[[
	Emergency lights (sh_police.lua, sv_police.lua): the flashing. The light key
	(audio_engine_lightkey, default left shift) steps the driver's lights off -> CODE 2 -> CODE 3 -> off.

	Patterns (each car offset in time, so a row of cars doesn't flash in step):
	  CODE 2: slow wig-wag, the driver's outer modules and corners with the passenger's inner ones,
	          then the other way round
	  CODE 3: the same split as quad flashes, twice as fast, plus double flashes in the middle

	Colours by the car's scheme (NW2 audio_lightscheme): police red / white / blue, fire red / yellow,
	medical red / white, per side of the bar; built-in lamps keep their lens's own colour.

	How a lit module shows:
	  - the LED bar (AudioEngine.LIGHTBAR_LED_MODEL, addons/police_lightbar): its lenses light
	    themselves. Each lens's material has 5 frames (0 unlit, 1 red, 2 white, 3 blue, 4 yellow,
	    police_lightbar/leds_large / leds_small) and the AudioLightbarLens material proxy below picks
	    the frame as the bar is drawn, from its car's pattern and scheme. Nothing is drawn over it.
	  - PERP's original bar (the addon not installed) and the built-in lamps (AudioEngine.BUILTIN_LIGHTS,
	    a car whose audio_lightbar is itself, placed by its body bone): their lenses are plain
	    textures, so a lit one gets a drawn glowing quad.
	  - the glow: one dynamic light per car (the nearest MAX_DLIGHT_CARS), in the colour flashing at
	    that moment. It replaced a glow sprite on every lit lens and a dynamic light per side: many
	    light sources for one bar.
]]
local AudioEngine = AUDIO_ENGINE

local lightKeyConVar = CreateClientConVar("audio_engine_lightkey", "lshift", true, false,
	"Key that switches the emergency lights of the car you drive (a key name such as lshift, l or f2; none = off)")

local CODE2 = { period = 1.2, onTime = 0.4 }
local CODE3 = { period = 0.5, flashPeriod = 0.0625, flashOnTime = 0.04, centreFlashTime = 0.035 }
local LIST_REFRESH = 0.5
local DRAW_DIST = 6000
local DLIGHT_DIST = 2500
local MAX_DLIGHT_CARS = 8
local DLIGHT_BASE = 0x40000
local LENS_HEIGHT = 1.7
local PHASE_PER_INDEX = 0.37
local DLIGHT = { brightness = 2, decay = 4000, size = 360, life = 0.05 }
-- the glow's place on the bar: over its middle
local BAR_LIGHT_OFFSET = Vector(0, 0, 14)

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
-- the LED bar's lens texture frame per colour (police_lightbar/leds_*.vtf)
local LENS_FRAMES = { red = 1, white = 2, blue = 3, yellow = 4 }
-- the bar's colour per side (-1 driver's, 0 centre, 1 passenger's) by scheme
local SCHEME_SIDE_NAMES = {
	police = { [-1] = "red", [0] = "white", [1] = "blue" },
	fire = { [-1] = "red", [0] = "yellow", [1] = "yellow" },
	medical = { [-1] = "red", [0] = "white", [1] = "white" },
}
local SCHEME_SIDES = {}
for scheme, names in pairs(SCHEME_SIDE_NAMES) do
	SCHEME_SIDES[scheme] = {}
	for side, name in pairs(names) do SCHEME_SIDES[scheme][side] = COLORS[name] end
end

local function schemeOf(vehicle)
	local scheme = vehicle:GetNW2String("audio_lightscheme", "police")
	return SCHEME_SIDES[scheme] and scheme or "police"
end

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

local function phaseTimeOf(vehicle)
	return CurTime() + vehicle:EntIndex() * PHASE_PER_INDEX
end

-- whether a side's outer lamps (-1 driver's / red, 1 passenger's / blue) are lit on a car right now,
-- in step with its bar (cl_hud's police cluster blinks its CODE 2 / CODE 3 buttons with it)
local outerLamp = { side = -1, group = "o" }
function AudioEngine.PoliceSideLit(vehicle, side)
	local mode = vehicle:GetNW2Int("audio_lights", 0)
	if mode == 0 then return false end
	outerLamp.side = side

	return isLit(outerLamp, mode, phaseTimeOf(vehicle))
end

--[[
	The LED bar's lenses: its lens materials name this proxy with their lens ("lens" "front_driver_outer",
	AudioEngine.LIGHTBAR_MODULES[i].lens). As the bar is drawn it sets the lens's texture frame: unlit,
	or the colour of its side while its module is lit. The bar is parented to its car.
]]
local lampByLens = {}
for _, lamp in ipairs(AudioEngine.LIGHTBAR_MODULES) do
	if lamp.lens then lampByLens[lamp.lens] = lamp end
end

local function lensFrame(lightbar, lamp)
	if not lamp or not IsValid(lightbar) then return 0 end
	local vehicle = lightbar:GetParent()
	if not IsValid(vehicle) then return 0 end
	local mode = vehicle:GetNW2Int("audio_lights", 0)
	if mode == 0 or not isLit(lamp, mode, phaseTimeOf(vehicle)) then return 0 end

	return LENS_FRAMES[SCHEME_SIDE_NAMES[schemeOf(vehicle)][lamp.side]] or 0
end

matproxy.Add({
	name = "AudioLightbarLens",
	init = function(self, material, values)
		self.lamp = lampByLens[string.lower(values.lens or "")]
	end,
	bind = function(self, material, entity)
		material:SetInt("$frame", lensFrame(entity, self.lamp))
	end,
})

-- cars with lights near enough to matter, refreshed now and then rather than searched every frame
local emergencyCars = {}
local nextRefresh = 0

local function refreshList()
	emergencyCars = {}
	for _, vehicle in ipairs(ents.FindByClass("prop_vehicle_jeep")) do
		local lightbar = vehicle:GetNW2Entity("audio_lightbar")
		if IsValid(lightbar) then
			local entry = { vehicle = vehicle, lightbar = lightbar, sides = SCHEME_SIDES[schemeOf(vehicle)] }
			if lightbar == vehicle then
				local builtinSet = AudioEngine.BUILTIN_LIGHTS[string.lower(vehicle:GetModel() or "")]
				local bone = builtinSet and vehicle:LookupBone(builtinSet.bone)
				if bone then
					entry.lamps, entry.bone = builtinSet.lamps, bone
					table.insert(emergencyCars, entry)
				end
			else
				-- (the LED bar lights its own lenses: nothing drawn over it)
				entry.lensesLightThemselves = string.lower(lightbar:GetModel() or "") == AudioEngine.LIGHTBAR_LED_MODEL
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

local function drawLens(worldPosition, worldNormal, width, height, color)
	render.SetMaterial(LENS_MATERIAL)
	render.DrawQuadEasy(worldPosition, worldNormal, width, height, color, 0)
end

-- a direction in a frame given by its forward / right / up (right = -y, as Entity:GetRight)
local function turned(forward, right, up, direction)
	return forward * direction.x - right * direction.y + up * direction.z
end

-- where the bar is drawn (the car may be drawn ahead of Source's copy: cl_handling.lua)
local function lightbarPose(lightbar)
	if AudioEngine.DisplayPose then return AudioEngine.DisplayPose(lightbar) end
	return lightbar:GetPos(), lightbar:GetAngles()
end

local function drawBar(entry, mode, phaseTime)
	local barPosition, angles = lightbarPose(entry.lightbar)
	local forward, right, up = angles:Forward(), angles:Right(), angles:Up()
	for _, lamp in ipairs(AudioEngine.LIGHTBAR_MODULES) do
		if isLit(lamp, mode, phaseTime) then
			drawLens(LocalToWorld(lamp.position, angle_zero, barPosition, angles), turned(forward, right, up, lamp.normal), lamp.width, LENS_HEIGHT, entry.sides[lamp.side])
		end
	end
end

-- built-in lamps follow the body bone (nil while the car hasn't set up its bones: not drawn)
local function drawBuiltin(entry, mode, phaseTime)
	local boneMatrix = entry.vehicle:GetBoneMatrix(entry.bone)
	if not boneMatrix then return end
	local forward, right, up = boneMatrix:GetForward(), boneMatrix:GetRight(), boneMatrix:GetUp()
	for _, lamp in ipairs(entry.lamps) do
		if isLit(lamp, mode, phaseTime) then
			drawLens(boneMatrix * lamp.position, turned(forward, right, up, lamp.normal), lamp.width, lamp.height, COLORS[lamp.color] or COLORS.white)
		end
	end
end

hook.Add("PostDrawTranslucentRenderables", "audio_engine_police", function(drawingDepth, drawingSkybox)
	if drawingDepth or drawingSkybox then return end
	local eyePosition = EyePos()
	for _, entry in ipairs(emergencyCars) do
		if not entry.lensesLightThemselves then
			local mode = lightModeOf(entry)
			if mode > 0 and entry.lightbar:GetPos():DistToSqr(eyePosition) < DRAW_DIST * DRAW_DIST then
				local phaseTime = phaseTimeOf(entry.vehicle)
				if entry.lamps then drawBuiltin(entry, mode, phaseTime) else drawBar(entry, mode, phaseTime) end
			end
		end
	end
end)

-- the colour the car's lights glow with right now, or nil: the driver's side, else the passenger's,
-- else the centre (the patterns light one side at a time)
local GLOW_ORDER = { { side = -1, group = "o" }, { side = 1, group = "o" }, { side = 0, group = "c" } }
local function glowColor(entry, mode, phaseTime)
	if entry.lamps then
		for _, wanted in ipairs(GLOW_ORDER) do
			for _, lamp in ipairs(entry.lamps) do
				if lamp.side == wanted.side and isLit(lamp, mode, phaseTime) then return COLORS[lamp.color] or COLORS.white end
			end
		end

		return nil
	end
	for _, wanted in ipairs(GLOW_ORDER) do
		if isLit(wanted, mode, phaseTime) then return entry.sides[wanted.side] end
	end

	return nil
end

-- where the glow comes from: over the bar's middle, or the middle of the built-in lamps
local function glowPosition(entry)
	if not entry.lamps then
		local barPosition, angles = lightbarPose(entry.lightbar)
		return (LocalToWorld(BAR_LIGHT_OFFSET, angle_zero, barPosition, angles))
	end
	local localPosition = entry.lampsMiddle
	if not localPosition then
		localPosition = Vector(0, 0, 0)
		for _, lamp in ipairs(entry.lamps) do localPosition = localPosition + lamp.position end
		localPosition = localPosition / math.max(#entry.lamps, 1)
		entry.lampsMiddle = localPosition
	end
	local boneMatrix = entry.vehicle:GetBoneMatrix(entry.bone)

	return boneMatrix and boneMatrix * localPosition
end

local function lightSurroundings(entry, mode, phaseTime)
	local color = glowColor(entry, mode, phaseTime)
	local position = color and glowPosition(entry)
	if not position then return end
	local dynamicLight = DynamicLight(DLIGHT_BASE + entry.vehicle:EntIndex())
	if not dynamicLight then return end
	dynamicLight.pos = position
	dynamicLight.r, dynamicLight.g, dynamicLight.b = color.r, color.g, color.b
	dynamicLight.brightness = DLIGHT.brightness
	dynamicLight.decay = DLIGHT.decay
	dynamicLight.size = DLIGHT.size
	dynamicLight.dietime = CurTime() + DLIGHT.life
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
		lightSurroundings(entry, lightModeOf(entry), phaseTimeOf(entry.vehicle))
	end
end)

-- the light key, sent as a console command like the start key (cl_engine.lua)
-- key name -> KEY_ code, looked up once per name (a string built and looked up every frame otherwise)
local keyCodes = {}
local function keyCodeOf(keyName)
	local keyCode = keyCodes[keyName]
	if keyCode == nil then
		keyCode = _G["KEY_" .. string.upper(keyName)] or false
		keyCodes[keyName] = keyCode
	end
	return keyCode or nil
end
local lightKeyHeld = false
hook.Add("Think", "audio_engine_lightkey", function()
	local keyCode = keyCodeOf(lightKeyConVar:GetString())
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
