--[[
	Audio Engine - driver HUD (client): the instrument cluster, centred at the bottom of the screen,
	no panel behind it. Four looks, picked with audio_engine_cluster (not saved: every load starts
	on 0):
	  0   automatic (the default): 4 in a police car, 1 in any other
	  1   classic (design A): rev counter, speedometer and fuel gauge as dials with needles
	  2   floating arc (B): one rev arc with the speed and gear in its middle
	  3   motorsport strip (C): a bar of rev segments over speed / gear / rpm read-outs
	  4   classic with the police panel (A2: siren tones, CODE 2 / CODE 3, the light bar's flashes):
	      police cars only (scheme "police" with a light bar), any other car shows 1
	Drawn after the "Speedometer HUD" design canvas (artboards A, A2, B, C): the positions and
	sizes below are that design's pixels, scaled to the screen.

	Indicators, hazards and headlights are the cluster's own lamps on the default controls (see
	"the cluster's own lights" below), PERP's where it has them; without PERP the fuel gauge sits
	at full.
]]

local AudioEngine = AUDIO_ENGINE

local hudConVar = CreateClientConVar("audio_engine_hud", "1", true, false, "Show the instrument cluster")
local unitsConVar = CreateClientConVar("audio_engine_units", "mph", true, false, "HUD speed units: mph or kmh")
-- the default used to be kmh, and the old value is archived: move everyone to mph once
-- (a cookie remembers it, so choosing kmh again afterwards sticks)
if cookie.GetNumber("audio_engine_units_mph", 0) == 0 then
	cookie.Set("audio_engine_units_mph", "1")
	if unitsConVar:GetString() ~= "mph" then RunConsoleCommand("audio_engine_units", "mph") end
end
local scaleConVar = CreateClientConVar("audio_engine_hud_scale", "1", true, false, "HUD size multiplier", 0.5, 2)
-- (not archived: the user's rule, every load starts on A)
local clusterConVar = CreateClientConVar("audio_engine_cluster", "0", false, false,
	"Instrument cluster: 0 automatic (4 in police cars, else 1), 1 classic, 2 floating arc, 3 motorsport strip, 4 classic + police panel (police cars only). Not saved")

local cos, sin, rad, min, max, floor, abs, clamp = math.cos, math.sin, math.rad, math.min, math.max, math.floor, math.abs, math.Clamp

-- the design's size of each cluster x this x (screen height / 1080) x audio_engine_hud_scale
local CLUSTER_SIZE = { a = 0.7, a2 = 0.7, b = 0.75, c = 0.65 }
local BOTTOM_MARGIN = 20       -- px at 1080 between the cluster and the bottom of the screen
local MIN_FONT = 9             -- px: smaller text can't be read

local function rgb(hex, alpha)
	return Color(tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16), alpha or 255)
end
local function mix(colorA, colorB, share, alpha)
	return Color(colorA.r + (colorB.r - colorA.r) * share, colorA.g + (colorB.g - colorA.g) * share, colorA.b + (colorB.b - colorA.b) * share, alpha or 255)
end
local function faded(color, alpha) return Color(color.r, color.g, color.b, alpha) end

local WHITE, BLACK = rgb("ffffff"), rgb("000000")

---------------------------------------------------------------------------
-- fonts (made again when the size changes). Roboto Condensed ships with the game; the design's
-- Barlow / Chakra Petch would be a download for every player
---------------------------------------------------------------------------
local FONTS = {
	-- name = { design px, weight, italic, glow (blur px) }
	A_Tach = { 25, 500, false, 3 }, A_Speed = { 25, 500, false, 3 }, A_Fuel = { 21, 500, false, 3 },
	A_Label = { 12, 600 }, A_Unit = { 15, 600 }, A_Gear = { 27, 600, false, 3 }, A_Button = { 16, 700 },
	B_Num = { 17, 600, true }, B_Small = { 13, 600, true }, B_Speed = { 118, 700, true }, B_Unit = { 18, 600 },
	B_Rpm = { 18, 500 }, B_Gear = { 76, 700, true },
	C_Scale = { 14, 600 }, C_Label = { 13, 600 }, C_Speed = { 84, 700, true }, C_Gear = { 140, 700, true },
	C_Rpm = { 44, 600, true }, C_Unit = { 18, 600 },
}
local fontScales = {}
local function fontsFor(prefix, scale)
	if fontScales[prefix] == scale then return end
	fontScales[prefix] = scale
	for name, spec in pairs(FONTS) do
		if name:sub(1, #prefix) == prefix then
			local size = max(MIN_FONT, floor(spec[1] * scale + 0.5))
			surface.CreateFont("AudioHud_" .. name, { font = "Roboto Condensed", size = size, weight = spec[2], italic = spec[3] or false, antialias = true, extended = true })
			if spec[4] then
				surface.CreateFont("AudioHud_" .. name .. "_Glow", { font = "Roboto Condensed", size = size, weight = spec[2], italic = spec[3] or false,
					antialias = true, extended = true, blursize = max(1, floor(spec[4] * scale + 0.5)) })
			end
		end
	end
end

---------------------------------------------------------------------------
-- drawing, in the design's pixels: x, y go through place() to the screen
---------------------------------------------------------------------------
local originX, originY, pixel = 0, 0, 1
local function place(x, y) return originX + x * pixel, originY + y * pixel end

-- polygons' point tables are made once and filled in place (DrawPoly reads them as it's called)
local pointPool = {}
local function points(count)
	local list = pointPool[count]
	if not list then
		list = {}
		for i = 1, count do list[i] = { x = 0, y = 0 } end
		pointPool[count] = list
	end
	return list
end

-- DrawPoly needs a convex polygon wound clockwise on screen: turned round if it isn't
local function fillPoly(list, count, color)
	local area = 0
	for i = 1, count do
		local a, b = list[i], list[i % count + 1]
		area = area + a.x * b.y - b.x * a.y
	end
	if area < 0 then
		for i = 1, floor(count / 2) do
			local a, b = list[i], list[count + 1 - i]
			a.x, b.x, a.y, b.y = b.x, a.x, b.y, a.y
		end
	end
	draw.NoTexture()
	surface.SetDrawColor(color)
	surface.DrawPoly(list)
end

-- screen point at `radius` design px from a centre, at a gauge angle (degrees, 0 = up, clockwise)
local function polar(centreX, centreY, radius, degrees)
	local angle = rad(degrees)
	return centreX + radius * sin(angle) * pixel, centreY - radius * cos(angle) * pixel
end

local function line(x0, y0, x1, y1, width, color)
	local deltaX, deltaY = x1 - x0, y1 - y0
	local length = math.sqrt(deltaX * deltaX + deltaY * deltaY)
	if length < 0.001 then return end
	local offsetX, offsetY = -deltaY / length * width * 0.5, deltaX / length * width * 0.5
	local list = points(4)
	list[1].x, list[1].y = x0 + offsetX, y0 + offsetY
	list[2].x, list[2].y = x1 + offsetX, y1 + offsetY
	list[3].x, list[3].y = x1 - offsetX, y1 - offsetY
	list[4].x, list[4].y = x0 - offsetX, y0 - offsetY
	fillPoly(list, 4, color)
