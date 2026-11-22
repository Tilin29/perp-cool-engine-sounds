--[[
	Emergency lights (sh_police.lua, sv_police.lua): the flashing. The light key
	(audio_engine_lightkey, default left shift) steps the driver's lights off -> CODE 2 -> CODE 3 -> off.

	Patterns (half the cars run half a period later, AudioEngine.LightPhaseTime, so cars side by
	side alternate rather than flash in step):
	  CODE 2: slow wig-wag, the driver's outer modules and corners with the passenger's inner ones,
	          then the other way round
	  CODE 3: the same split as quad flashes, twice as fast, plus double flashes in the middle

	Colours by the car's scheme (NW2 audio_lightscheme): police red / white / blue, fire red / yellow,
	medical red / white, per side of the bar; built-in lamps keep their lens's own colour.

	How a lit module shows:
	  - the LED bar (AudioEngine.LIGHTBAR_LED_MODEL, addons/police_lightbar): its lenses light
	    themselves, all in its materials: the server sets the bar's skin for the car's scheme and
	    mode (sv_police's AudioEngine.SetLights), whose lens materials run the pattern with Source's
	    own VMT proxies. No Lua here; nothing is drawn over it.
	  - PERP's original bar (the addon not installed): nothing drawn over it (the user: no overlaid
	    colours), only the glow.
	  - the built-in lamps (AudioEngine.BUILTIN_LIGHTS, a car whose audio_lightbar is itself, placed
	    by its body bone): their lenses are plain textures, so a lit one gets a drawn glowing quad.
	  - the glow: one dynamic light per car (the nearest MAX_DLIGHT_CARS), in the colour flashing at
	    that moment, over the side it flashes on (BAR_LIGHT_OFFSETS; built-in lamps: that side's middle). It replaced a glow sprite on every lit lens and a dynamic light per side: many
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
local DLIGHT = { brightness = 2, decay = 4000, size = 360, life = 0.05 }
-- the glow's place on the bar (its model space: -X the driver's side, front +Y), by the side flashing:
-- over that end's outer modules, the centre's over the front centre lens
local BAR_LIGHT_OFFSETS = { [-1] = Vector(-22, 0, 14), [0] = Vector(0, 8, 14), [1] = Vector(22, 0, 14) }

local LENS_MATERIAL = CreateMaterial("audio_engine_lightbar_lens", "UnlitGeneric", {
	["$basetexture"] = "color/white",
	["$additive"] = "1",
	["$vertexcolor"] = "1",
	["$vertexalpha"] = "1",
})
-- the glow's colours: the LED bar's lit lenses' own (the average of the user's led_large_<colour>.png
-- LEDs, scaled to full brightness; the blue was 25, 70, 255, deeper than the lenses' azure, which
-- showed in the dark, the user; the yellow was orange)
local COLORS = {
	red = Color(255, 40, 23),
	white = Color(247, 250, 255),
	blue = Color(45, 139, 255),
	yellow = Color(255, 227, 40),
}
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

-- (the same phase as the LED bar's skins: sh_police)
local function phaseTimeOf(vehicle, mode)
	return AudioEngine.LightPhaseTime(vehicle, mode)
end

-- whether a side's outer lamps (-1 driver's / red, 1 passenger's / blue) are lit on a car right now,
-- in step with its bar (cl_hud's police cluster blinks its CODE 2 / CODE 3 buttons with it)
local outerLamp = { side = -1, group = "o" }
function AudioEngine.PoliceSideLit(vehicle, side)
	local mode = vehicle:GetNW2Int("audio_lights", 0)
	if mode == 0 then return false end
	outerLamp.side = side

	return isLit(outerLamp, mode, phaseTimeOf(vehicle, mode))
end

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
				-- (a bar: nothing drawn over it, only its glow)
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
		if entry.lamps then
			local mode = lightModeOf(entry)
			if mode > 0 and entry.lightbar:GetPos():DistToSqr(eyePosition) < DRAW_DIST * DRAW_DIST then
				drawBuiltin(entry, mode, phaseTimeOf(entry.vehicle, mode))
			end
		end
	end
end)

-- the colour the car's lights glow with right now and the side it comes from (-1 driver's, 1
-- passenger's, 0 centre), or nil: the driver's side, else the passenger's, else the centre (the
-- patterns light one side at a time)
local GLOW_ORDER = { { side = -1, group = "o" }, { side = 1, group = "o" }, { side = 0, group = "c" } }
local function glowColor(entry, mode, phaseTime)
	if entry.lamps then
		for _, wanted in ipairs(GLOW_ORDER) do
			for _, lamp in ipairs(entry.lamps) do
				if lamp.side == wanted.side and isLit(lamp, mode, phaseTime) then return COLORS[lamp.color] or COLORS.white, wanted.side end
			end
		end

		return nil
	end
	for _, wanted in ipairs(GLOW_ORDER) do
		if isLit(wanted, mode, phaseTime) then return entry.sides[wanted.side], wanted.side end
	end

	return nil
end

-- where the glow comes from: over the flashing side's end of the bar, or the middle of that side's
-- built-in lamps
local function glowPosition(entry, side)
	if not entry.lamps then
		local barPosition, angles = lightbarPose(entry.lightbar)
		return (LocalToWorld(BAR_LIGHT_OFFSETS[side], angle_zero, barPosition, angles))
	end
	entry.lampMiddles = entry.lampMiddles or {}
	local localPosition = entry.lampMiddles[side]
	if not localPosition then
		local count = 0
		localPosition = Vector(0, 0, 0)
		for _, lamp in ipairs(entry.lamps) do
			if lamp.side == side then localPosition, count = localPosition + lamp.position, count + 1 end
		end
		localPosition = localPosition / math.max(count, 1)
		entry.lampMiddles[side] = localPosition
	end
	local boneMatrix = entry.vehicle:GetBoneMatrix(entry.bone)

	return boneMatrix and boneMatrix * localPosition
end

local function lightSurroundings(entry, mode, phaseTime)
	local color, side = glowColor(entry, mode, phaseTime)
	local position = color and glowPosition(entry, side)
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
		local mode = lightModeOf(entry)
		lightSurroundings(entry, mode, phaseTimeOf(entry.vehicle, mode))
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