end

-- a band between two radii (design px) from one gauge angle to another
local function band(centreX, centreY, innerRadius, outerRadius, fromDegrees, toDegrees, color, stepDegrees)
	if toDegrees - fromDegrees < 0.05 then return end
	local segments = max(2, floor((toDegrees - fromDegrees) / (stepDegrees or 4)))
	local list = points(4)
	for i = 0, segments - 1 do
		local a0 = fromDegrees + (toDegrees - fromDegrees) * i / segments
		local a1 = fromDegrees + (toDegrees - fromDegrees) * (i + 1) / segments
		list[1].x, list[1].y = polar(centreX, centreY, outerRadius, a0)
		list[2].x, list[2].y = polar(centreX, centreY, outerRadius, a1)
		list[3].x, list[3].y = polar(centreX, centreY, innerRadius, a1)
		list[4].x, list[4].y = polar(centreX, centreY, innerRadius, a0)
		fillPoly(list, 4, color)
	end
end

local CIRCLE_SEGMENTS = 48
local function disc(centreX, centreY, radius, color)
	local list = points(CIRCLE_SEGMENTS)
	for i = 1, CIRCLE_SEGMENTS do list[i].x, list[i].y = polar(centreX, centreY, radius, (i - 1) / CIRCLE_SEGMENTS * 360) end
	fillPoly(list, CIRCLE_SEGMENTS, color)
end

local function text(value, font, x, y, color, alignX, alignY, glowColor)
	local screenX, screenY = place(x, y)
	screenX, screenY = floor(screenX + 0.5), floor(screenY + 0.5)
	if glowColor then draw.SimpleText(value, "AudioHud_" .. font .. "_Glow", screenX, screenY, glowColor, alignX, alignY) end
	draw.SimpleText(value, "AudioHud_" .. font, screenX, screenY, color, alignX or TEXT_ALIGN_CENTER, alignY or TEXT_ALIGN_CENTER)
end
local function textShadowed(value, font, x, y, color, alignX, alignY)
	local screenX, screenY = place(x, y)
	screenX, screenY = floor(screenX + 0.5), floor(screenY + 0.5)
	draw.SimpleText(value, "AudioHud_" .. font, screenX + pixel, screenY + 2 * pixel, Color(0, 0, 0, 150), alignX, alignY)
	draw.SimpleText(value, "AudioHud_" .. font, screenX, screenY, color, alignX, alignY)
end
local function textWidth(value, font)
	surface.SetFont("AudioHud_" .. font)
	return (surface.GetTextSize(value)) / pixel
end

-- a box leaning like italic type (CSS skewX(-degrees)): x, y = its top left before the lean
local function leaningBox(x, y, width, height, degrees, color)
	local shift = math.tan(rad(degrees)) * height * 0.5
	local list = points(4)
	list[1].x, list[1].y = place(x + shift, y)
	list[2].x, list[2].y = place(x + width + shift, y)
	list[3].x, list[3].y = place(x + width - shift, y + height)
	list[4].x, list[4].y = place(x - shift, y + height)
	fillPoly(list, 4, color)
end

local function rectangle(x, y, width, height, color)
	local screenX, screenY = place(x, y)
	surface.SetDrawColor(color)
	surface.DrawRect(screenX, screenY, width * pixel, height * pixel)
end
local function outline(x, y, width, height, color)
	local screenX, screenY = place(x, y)
	surface.SetDrawColor(color)
	surface.DrawOutlinedRect(screenX, screenY, width * pixel, height * pixel, max(1, floor(pixel + 0.5)))
end

---------------------------------------------------------------------------
-- icons: drawn in their own viewBox, centred on x, y, `width` design px wide
---------------------------------------------------------------------------
local iconX, iconY, iconScale = 0, 0, 1
local function iconPoint(u, v) return iconX + u * iconScale, iconY + v * iconScale end
local function iconStart(x, y, width, boxWidth, boxHeight)
	iconScale = width / boxWidth * pixel
	local screenX, screenY = place(x, y)
	iconX, iconY = screenX - boxWidth * 0.5 * iconScale, screenY - boxHeight * 0.5 * iconScale
end
local function iconPoly(color, ...)
	local coordinates = { ... }
	local count = #coordinates / 2
	local list = points(count)
	for i = 1, count do list[i].x, list[i].y = iconPoint(coordinates[i * 2 - 1], coordinates[i * 2]) end
	fillPoly(list, count, color)
end
local function iconLine(width, color, ...)
	local coordinates = { ... }
	for i = 1, #coordinates / 2 - 1 do
		local x0, y0 = iconPoint(coordinates[i * 2 - 1], coordinates[i * 2])
		local x1, y1 = iconPoint(coordinates[i * 2 + 1], coordinates[i * 2 + 2])
		line(x0, y0, x1, y1, width * iconScale, color)
	end
end
-- an arc in the icon's box: centre u, v, radius, gauge angles
local function iconArc(u, v, radius, fromDegrees, toDegrees, width, color)
	local centreX, centreY = iconPoint(u, v)
	local savedPixel = pixel
	pixel = iconScale
	band(centreX, centreY, radius - width * 0.5, radius + width * 0.5, fromDegrees, toDegrees, color)
	pixel = savedPixel
end
local function iconDisc(u, v, radius, color)
	local centreX, centreY = iconPoint(u, v)
	local savedPixel = pixel
	pixel = iconScale
	disc(centreX, centreY, radius, color)
	pixel = savedPixel
end

-- the indicators' soft glow behind their arrows (only theirs: the user's; other lamps just light up)
local function indicatorGlow(x, y, radius, color)
	local screenX, screenY = place(x, y)
	disc(screenX, screenY, radius, faded(color, 38))
	disc(screenX, screenY, radius * 0.6, faded(color, 30))
end

local ICONS = {}
function ICONS.headlights(x, y, width, color, stroke)
	iconStart(x, y, width, 30, 24)
	-- M17 3 C27 3 27 21 17 21 Z: a half ellipse
	local coordinates = {}
	for i = 0, 12 do
		local angle = rad(-90 + i * 15)
		coordinates[#coordinates + 1] = 17 + 7.5 * cos(angle)
		coordinates[#coordinates + 1] = 12 + 9 * sin(angle)
	end
	iconPoly(color, unpack(coordinates))
	iconLine(stroke or 2.2, color, 3, 6, 13, 8)
	iconLine(stroke or 2.2, color, 3, 11, 13, 13)
	iconLine(stroke or 2.2, color, 3, 16, 13, 18)
end
function ICONS.handbrake(x, y, width, color, stroke)
	stroke = stroke or 2
	iconStart(x, y, width, 32, 24)
	iconArc(16, 12, 8, 0, 360, stroke, color)
	iconLine(stroke, color, 13.6, 16.5, 13.6, 7.5, 17, 7.5)
	iconArc(17, 10.1, 2.6, 0, 180, stroke, color)
	iconLine(stroke, color, 17, 12.7, 13.6, 12.7)
	iconArc(13.35, 12, 10.5, -135.6, -44.4, stroke, color)
	iconArc(18.65, 12, 10.5, 44.4, 135.6, stroke, color)
end
function ICONS.fuel(x, y, width, color, stroke)
	stroke = stroke or 2
	iconStart(x, y, width, 24, 24)
	iconLine(stroke, color, 4, 3, 14, 3, 14, 21, 4, 21, 4, 3)
	iconPoly(color, 6.5, 5.5, 11.5, 5.5, 11.5, 10, 6.5, 10)
	iconLine(stroke * 0.9, color, 14, 9, 16.5, 9, 18.3, 10.8, 18.3, 17, 19.65, 18.4, 21, 17, 21, 8.5, 18.5, 6)
end
-- A's arrows: a head and a shaft (the polygon isn't convex)
function ICONS.arrowA(x, y, width, color, left)
	iconStart(x, y, width, 34, 28)
	if left then
		iconPoly(color, 2, 14, 14, 2, 14, 26)
		iconPoly(color, 14, 9, 32, 9, 32, 19, 14, 19)
	else
		iconPoly(color, 32, 14, 20, 26, 20, 2)
		iconPoly(color, 2, 9, 20, 9, 20, 19, 2, 19)
	end
end
-- B's double chevrons
function ICONS.chevrons(x, y, width, color, left)
	iconStart(x, y, width, 34, 26)
	if left then
		iconLine(4.5, color, 16, 2, 4, 13, 16, 24)
		iconLine(4.5, color, 30, 2, 18, 13, 30, 24)
	else
		iconLine(4.5, color, 18, 2, 30, 13, 18, 24)
		iconLine(4.5, color, 4, 2, 16, 13, 4, 24)
	end
end
-- C's arrowheads (two triangles: the shape isn't convex)
function ICONS.arrowhead(x, y, width, color, left)
	iconStart(x, y, width, 22, 26)
	if left then
		iconPoly(color, 20, 1, 15, 13, 2, 13)
		iconPoly(color, 2, 13, 15, 13, 20, 25)
	else
		iconPoly(color, 2, 1, 20, 13, 7, 13)
		iconPoly(color, 7, 13, 20, 13, 2, 25)
	end
end

---------------------------------------------------------------------------
-- what the cluster shows (read once a frame)
---------------------------------------------------------------------------
local state = { rpm = 0, fuelShown = 1 }

local function speedUnits()
	local usesMph = unitsConVar:GetString() == "mph"
	return usesMph, usesMph and 2.23694 or 3.6, usesMph and "MPH" or "KM/H"
end

local function gearLabel(engineState)
	if not engineState.on then return "-" end
	if engineState.phase ~= "run" then return "N" end
	if engineState.gear == -1 then return "R" end
	if engineState.gear > 0 then return tostring(engineState.gear) end
	return "N"
end

--[[
	The cluster's own lights, ready for PERP: nothing on the car itself is lit or networked, only
	the lamps on the cluster follow the controls. Left click = left indicator, right click = right
	indicator (pressed again, or the other one, it goes off / over), both together (within
	BOTH_CLICK_WINDOW) = hazards, F = headlights; the handbrake lamp is Space. Where the PERP
	gamemode's own vehicle methods are there (IsIndicating, GetIndicatorDirection (true = left),
	HasHazardLights, GetHeadlights, GetFuel 0..10000, IsHandBraking) they're shown instead, and the
	audio_engine/cluster-lights hook (vehicle, lights) can fill in `lights` { left, right, hazards,
	headlights, fuel (0..1), handbrake } for any other source.
]]
local BOTH_CLICK_WINDOW = 0.15   -- s between the two clicks that make the hazards
local BLINK_PERIOD = 0.8         -- s, on for half of it
local ownLights = setmetatable({}, { __mode = "k" })   -- vehicle -> { indicator = "left" | "right" | nil, hazards, headlights }
local clickState = { left = false, right = false, pendingSide = nil, pendingAt = 0, f = false }

local function lightsOf(vehicle)
	local lights = ownLights[vehicle]
	if not lights then lights = {}; ownLights[vehicle] = lights end
	return lights
end

local function toggleIndicator(lights, side)
	lights.hazards = false
	lights.indicator = lights.indicator ~= side and side or nil
end

local function controlsAllowed(player)
	return not player:IsTyping() and not gui.IsGameUIVisible() and not vgui.CursorVisible() and system.HasFocus()
end

hook.Add("Think", "audio_engine_cluster_lights", function()
	local player = LocalPlayer()
	local vehicle = IsValid(player) and player:GetVehicle()
	if not IsValid(vehicle) or not AudioEngine.GetClientCar or not AudioEngine.GetClientCar(vehicle) then
		clickState.left, clickState.right, clickState.pendingSide, clickState.f = false, false, nil, false
		return
	end
	local allowed = controlsAllowed(player)
	local leftDown = allowed and input.IsMouseDown(MOUSE_LEFT)
	local rightDown = allowed and input.IsMouseDown(MOUSE_RIGHT)
	local fDown = allowed and input.IsKeyDown(KEY_F)
	local lights = lightsOf(vehicle)
	local now = RealTime()
	local leftPressed, rightPressed = leftDown and not clickState.left, rightDown and not clickState.right
	clickState.left, clickState.right = leftDown, rightDown

	if (leftPressed and (rightDown or clickState.pendingSide == "right")) or (rightPressed and (leftDown or clickState.pendingSide == "left")) then
		-- both: the hazards (a single click still waiting is taken back into them)
		clickState.pendingSide = nil
		lights.hazards = not lights.hazards
		lights.indicator = nil
	elseif leftPressed or rightPressed then
		clickState.pendingSide, clickState.pendingAt = leftPressed and "left" or "right", now
	elseif clickState.pendingSide and now - clickState.pendingAt >= BOTH_CLICK_WINDOW then
		toggleIndicator(lights, clickState.pendingSide)
		clickState.pendingSide = nil
	end

	if fDown and not clickState.f then lights.headlights = not lights.headlights end
	clickState.f = fDown
end)

local hookLights = {}
--[[
	The needles and read-outs move like a stepper-motor gauge, not with every wobble of the
	measured speed and revs (position samples, the limiter trimming the power, the converter): the
	value is filtered over `filter` s, the needle stays put until that is `band` away, then
	travels to it (eased, at `slowest`..`fastest` per s: a gear change's drop is still quick) and
	stops there. Digits show the needle's value (rpm in steps of RPM_DIGIT_STEP).
	Once it has caught up, it keeps following while the revs go on moving the same way faster than
	`drift` per s (their rate filtered over `rateTime` s) and holds again when they stop or turn: a
	slow climb (the last of the pull to top speed) went up in band-sized steps (the user)
]]
local RPM_GAUGE = { filter = 0.15, band = 120, slowest = 700, fastest = 16000, follow = 14, drift = 40, rateTime = 0.3 }      -- rpm
local RPM_DIGIT_STEP = 50
local rpmNeedle = {}

--[[
	The speedometer: the stepper-style hold above made it move in steps (held, then a jump each
	0.8 mph pulling away), and its speed came from the car's drawn position frame to frame, which
	jittered more the faster the car (fast cars' needles kept kicking). Now the speed is the server's
	own physics (AudioEngine.ServerSpeed, the driver's drive state, cl_handling), else a line fitted
	through the last SPEED_FIT_SECONDS of positions on game time (single player, the listen host,
	prediction off), and the needle follows it smoothly over SPEED_NEEDLE_TIME s (no overshoot, so
	no sway). The digits change only once the needle is SPEED_DIGIT_HOLD past the shown number
]]
local SPEED_FIT_SECONDS = 0.3
local SPEED_NEEDLE_TIME = 0.15
local SPEED_DIGIT_HOLD = 0.6
local speedNeedle = {}
local speedHistory = { vehicle = nil, count = 0 }

-- metres/s from the drawn positions, fitted over the last SPEED_FIT_SECONDS (a least squares slope per axis)
local function fittedSpeed(vehicle)
	if speedHistory.vehicle ~= vehicle then speedHistory.vehicle, speedHistory.count = vehicle, 0 end
	local now, position = CurTime(), vehicle:GetPos()
	local count = speedHistory.count
	-- (a frame on the same game time adds nothing)
	if count == 0 or now > speedHistory[count].time then
		count = count + 1
		local sample = speedHistory[count] or {}
		sample.time, sample.x, sample.y, sample.z = now, position.x, position.y, position.z
		speedHistory[count] = sample
	end
	-- drop samples older than the window (shifted down; a few dozen at most)
	local first = 1
	while first < count and now - speedHistory[first].time > SPEED_FIT_SECONDS do first = first + 1 end
	if first > 1 then
		for index = first, count do speedHistory[index - first + 1], speedHistory[index] = speedHistory[index], speedHistory[index - first + 1] end
		count = count - first + 1
	end
	speedHistory.count = count
	if count < 3 then return nil end
	local meanTime, meanX, meanY, meanZ = 0, 0, 0, 0
	for index = 1, count do
		local sample = speedHistory[index]
		meanTime, meanX, meanY, meanZ = meanTime + sample.time, meanX + sample.x, meanY + sample.y, meanZ + sample.z
	end
	meanTime, meanX, meanY, meanZ = meanTime / count, meanX / count, meanY / count, meanZ / count
	local timeSquares, slopeX, slopeY, slopeZ = 0, 0, 0, 0
	for index = 1, count do
		local sample = speedHistory[index]
		local timeOffset = sample.time - meanTime
		timeSquares = timeSquares + timeOffset * timeOffset
		slopeX = slopeX + timeOffset * (sample.x - meanX)
		slopeY = slopeY + timeOffset * (sample.y - meanY)
		slopeZ = slopeZ + timeOffset * (sample.z - meanZ)
	end
	if timeSquares <= 0 then return nil end
	return math.sqrt(slopeX * slopeX + slopeY * slopeY + slopeZ * slopeZ) / timeSquares * 0.0254
end

--[[
	The revs for the arc (B) and the strip (C): their rev bar and LED segments stepped with the
	stepper-style needle value (held, then a jump every RPM_GAUGE.band), which a needle hides and a
	filled bar doesn't. They follow the revs smoothly over RPM_SMOOTH_TIME s instead; the digits
	change once the value is RPM_DIGIT_HOLD past them (idle's wobble otherwise flickered them)
]]
local RPM_SMOOTH_TIME = 0.05
local RPM_DIGIT_HOLD = 75
local smoothRpm = {}
local function smoothRpmValue(target, deltaTime)
	if not smoothRpm.value then smoothRpm.value, smoothRpm.digits = target, target end
	smoothRpm.value = smoothRpm.value + (target - smoothRpm.value) * min(1, deltaTime / RPM_SMOOTH_TIME)
	if abs(smoothRpm.value - smoothRpm.digits) > RPM_DIGIT_HOLD then smoothRpm.digits = smoothRpm.value end
	return smoothRpm.value, smoothRpm.digits
end

local function smoothSpeedNeedle(target, deltaTime)
	if not speedNeedle.value then speedNeedle.value, speedNeedle.digits = target, floor(target + 0.5) end
	speedNeedle.value = speedNeedle.value + (target - speedNeedle.value) * min(1, deltaTime / SPEED_NEEDLE_TIME)
	if abs(speedNeedle.value - speedNeedle.digits) > SPEED_DIGIT_HOLD then speedNeedle.digits = floor(speedNeedle.value + 0.5) end
	return speedNeedle.value, speedNeedle.digits
end

local function stepGauge(needle, spec, target, deltaTime)
	if not needle.value then needle.value, needle.filtered, needle.moving, needle.rate = target, target, false, 0 end
	local previous = needle.filtered
	needle.filtered = previous + (target - previous) * min(1, deltaTime / spec.filter)
	if deltaTime > 0 then
		needle.rate = needle.rate + ((needle.filtered - previous) / deltaTime - needle.rate) * min(1, deltaTime / spec.rateTime)
	end
	-- (following a steady climb or fall: needle.tracking is its direction, 1 or -1)
	if needle.tracking then
		if needle.rate * needle.tracking > spec.drift then
			needle.value = needle.filtered
			return needle.value
		end
		needle.tracking = nil
	end
	local gap = needle.filtered - needle.value
	if not needle.moving and abs(gap) > spec.band then needle.moving = true end
	if needle.moving then
		local step = clamp(abs(gap) * spec.follow, spec.slowest, spec.fastest) * deltaTime
		if abs(gap) <= step then
			needle.value, needle.moving = needle.filtered, false
			local direction = gap > 0 and 1 or -1
			if needle.rate * direction > spec.drift then needle.tracking = direction end
		else
			needle.value = needle.value + (gap > 0 and step or -step)
		end
	end
	return needle.value
end

local function readState(player, vehicle, car, deltaTime)
	local config, engineState = car.config, car.engineState
	state.rpm = max(0, stepGauge(rpmNeedle, RPM_GAUGE, engineState.rpm, deltaTime))
	state.rpmDigits = string.Comma(floor(state.rpm / RPM_DIGIT_STEP + 0.5) * RPM_DIGIT_STEP)
	local rpmSmooth, rpmSmoothDigits = smoothRpmValue(max(0, engineState.rpm), deltaTime)
	state.rpmSmooth = rpmSmooth
	state.rpmSmoothDigits = string.Comma(floor(rpmSmoothDigits / RPM_DIGIT_STEP + 0.5) * RPM_DIGIT_STEP)
	state.redline = config.redline
	state.majorRpm = (config.redline + 500 > 12000) and 2000 or 1000
	state.dialRpm = math.ceil((config.redline + 500) / state.majorRpm) * state.majorRpm
	state.share = state.rpm / config.redline
	state.limiter = engineState.limiterHoldTimer > 0 or state.share > 0.985
	local usesMph, factor, unitLabel = speedUnits()
	state.unitLabel, state.usesMph = unitLabel, usesMph
	local serverSpeed = AudioEngine.ServerSpeed and AudioEngine.ServerSpeed(vehicle)
	local metresPerSecond = serverSpeed and serverSpeed * 0.0254 or fittedSpeed(vehicle) or abs(car.speedAlongNose)
	if state.speedUnits ~= unitLabel then state.speedUnits, speedNeedle.value = unitLabel, nil end
	local speed, digits = smoothSpeedNeedle(metresPerSecond * factor, deltaTime)
	state.speed, state.speedDigits = max(0, speed), max(0, digits)
	local topSpeed = (tonumber(config.topSpeed) or 200) / 3.6 * factor
	state.speedMajor = topSpeed > 190 and 40 or 20
	state.dialSpeed = clamp(math.ceil(topSpeed * 1.1 / state.speedMajor) * state.speedMajor, usesMph and 80 or 120, usesMph and 260 or 400)
	state.gear = gearLabel(engineState)
	-- the lights: the cluster's own (the controls above), PERP's where it has them, then the hook
	local own = lightsOf(vehicle)
	local left, right, hazards = own.indicator == "left", own.indicator == "right", own.hazards or false
	local headlights, fuel = own.headlights or false, nil
	local handbrake = player:KeyDown(IN_JUMP)
	if vehicle.IsIndicating and vehicle.GetIndicatorDirection then
		local indicating, leftward = vehicle:IsIndicating(), vehicle:GetIndicatorDirection()
		left, right = indicating and leftward or false, indicating and not leftward or false
	end
	if vehicle.HasHazardLights then hazards = vehicle:HasHazardLights() end
	if vehicle.GetHeadlights then headlights = vehicle:GetHeadlights() end
	if vehicle.GetFuel then fuel = tonumber(vehicle:GetFuel()); fuel = fuel and fuel / 10000 end
	if vehicle.IsHandBraking and vehicle:IsHandBraking() then handbrake = true end
	hookLights.left, hookLights.right, hookLights.hazards, hookLights.headlights, hookLights.fuel, hookLights.handbrake =
		left, right, hazards, headlights, fuel, handbrake
	hook.Run("audio_engine/cluster-lights", vehicle, hookLights)

	state.fuel = hookLights.fuel and clamp(hookLights.fuel, 0, 1) or 1
	state.lowFuel = hookLights.fuel ~= nil and hookLights.fuel < 0.1
	state.fuelShown = state.fuelShown + (state.fuel - state.fuelShown) * min(1, deltaTime * 2)
	-- (PERP keeps the flash in step with its own lamps and tick sound)
	local blinkOn = vehicle.indicatorOn
	if blinkOn == nil then blinkOn = RealTime() % BLINK_PERIOD < BLINK_PERIOD / 2 end
	state.left = blinkOn and (hookLights.hazards or hookLights.left) or false
	state.right = blinkOn and (hookLights.hazards or hookLights.right) or false
	state.headlights = hookLights.headlights or false
	state.handbrake = hookLights.handbrake or false
	return state
end

---------------------------------------------------------------------------
-- A: classic dials (and A2's police panel on top)
---------------------------------------------------------------------------
local A = {
	backlight = rgb("ff4a36"), needle = rgb("ff5a2e"), red = rgb("c81e14"), redNumber = rgb("ff7a66"),
	green = rgb("4fe07a"), redLamp = rgb("ff4b3a"), amber = rgb("ffb53a"), off = rgb("18191b"),
	bezel = rgb("0b0c0d"), trim = rgb("6f7276"), trimLight = rgb("c8cacd"), wall = rgb("141517"), face = rgb("0a0b0c"),
	cap = rgb("1e1f21"), capLight = rgb("3a3c3f"),
}
A.core = mix(A.backlight, WHITE, 0.38)
A.glow = faded(A.backlight, 170)
A.dimLabel = mix(A.backlight, WHITE, 0.2, 179)
A.needleGlow = faded(A.needle, 70)
-- the content's box in the design (the 1000 x 460 artboard): centred at the bottom of the screen
A.left, A.right, A.top, A.bottom = 88, 915, 30, 411

local function drawDial(centreX, centreY, bezelRadius)
	local x, y = place(centreX, centreY)
	disc(x, y, bezelRadius + 6, A.bezel)
	disc(x, y, bezelRadius + 3, A.trim)
	band(x, y, bezelRadius, bezelRadius + 3, -80, 10, A.trimLight)
	disc(x, y, bezelRadius, A.wall)
	disc(x, y, bezelRadius - 8, A.face)
	band(x, y, bezelRadius - 16, bezelRadius - 8, 0, 360, Color(0, 0, 0, 90), 8)
end

-- ticks, numbers and red zone of one dial: `gauge` as in the design's geom()
local function drawScale(gauge)
	local x, y = place(gauge.cx, gauge.cy)
	local faceRadius = gauge.bezel - 8
	local outer = faceRadius - 6
	local function angleOf(value) return -gauge.sweep / 2 + value / gauge.max * gauge.sweep end
	if gauge.redFrom then band(x, y, outer - 3.5, outer, angleOf(gauge.redFrom), angleOf(gauge.redTo), A.red) end
	local count = math.Round(gauge.max / gauge.minor)
	for i = 0, count do
		local value = i * gauge.minor
		local angle = angleOf(value)
		local isMajor = abs(value / gauge.major - math.Round(value / gauge.major)) < 1e-6
		local isHalf = not isMajor and abs(value / gauge.half - math.Round(value / gauge.half)) < 1e-6
		local length = faceRadius * (isMajor and 0.12 or (isHalf and 0.075 or 0.045))
		local x0, y0 = polar(x, y, outer - length, angle)
		local x1, y1 = polar(x, y, outer, angle)
		local width = (isMajor and 2.4 or (isHalf and 1.5 or 1)) * pixel
		line(x0, y0, x1, y1, width * 2.2, faded(A.backlight, 50))
		line(x0, y0, x1, y1, width, isMajor and A.core or faded(A.core, isHalf and 255 or 190))
		if isMajor then
			local inRed = gauge.redFrom and value >= gauge.redFrom - 1e-9 and value <= gauge.redTo + 1e-9
			local numberX, numberY = polar(x, y, faceRadius * gauge.numberRadius, angle)
			numberX, numberY = floor(numberX + 0.5), floor(numberY + 0.5)
			local label = gauge.label(value)
			draw.SimpleText(label, "AudioHud_" .. gauge.font .. "_Glow", numberX, numberY, inRed and Color(255, 42, 26, 170) or A.glow, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			draw.SimpleText(label, "AudioHud_" .. gauge.font, numberX, numberY, inRed and A.redNumber or A.core, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
	end
end

local function drawNeedle(centreX, centreY, length, tail, halfWidth, degrees, capRadius)
	local x, y = place(centreX, centreY)
	local tipX, tipY = polar(x, y, length, degrees)
	local tailX, tailY = polar(x, y, tail, degrees + 180)
	-- a thin wedge: wide at the tail, a point at the tip
	local sideX, sideY = cos(rad(degrees)) * halfWidth * pixel, sin(rad(degrees)) * halfWidth * pixel
	local tipSideX, tipSideY = cos(rad(degrees)) * 0.6 * pixel, sin(rad(degrees)) * 0.6 * pixel
	line(tailX, tailY, tipX, tipY, halfWidth * 4 * pixel, A.needleGlow)
	local list = points(4)
	list[1].x, list[1].y = tailX - sideX, tailY - sideY
	list[2].x, list[2].y = tailX + sideX, tailY + sideY
	list[3].x, list[3].y = tipX + tipSideX, tipY + tipSideY
	list[4].x, list[4].y = tipX - tipSideX, tipY - tipSideY
	fillPoly(list, 4, A.needle)
	disc(x + 1.5 * pixel, y + 3 * pixel, capRadius, Color(0, 0, 0, 150))
	disc(x, y, capRadius, A.cap)
	disc(x - capRadius * 0.15 * pixel, y - capRadius * 0.2 * pixel, capRadius * 0.55, A.capLight)
	disc(x, y, capRadius * 0.45, A.cap)
end

local function lampColor(on, color, offColor) return on and color or (offColor or A.off) end

local function drawClassic(info)
	local tach = { cx = 219, cy = 230, bezel = 125, sweep = 270, max = info.dialRpm, major = info.majorRpm, half = info.majorRpm / 2,
		minor = info.majorRpm / 4, redFrom = info.redline, redTo = info.dialRpm, numberRadius = 0.70, font = "A_Tach",
		label = function(value) return string.format("%d", value / 1000) end }
	local speedo = { cx = 529, cy = 220, bezel = 165, sweep = 270, max = info.dialSpeed, major = info.speedMajor, half = info.speedMajor / 2,
		minor = info.speedMajor / 4, numberRadius = 0.71, font = "A_Speed", label = function(value) return string.format("%d", value) end }
	local fuelGauge = { cx = 814, cy = 240, bezel = 95, sweep = 120, max = 1, major = 0.5, half = 0.25, minor = 0.125, redFrom = 0, redTo = 0.125,
		numberRadius = 0.58, font = "A_Fuel", label = function(value) return value == 0 and "E" or (value == 1 and "F" or "½") end }
	for _, gauge in ipairs({ tach, speedo, fuelGauge }) do
		drawDial(gauge.cx, gauge.cy, gauge.bezel)
		drawScale(gauge)
	end

	-- shift light, gear, labels
	local shiftOn = info.share > 0.92
	local shiftX, shiftY = place(219, 186)
	disc(shiftX, shiftY, 5.5, A.cap)
	disc(shiftX, shiftY, 4, shiftOn and A.redLamp or rgb("1f1210"))
	text("RPM × 1000", "A_Label", 219, 254, A.dimLabel, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
	rectangle(201, 268, 36, 38, rgb("040404"))
	outline(201, 268, 36, 38, rgb("1f2022"))
	text(info.gear, "A_Gear", 219, 287, A.core, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, A.glow)
	text(info.unitLabel, "A_Unit", 529, 174, A.dimLabel, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)

	-- lamps
	ICONS.headlights(507, 282, 24, lampColor(info.headlights, A.green))
	ICONS.handbrake(551, 282, 26, lampColor(info.handbrake, A.redLamp))
	ICONS.fuel(814, 282, 19, lampColor(info.lowFuel, A.amber))
	if info.left then indicatorGlow(395, 82, 15, A.green) end
	ICONS.arrowA(395, 82, 27, lampColor(info.left, A.green), true)
	if info.right then indicatorGlow(663, 82, 15, A.green) end
	ICONS.arrowA(663, 82, 27, lampColor(info.right, A.green), false)

	-- needles over everything
	drawNeedle(219, 230, 102, 20, 2.2, -135 + clamp(info.rpm, 0, info.dialRpm) / info.dialRpm * 270, 11)
	drawNeedle(529, 220, 140, 26, 2.6, -135 + clamp(info.speed, 0, info.dialSpeed) / info.dialSpeed * 270, 14)
	drawNeedle(814, 240, 72, 15, 1.9, -60 + clamp(info.fuelShown, 0, 1) * 120, 9)
end

-- A2: the siren tones (WAIL / YELP / PHASER), the light modes (CODE 2 / CODE 3) and the bar's flashes
local POLICE_RED, POLICE_BLUE, SIREN_AMBER = rgb("ff3b30"), rgb("3d8bff"), rgb("ffb53a")

local BUTTON_HEIGHT = 30
local function drawButton(x, y, width, label, active, lit, color)
	rectangle(x, y, width, BUTTON_HEIGHT, lit and mix(color, BLACK, 0.72) or rgb("0b0c0d"))
	outline(x, y, width, BUTTON_HEIGHT, lit and mix(color, BLACK, 0.3) or (active and mix(color, BLACK, 0.55) or BLACK))
	text(label, "A_Button", x + width / 2, y + BUTTON_HEIGHT / 2, lit and mix(color, WHITE, 0.45) or (active and mix(color, BLACK, 0.25) or rgb("8a8c90")),
		TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end

-- the siren tones over the rev counter, the light modes over the fuel gauge: just the buttons
local SIREN_BUTTONS = { { "WAIL", SIREN_AMBER }, { "YELP", SIREN_AMBER }, { "PHASER", POLICE_RED } }
local SIREN_BUTTON_WIDTH, LIGHT_BUTTON_WIDTH, BUTTON_GAP = 80, 100, 6

local function drawPolicePanel(vehicle)
	local lightMode = vehicle:GetNW2Int("audio_lights", 0)
	-- the tone, from whoever answers the engine's lights-label hook (the siren module: its tone name, PHASER while the horn plays it)
	local tone = hook.Run("audio_engine/lights-label", vehicle)
	tone = isstring(tone) and string.upper(tone) or ""
	for index, button in ipairs(SIREN_BUTTONS) do
		local on = tone == button[1]
		drawButton(100 + (index - 1) * (SIREN_BUTTON_WIDTH + BUTTON_GAP), 50, SIREN_BUTTON_WIDTH, button[1], on, on, button[2])
	end

	-- the light mode's button flashes with the car's own lights (cl_police: either side lit)
	local flashing = AudioEngine.PoliceSideLit and (AudioEngine.PoliceSideLit(vehicle, -1) or AudioEngine.PoliceSideLit(vehicle, 1)) or lightMode > 0
	drawButton(712, 50, LIGHT_BUTTON_WIDTH, "CODE 2", lightMode == 1, lightMode == 1 and flashing, POLICE_BLUE)
	drawButton(712 + LIGHT_BUTTON_WIDTH + BUTTON_GAP, 50, LIGHT_BUTTON_WIDTH, "CODE 3", lightMode == 2, lightMode == 2 and flashing, POLICE_RED)
end

---------------------------------------------------------------------------
-- B: floating arc
---------------------------------------------------------------------------
local B = {
	accent = rgb("ffb21a"), red = rgb("ff3b30"), redNumber = rgb("ff5a4f"), green = rgb("4ade80"), blue = rgb("37a8ff"),
	track = Color(255, 255, 255, 41), redTrack = Color(255, 59, 48, 115), tick = Color(255, 255, 255, 140),
	number = Color(255, 255, 255, 204), soft = Color(255, 255, 255, 199), off = Color(255, 255, 255, 36),
}
-- in the 400 x 400 dial box (the indicators reach out to -14 and 414)
B.left, B.right, B.top, B.bottom = -31, 431, 6, 370

local function drawArc(info)
	local x, y = place(200, 200)
	local function angleOf(rpm) return -135 + clamp(rpm, 0, info.dialRpm) / info.dialRpm * 270 end
	local limiterBlink = info.limiter and RealTime() % 0.14 < 0.07
	band(x, y, 154, 166, -135, 135, B.track)
	band(x, y, 154, 166, angleOf(info.redline), 135, B.redTrack)
	local fill = info.rpm > info.redline and B.red or (info.share > 0.827 and B.accent or WHITE)
	band(x, y, 154, 166, -135, angleOf(info.rpm), fill)
	for rpm = 0, info.dialRpm, info.majorRpm do
		local angle = angleOf(rpm)
		local x0, y0 = polar(x, y, 170, angle)
		local x1, y1 = polar(x, y, 178, angle)
		line(x0, y0, x1, y1, 2 * pixel, B.tick)
		local numberX, numberY = polar(x, y, 194, angle)
		local label = string.format("%d", rpm / 1000)
		draw.SimpleText(label, "AudioHud_B_Num", numberX + pixel, numberY + pixel, Color(0, 0, 0, 150), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		draw.SimpleText(label, "AudioHud_B_Num", numberX, numberY, rpm >= info.redline and B.redNumber or B.number, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end
	local needleAngle = angleOf(info.rpm)
	local x0, y0 = polar(x, y, 146, needleAngle)
	local x1, y1 = polar(x, y, 174, needleAngle)
	line(x0, y0, x1, y1, 4 * pixel, WHITE)

	-- fuel: four quarters, gaps between
	local fuelColor = info.lowFuel and B.accent or WHITE
	for quarter = 0, 3 do
		local from, to = -150 + quarter * 11.25 + (quarter > 0 and 0.6 or 0), -150 + (quarter + 1) * 11.25 - (quarter < 3 and 0.6 or 0)
		band(x, y, 133.5, 138.5, from, to, B.track)
		local filledTo = min(to, -150 + info.fuelShown * 45)
		if filledTo > from then band(x, y, 133.5, 138.5, from, filledTo, fuelColor) end
	end
	local eX, eY = polar(x, y, 118, -152)
	local fX, fY = polar(x, y, 118, -103)
	draw.SimpleText("E", "AudioHud_B_Small", eX, eY, B.soft, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	draw.SimpleText("F", "AudioHud_B_Small", fX, fY, B.soft, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	ICONS.fuel(158, 340, 18, info.lowFuel and B.accent or B.off, 2.2)

	-- shift lights
	local lit = clamp(floor((info.share - 0.8) / 0.0667) + 1, 0, 5)
	for i = 0, 4 do
		local color = (i < 2 and B.green) or (i < 4 and B.accent) or B.red
		if limiterBlink then color = B.blue elseif i >= lit then color = Color(255, 255, 255, 41) end
		leaningBox(200 - (5 * 22 + 4 * 6) / 2 + i * 28, 112, 22, 6, 20, color)
	end

	textShadowed(tostring(info.speedDigits), "B_Speed", 200, 132, WHITE, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
	local unitText, rpmText = info.unitLabel, info.rpmDigits .. " RPM"
	local unitWidth, rpmWidth = textWidth(unitText, "B_Unit"), textWidth(rpmText, "B_Rpm")
	local rowLeft = 200 - (unitWidth + 14 + rpmWidth) / 2
	textShadowed(unitText, "B_Unit", rowLeft, 250, B.soft, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
	textShadowed(rpmText, "B_Rpm", rowLeft + unitWidth + 14, 250, B.soft, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
	textShadowed(info.gear, "B_Gear", 200, 292, B.accent, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)

	ICONS.headlights(262, 314, 24, info.headlights and B.green or B.off, 2.4)
	ICONS.handbrake(280, 344, 26, info.handbrake and B.red or B.off, 2.2)
	if info.left then indicatorGlow(-14, 36, 17, B.green) end
	ICONS.chevrons(-14, 36, 34, info.left and B.green or B.off, true)
	if info.right then indicatorGlow(414, 36, 17, B.green) end
	ICONS.chevrons(414, 36, 34, info.right and B.green or B.off, false)
end

---------------------------------------------------------------------------
-- C: motorsport strip
---------------------------------------------------------------------------
local C = {
	accent = rgb("ffb21a"), red = rgb("ff3b30"), redNumber = rgb("ff5a4f"), green = rgb("4ade80"), blue = rgb("37a8ff"),
	light = rgb("eef0f2"), unlit = Color(255, 255, 255, 33), label = Color(255, 255, 255, 184), scale = Color(255, 255, 255, 191),
	off = Color(255, 255, 255, 36),
}
local C_SEGMENTS = 36
-- the 680 px column (the indicators reach out to -35 and 715)
C.left, C.right, C.top, C.bottom = -37, 717, 0, 293

local function drawStrip(info)
	local limiterBlink = info.limiter and RealTime() % 0.14 < 0.07
	-- scale
	for rpm = 0, info.dialRpm, info.majorRpm do
		local x = rpm == 0 and 7 or min(673, rpm / info.dialRpm * C_SEGMENTS * 19 - 2)
		textShadowed(string.format("%d", rpm / 1000), "C_Scale", x, 0, rpm >= info.redline and C.redNumber or C.scale, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
	end
	-- segments, rising to the right, bottoms in line at y 86
	for i = 0, C_SEGMENTS - 1 do
		local value = (i + 1) * info.dialRpm / C_SEGMENTS
		local on = info.rpm >= value - info.dialRpm / C_SEGMENTS / 2
		local color = value <= info.redline * 0.8 and C.light or (value <= info.redline and C.accent or C.red)
		local height = floor(16 + i * (34 / 35) + 0.5)
		leaningBox(i * 19, 86 - height, 15, height, 14, on and (limiterBlink and C.blue or color) or C.unlit)
	end
	if info.left then indicatorGlow(-24, 61, 15, C.green) end
	ICONS.arrowhead(-24, 61, 22, info.left and C.green or C.off, true)
	if info.right then indicatorGlow(704, 61, 15, C.green) end
	ICONS.arrowhead(704, 61, 22, info.right and C.green or C.off, false)

	-- read-outs: bottoms on y 248
	local baseline = 248
	textShadowed("SPEED", "C_Label", 0, 114, C.label, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
	local speedText = tostring(info.speedDigits)
	textShadowed(speedText, "C_Speed", 0, baseline, WHITE, TEXT_ALIGN_LEFT, TEXT_ALIGN_BOTTOM)
	textShadowed(info.usesMph and "mph" or "km/h", "C_Unit", textWidth(speedText, "C_Speed") + 8, baseline - 8, C.label, TEXT_ALIGN_LEFT, TEXT_ALIGN_BOTTOM)
	textShadowed("GEAR", "C_Label", 340, 114, C.label, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
	textShadowed(info.gear, "C_Gear", 340, 128, limiterBlink and C.blue or C.accent, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
	textShadowed("ENGINE", "C_Label", 680, 114, C.label, TEXT_ALIGN_RIGHT, TEXT_ALIGN_TOP)
	local unitWidth = textWidth("rpm", "C_Unit")
	textShadowed("rpm", "C_Unit", 680, baseline - 6, C.label, TEXT_ALIGN_RIGHT, TEXT_ALIGN_BOTTOM)
	textShadowed(info.rpmDigits, "C_Rpm", 680 - unitWidth - 8, baseline, WHITE, TEXT_ALIGN_RIGHT, TEXT_ALIGN_BOTTOM)

	-- fuel and lamps
	local rowY = 282
	ICONS.fuel(10, rowY, 20, info.lowFuel and C.accent or C.off, 2.2)
	textShadowed("E", "C_Label", 30, rowY, C.label, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	for segment = 0, 9 do
		local lit = info.fuelShown >= (segment + 0.5) / 10 or (segment == 0 and info.fuelShown > 0.02)
		leaningBox(48 + segment * 16, rowY - 5, 13, 10, 14, lit and (info.lowFuel and C.accent or C.light) or C.unlit)
	end
	textShadowed("F", "C_Label", 212, rowY, C.label, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	ICONS.headlights(623, rowY, 26, info.headlights and C.green or C.off, 2.4)
	ICONS.handbrake(666, rowY, 28, info.handbrake and C.red or C.off, 2.2)
end

---------------------------------------------------------------------------
-- HUD
---------------------------------------------------------------------------
-- smoothRevs: the cluster shows the revs as a bar / segments (smoothRpmValue), not a needle
local CLUSTERS = {
	a = { box = A, draw = drawClassic, fonts = "A" },
	a2 = { box = A, draw = drawClassic, fonts = "A", police = true },
	b = { box = B, draw = drawArc, fonts = "B", smoothRevs = true },
	c = { box = C, draw = drawStrip, fonts = "C", smoothRevs = true },
}

local function isPoliceCar(vehicle)
	return vehicle:GetNW2String("audio_lightscheme", "") == "police" and IsValid(vehicle:GetNW2Entity("audio_lightbar"))
end

-- audio_engine_cluster's numbers -> the design's clusters
local CLUSTER_NUMBERS = { "a", "b", "c", "a2" }

local function clusterFor(vehicle)
	local wanted = CLUSTER_NUMBERS[clusterConVar:GetInt()]
	-- 0 (or anything else): the police one in a police car, else the classic
	if not wanted or wanted == "a2" then return isPoliceCar(vehicle) and "a2" or "a" end
	return wanted
end

local statusFontScale
local function statusFont(scale)
	if statusFontScale == scale then return end
	statusFontScale = scale
	surface.CreateFont("AudioHud_Status", { font = "Roboto Condensed", size = max(MIN_FONT, floor(24 * scale)), weight = 700, antialias = true, extended = true })
end

hook.Add("HUDPaint", "audio_engine_hud", function()
	if not hudConVar:GetBool() then return end
	local player = LocalPlayer()
	if not IsValid(player) then return end
	local vehicle = player:GetVehicle()
	if not IsValid(vehicle) then return end
	local car = AudioEngine.GetClientCar and AudioEngine.GetClientCar(vehicle)
	if not car then return end

	local info = readState(player, vehicle, car, RealFrameTime())
	local clusterId = clusterFor(vehicle)
	local cluster = CLUSTERS[clusterId]
	local box = cluster.box
	if cluster.smoothRevs then
		info.rpm, info.rpmDigits = info.rpmSmooth, info.rpmSmoothDigits
		info.share = info.rpm / info.redline
	end
	local screenScale = ScrH() / 1080 * scaleConVar:GetFloat()
	pixel = screenScale * CLUSTER_SIZE[clusterId]
	fontsFor(cluster.fonts .. "_", pixel)
	-- the content centred at the bottom of the screen
	originX = ScrW() / 2 - (box.left + box.right) / 2 * pixel
	originY = ScrH() - BOTTOM_MARGIN * screenScale - box.bottom * pixel
	draw.NoTexture()
	cluster.draw(info)
	if cluster.police then drawPolicePanel(vehicle) end

	-- status above the cluster: the ignition prompt, the speed limiter, the light mode
	statusFont(screenScale)
	local _, topY = place(0, box.top)
	topY = topY - 10 * screenScale
	local leftX = place(box.left, 0)
	local rightX = place(box.right, 0)
	local engineState = car.engineState
	if not engineState.on or engineState.phase ~= "run" then
		local message
		if not engineState.on then
			local startKeyConVar = GetConVar("audio_engine_startkey")
			local key = string.upper(startKeyConVar and startKeyConVar:GetString() or "R")
			message = (key == "" or key == "NONE") and "Engine off · audio_engine_toggle starts it" or ("Engine off · press " .. key .. " to start")
		else
			message = "Starting…"
		end
		draw.SimpleText(message, "AudioHud_Status", ScrW() / 2, topY, engineState.on and SIREN_AMBER or WHITE, TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM)
	end
	-- speed limiter (sv_cruise.lua): the limit, in the HUD's units
	local speedLimit = vehicle:GetNW2Float("audio_cruise", 0)
	if speedLimit > 0 and engineState.on and engineState.phase == "run" then
		local limitText = info.usesMph and string.format("LIMIT %d mph", floor(speedLimit + 0.5)) or string.format("LIMIT %d km/h", floor(speedLimit * 1.609344 + 0.5))
		draw.SimpleText(limitText, "AudioHud_Status", rightX, topY, B.green, TEXT_ALIGN_RIGHT, TEXT_ALIGN_BOTTOM)
	end
	-- police lights (sv_police.lua), with the word other addons add through audio_engine/lights-label
	-- (the siren's tone); A2 shows them on its own panel
	local lightLabel = AudioEngine.LIGHT_MODES[vehicle:GetNW2Int("audio_lights", 0)]
	if not cluster.police and lightLabel and IsValid(vehicle:GetNW2Entity("audio_lightbar")) then
		local extra = hook.Run("audio_engine/lights-label", vehicle)
		if isstring(extra) and extra ~= "" then lightLabel = lightLabel .. " · " .. extra end
		draw.SimpleText(lightLabel, "AudioHud_Status", leftX, topY, RealTime() % 0.5 < 0.25 and POLICE_RED or WHITE, TEXT_ALIGN_LEFT, TEXT_ALIGN_BOTTOM)
	end
end)

hook.Add("OnScreenSizeChanged", "audio_engine_hud", function() fontScales, statusFontScale = {}, nil end)
