--[[
	Audio Engine - driver HUD (client): the instrument cluster, centred at the bottom of the screen,
	no panel behind it. Seven looks, picked with audio_engine_cluster (not saved: every load starts
	on 0; the numbers are the user's order):
	  0   automatic (the default): the classic
	  1   classic (design A): rev counter, speedometer and fuel gauge as dials with needles
	  2   modern digital (D): two lit dials, speed and gear in their middles, a centre panel
	  3   German hatch (A5): twin chrome-ringed dials, a red LCD between them
	  4   60s vintage (A3): cream faces, chrome rims, jewel lamps
	  5   80s digital (A4): a VFD rev arc of blocks, seven-segment speed and gear
	  6   floating arc (B): one rev arc with the speed and gear in its middle
	  7   motorsport strip (C): a bar of rev segments over speed / gear / rpm read-outs
	In a police car (scheme "police" with a light bar) the ones with emergency-light controls show
	them: the classic turns into A2 (its police look, siren tones and CODE 2 / CODE 3 buttons), D
	shows LIGHTS / SIREN in its centre panel, A5 buttons under its LCD.
	Drawn after the "Speedometer HUD" design canvas (artboards A, A2, A3, A4, A5, B, C, D): the
	positions and sizes below are that design's pixels, scaled to the screen.

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
	"Instrument cluster: 0 automatic (the classic), 1 classic, 2 modern digital, 3 German hatch, 4 60s vintage, 5 80s digital, 6 floating arc, 7 motorsport strip. Police cars get the light/siren controls on 1-3. Not saved")

local cos, sin, rad, min, max, floor, abs, clamp = math.cos, math.sin, math.rad, math.min, math.max, math.floor, math.abs, math.Clamp

-- the design's size of each cluster x this x (screen height / 1080) x audio_engine_hud_scale
local CLUSTER_SIZE = { a = 0.7, d = 0.7, a5 = 0.7, a3 = 0.7, a4 = 0.6, b = 0.75, c = 0.65 }   -- (A4 smaller: the user's)
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
-- fonts (made again when the size changes). Roboto Condensed and Roboto ship with the game; the
-- design's Barlow / Chakra Petch / Oswald / Inter Tight would be a download for every player.
-- Dial numbers are a few px over the design's (the user found the design's small in game)
---------------------------------------------------------------------------
local FONTS = {
	-- name = { design px, weight, italic, glow (blur px), face (default Roboto Condensed) }
	A_Tach = { 25, 500, false, 3 }, A_Speed = { 25, 500, false, 3 }, A_Fuel = { 21, 500, false, 3 },
	A_Label = { 12, 600 }, A_Unit = { 15, 600 }, A_Gear = { 27, 600, false, 3 }, A_Button = { 16, 700 },
	B_Num = { 17, 600, true }, B_Small = { 13, 600, true }, B_Speed = { 118, 700, true }, B_Unit = { 18, 600 },
	B_Rpm = { 18, 500 }, B_Gear = { 76, 700, true },
	C_Scale = { 14, 600 }, C_Label = { 13, 600 }, C_Speed = { 84, 700, true }, C_Gear = { 140, 700, true },
	C_Rpm = { 44, 600, true }, C_Unit = { 18, 600 },
	-- D: modern digital (Roboto for the design's Inter Tight)
	D_Num = { 21, 500, false, nil, "Roboto" }, D_Speed = { 84, 500, false, nil, "Roboto" }, D_Gear = { 84, 600, false, 8, "Roboto" },
	D_Unit = { 15, 500, false, nil, "Roboto" }, D_Small = { 13, 500, false, nil, "Roboto" }, D_Tiny = { 11, 600, false, nil, "Roboto" },
	D_Mode = { 20, 600, false, nil, "Roboto" },
	-- A5 (G): German hatch
	G_Speed = { 24, 500, false, 4 }, G_Tach = { 26, 500, false, 4 }, G_Unit = { 13, 500, false, 3 }, G_Small = { 11, 500, false, 3 },
	G_LcdSmall = { 13, 400, false, 3 }, G_LcdGear = { 60, 600, false, 3 }, G_LcdSpeed = { 17, 500, false, 3 }, G_Button = { 13, 600 },
	-- A3 (V): 60s vintage
	V_Tach = { 25, 500 }, V_Speed = { 26, 500 }, V_Fuel = { 21, 500 }, V_Label = { 11, 400 }, V_Unit = { 12, 400 }, V_Gear = { 20, 500 },
	-- A4 (F): 80s digital (VFD)
	F_Scale = { 21, 400, false, 3 }, F_Label = { 11, 400 }, F_Unit = { 16, 400, false, 3 }, F_Fuel = { 13, 400 },
}
local fontScales = {}
local function fontsFor(prefix, scale)
	if fontScales[prefix] == scale then return end
	fontScales[prefix] = scale
	for name, spec in pairs(FONTS) do
		if name:sub(1, #prefix) == prefix then
			local size = max(MIN_FONT, floor(spec[1] * scale + 0.5))
			local face = spec[5] or "Roboto Condensed"
			surface.CreateFont("AudioHud_" .. name, { font = face, size = size, weight = spec[2], italic = spec[3] or false, antialias = true, extended = true })
			if spec[4] then
				surface.CreateFont("AudioHud_" .. name .. "_Glow", { font = face, size = size, weight = spec[2], italic = spec[3] or false,
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
local function disc(centreX, centreY, radius, color, segments)
	segments = segments or CIRCLE_SEGMENTS
	local list = points(segments)
	for i = 1, segments do list[i].x, list[i].y = polar(centreX, centreY, radius, (i - 1) / segments * 360) end
	fillPoly(list, segments, color)
end

-- a needle-like wedge from a centre (screen px): `fromRadius` (negative = the tail behind the
-- centre) `fromHalfWidth` wide out to `toRadius` `toHalfWidth` wide, design px, at a gauge angle
local function wedge(x, y, fromRadius, fromHalfWidth, toRadius, toHalfWidth, degrees, color)
	local angle = rad(degrees)
	local alongX, alongY = sin(angle) * pixel, -cos(angle) * pixel
	local sideX, sideY = cos(angle) * pixel, sin(angle) * pixel
	local list = points(4)
	list[1].x, list[1].y = x + alongX * fromRadius - sideX * fromHalfWidth, y + alongY * fromRadius - sideY * fromHalfWidth
	list[2].x, list[2].y = x + alongX * fromRadius + sideX * fromHalfWidth, y + alongY * fromRadius + sideY * fromHalfWidth
	list[3].x, list[3].y = x + alongX * toRadius + sideX * toHalfWidth, y + alongY * toRadius + sideY * toHalfWidth
	list[4].x, list[4].y = x + alongX * toRadius - sideX * toHalfWidth, y + alongY * toRadius - sideY * toHalfWidth
	fillPoly(list, 4, color)
end

-- a box centred on x, y (design px) turned `degrees` clockwise (CSS rotate)
local function rotatedBox(centreX, centreY, width, height, degrees, color)
	local x, y = place(centreX, centreY)
	local angle = rad(degrees)
	local acrossX, acrossY = cos(angle) * width * 0.5 * pixel, sin(angle) * width * 0.5 * pixel
	local downX, downY = -sin(angle) * height * 0.5 * pixel, cos(angle) * height * 0.5 * pixel
	local list = points(4)
	list[1].x, list[1].y = x - acrossX - downX, y - acrossY - downY
	list[2].x, list[2].y = x + acrossX - downX, y + acrossY - downY
	list[3].x, list[3].y = x + acrossX + downX, y + acrossY + downY
	list[4].x, list[4].y = x - acrossX + downX, y - acrossY + downY
	fillPoly(list, 4, color)
end

-- the top half of an ellipse standing on its chord (design px)
local ELLIPSE_POINTS = 40
local function halfEllipse(centreX, centreY, radiusX, radiusY, color)
	local list = points(ELLIPSE_POINTS)
	for i = 1, ELLIPSE_POINTS do
		local angle = math.pi * (i - 1) / (ELLIPSE_POINTS - 1)
		list[i].x, list[i].y = place(centreX - radiusX * cos(angle), centreY - radiusY * sin(angle))
	end
	fillPoly(list, ELLIPSE_POINTS, color)
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

--[[
	A seven-segment digit (the 80s cluster), x, y = its top left, leaning like the design's
	skewX(-8deg) about its middle. Lit segments get a soft halo.
]]
local SEVEN_SEGMENTS = {
	["0"] = "abcdef", ["1"] = "bc", ["2"] = "abged", ["3"] = "abgcd", ["4"] = "fgbc", ["5"] = "afgcd", ["6"] = "afgedc",
	["7"] = "abc", ["8"] = "abcdefg", ["9"] = "abcdfg", N = "ceg", R = "eg", ["-"] = "g",
}
local SEGMENT_NAMES = { "a", "b", "c", "d", "e", "f", "g" }
local SEVEN_LEAN = math.tan(rad(8))

-- a segment's box inside the digit (the design's seven())
local function segmentBox(name, width, height, thickness)
	local half = height / 2 - 0.9 * thickness
	if name == "a" then return 0.6 * thickness, 0, width - 1.2 * thickness, thickness end
	if name == "b" then return width - thickness, 0.6 * thickness, thickness, half end
	if name == "c" then return width - thickness, height / 2 + 0.3 * thickness, thickness, half end
	if name == "d" then return 0.6 * thickness, height - thickness, width - 1.2 * thickness, thickness end
	if name == "e" then return 0, height / 2 + 0.3 * thickness, thickness, half end
	if name == "f" then return 0, 0.6 * thickness, thickness, half end
	return 0.6 * thickness, height / 2 - thickness / 2, width - 1.2 * thickness, thickness
end

local function leanedQuad(digitX, digitY, digitHeight, left, top, width, height, color)
	local middle = digitY + digitHeight / 2
	local list = points(4)
	local x0, x1, y0, y1 = digitX + left, digitX + left + width, digitY + top, digitY + top + height
	list[1].x, list[1].y = place(x0 - SEVEN_LEAN * (y0 - middle), y0)
	list[2].x, list[2].y = place(x1 - SEVEN_LEAN * (y0 - middle), y0)
	list[3].x, list[3].y = place(x1 - SEVEN_LEAN * (y1 - middle), y1)
	list[4].x, list[4].y = place(x0 - SEVEN_LEAN * (y1 - middle), y1)
	fillPoly(list, 4, color)
end

local function sevenSegment(x, y, width, height, thickness, character, onColor, offColor)
	local lit = SEVEN_SEGMENTS[character] or ""
	local halo = faded(onColor, 45)
	for _, name in ipairs(SEGMENT_NAMES) do
		local left, top, segmentWidth, segmentHeight = segmentBox(name, width, height, thickness)
		if lit:find(name, 1, true) then
			leanedQuad(x, y, height, left - 2, top - 2, segmentWidth + 4, segmentHeight + 4, halo)
			leanedQuad(x, y, height, left, top, segmentWidth, segmentHeight, onColor)
		else
			leanedQuad(x, y, height, left, top, segmentWidth, segmentHeight, offColor)
		end
	end
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
-- a stroked path with round joints (opaque colours only: a see-through one would show the overlaps)
local function iconPath(width, color, ...)
	iconLine(width, color, ...)
	if color.a < 255 then return end
	local coordinates = { ... }
	for i = 1, #coordinates / 2 do
		local x, y = iconPoint(coordinates[i * 2 - 1], coordinates[i * 2])
		local savedPixel = pixel
		pixel = iconScale
		disc(x, y, width * 0.5, color, 10)
		pixel = savedPixel
	end
end
-- the check-engine lamp (the design's 32 x 22 outline of an engine)
function ICONS.engine(x, y, width, color, stroke)
	stroke = stroke or 2
	iconStart(x, y, width, 32, 22)
	iconPath(stroke, color, 12, 3, 18, 3)
	iconPath(stroke, color, 15, 3, 15, 6)
	iconPath(stroke, color, 7, 6, 21, 6, 23, 9, 26, 9, 26, 7, 29, 7, 29, 18, 26, 18, 26, 16, 23, 16, 20, 19, 10, 19, 7, 16, 7, 6)
	iconPath(stroke, color, 7, 9, 4, 9)
	iconPath(stroke, color, 4, 7, 4, 14)
	iconPath(stroke, color, 7, 13, 4, 13)
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
	headlights, fuel (0..1), handbrake, engine } for any other source. The check-engine lamp is lit
	while the engine isn't running (off, or still starting), as a real one is with the key on.
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
	hookLights.engine = not engineState.on or engineState.phase ~= "run"
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
	state.engine = hookLights.engine or false
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
A.redWidth, A.tickGlow = 3.5, 50
-- the content's box in the design (the 1000 x 460 artboard): centred at the bottom of the screen.
-- Every 1000 x 460 cluster (A, A3, A4, A5, D) uses it, so they all sit in the same place
A.left, A.right, A.top, A.bottom = 88, 915, 30, 411

-- A2: the classic in a police car (artboard A2): a hotter, flatter backlight, lighter trim
local A2 = setmetatable({
	backlight = rgb("ff5533"), needle = rgb("ff5a1e"), red = rgb("ff3b2a"), redNumber = rgb("ff5533"), off = rgb("3a3c3f"),
	trim = rgb("9a9da1"), trimLight = rgb("e4e6e8"), redWidth = 5, tickGlow = 16,
}, { __index = A })
A2.core = mix(A2.backlight, WHITE, 0.08)
A2.glow = faded(A2.backlight, 85)
A2.dimLabel = mix(A2.backlight, WHITE, 0.2, 179)
A2.needleGlow = faded(A2.needle, 70)

-- the palette the classic is being drawn with (A, or A2 in a police car)
local classic = A

local function drawDial(centreX, centreY, bezelRadius)
	local x, y = place(centreX, centreY)
	disc(x, y, bezelRadius + 6, classic.bezel)
	disc(x, y, bezelRadius + 3, classic.trim)
	band(x, y, bezelRadius, bezelRadius + 3, -80, 10, classic.trimLight)
	disc(x, y, bezelRadius, classic.wall)
	disc(x, y, bezelRadius - 8, classic.face)
	band(x, y, bezelRadius - 16, bezelRadius - 8, 0, 360, Color(0, 0, 0, 90), 8)
end

-- ticks, numbers and red zone of one dial: `gauge` as in the design's geom()
local function drawScale(gauge)
	local x, y = place(gauge.cx, gauge.cy)
	local faceRadius = gauge.bezel - 8
	local outer = faceRadius - 6
	local function angleOf(value) return -gauge.sweep / 2 + value / gauge.max * gauge.sweep end
	if gauge.redFrom then
		band(x, y, outer - 1.75 - classic.redWidth / 2, outer - 1.75 + classic.redWidth / 2, angleOf(gauge.redFrom), angleOf(gauge.redTo), classic.red)
	end
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
		line(x0, y0, x1, y1, width * 2.2, faded(classic.backlight, classic.tickGlow))
		line(x0, y0, x1, y1, width, isMajor and classic.core or faded(classic.core, isHalf and 255 or 190))
		if isMajor then
			local inRed = gauge.redFrom and value >= gauge.redFrom - 1e-9 and value <= gauge.redTo + 1e-9
			local numberX, numberY = polar(x, y, faceRadius * gauge.numberRadius, angle)
			numberX, numberY = floor(numberX + 0.5), floor(numberY + 0.5)
			local label = gauge.label(value)
			draw.SimpleText(label, "AudioHud_" .. gauge.font .. "_Glow", numberX, numberY, inRed and Color(255, 42, 26, 170) or classic.glow, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			draw.SimpleText(label, "AudioHud_" .. gauge.font, numberX, numberY, inRed and classic.redNumber or classic.core, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
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
	line(tailX, tailY, tipX, tipY, halfWidth * 4 * pixel, classic.needleGlow)
	local list = points(4)
	list[1].x, list[1].y = tailX - sideX, tailY - sideY
	list[2].x, list[2].y = tailX + sideX, tailY + sideY
	list[3].x, list[3].y = tipX + tipSideX, tipY + tipSideY
	list[4].x, list[4].y = tipX - tipSideX, tipY - tipSideY
	fillPoly(list, 4, classic.needle)
	disc(x + 1.5 * pixel, y + 3 * pixel, capRadius, Color(0, 0, 0, 150))
	disc(x, y, capRadius, classic.cap)
	disc(x - capRadius * 0.15 * pixel, y - capRadius * 0.2 * pixel, capRadius * 0.55, classic.capLight)
	disc(x, y, capRadius * 0.45, classic.cap)
end

local function lampColor(on, color, offColor) return on and color or (offColor or classic.off) end

local drawPolicePanel

local function drawClassic(info, vehicle, police)
	classic = police and A2 or A
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
	disc(shiftX, shiftY, 5.5, classic.cap)
	disc(shiftX, shiftY, 4, shiftOn and classic.redLamp or rgb("1f1210"))
	text("RPM × 1000", "A_Label", 219, 254, classic.dimLabel, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
	rectangle(201, 268, 36, 38, rgb("040404"))
	outline(201, 268, 36, 38, rgb("1f2022"))
	text(info.gear, "A_Gear", 219, 287, classic.core, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, classic.glow)
	text(info.unitLabel, "A_Unit", 529, 174, classic.dimLabel, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)

	-- lamps
	ICONS.headlights(489, 282, 24, lampColor(info.headlights, classic.green))
	ICONS.handbrake(529, 282, 26, lampColor(info.handbrake, classic.redLamp))
	ICONS.engine(569, 282, 26, lampColor(info.engine, classic.amber))
	ICONS.fuel(814, 282, 19, lampColor(info.lowFuel, classic.amber))
	if info.left then indicatorGlow(395, 82, 15, classic.green) end
	ICONS.arrowA(395, 82, 27, lampColor(info.left, classic.green), true)
	if info.right then indicatorGlow(663, 82, 15, classic.green) end
	ICONS.arrowA(663, 82, 27, lampColor(info.right, classic.green), false)

	-- needles over everything
	drawNeedle(219, 230, 102, 20, 2.2, -135 + clamp(info.rpm, 0, info.dialRpm) / info.dialRpm * 270, 11)
	drawNeedle(529, 220, 140, 26, 2.6, -135 + clamp(info.speed, 0, info.dialSpeed) / info.dialSpeed * 270, 14)
	drawNeedle(814, 240, 72, 15, 1.9, -60 + clamp(info.fuelShown, 0, 1) * 120, 9)
	if police then drawPolicePanel(vehicle) end
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

-- the tone, from whoever answers the engine's lights-label hook (the siren module: its tone name, PHASER while the horn plays it)
local function sirenTone(vehicle)
	local tone = hook.Run("audio_engine/lights-label", vehicle)
	return isstring(tone) and string.upper(tone) or ""
end

-- the car's lights flashing now (cl_police: either side lit; without it, any light mode)
local function lightsFlashing(vehicle, lightMode)
	if AudioEngine.PoliceSideLit then return AudioEngine.PoliceSideLit(vehicle, -1) or AudioEngine.PoliceSideLit(vehicle, 1) end
	return lightMode > 0
end

function drawPolicePanel(vehicle)
	local lightMode = vehicle:GetNW2Int("audio_lights", 0)
	local tone = sirenTone(vehicle)
	for index, button in ipairs(SIREN_BUTTONS) do
		local on = tone == button[1]
		drawButton(100 + (index - 1) * (SIREN_BUTTON_WIDTH + BUTTON_GAP), 50, SIREN_BUTTON_WIDTH, button[1], on, on, button[2])
	end

	-- the light mode's button flashes with the car's own lights (cl_police: either side lit)
	local flashing = lightsFlashing(vehicle, lightMode)
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
	ICONS.engine(300, 288, 26, info.engine and B.accent or B.off, 2.4)
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
	ICONS.headlights(577, rowY, 26, info.headlights and C.green or C.off, 2.4)
	ICONS.engine(621, rowY, 30, info.engine and C.accent or C.off, 2.2)
	ICONS.handbrake(666, rowY, 28, info.handbrake and C.red or C.off, 2.2)
end

---------------------------------------------------------------------------
-- D: modern digital (two lit dials, a centre panel: LIGHTS / SIREN in a police car, fuel)
---------------------------------------------------------------------------
local D = {
	accent = rgb("4cc3ff"), face = rgb("0e1013"), faceIn = rgb("1c1e21"), red = rgb("ff3b30"), redNumber = rgb("ff5a4f"),
	needleRed = rgb("ff6a5f"), green = rgb("4ade80"), amber = rgb("ffb21a"),
	policeRed = rgb("ff5147"), policeBlue = rgb("5aa8ff"), sirenAmber = rgb("ffb53a"),
	track = Color(255, 255, 255, 36), tick = Color(255, 255, 255, 115), major = Color(255, 255, 255, 217),
	number = Color(255, 255, 255, 179), soft = Color(255, 255, 255, 158), faint = Color(255, 255, 255, 128),
	label = Color(255, 255, 255, 140), off = Color(255, 255, 255, 41), grey = Color(255, 255, 255, 102),
	dotOff = Color(255, 255, 255, 46), divider = Color(255, 255, 255, 20), rim = Color(255, 255, 255, 25), innerRim = Color(255, 255, 255, 13),
}
local D_RADIUS = 160

-- one of D's dials: track, ticks and numbers, the lit arc to `value`, the needle
local function modernDial(centreX, max, major, value, fillColor, needleColor, redFrom, label)
	local x, y = place(centreX, 230)
	local function angleOf(dialValue) return -135 + clamp(dialValue, 0, max) / max * 270 end
	band(x, y, D_RADIUS - 1, D_RADIUS + 1, -135, 135, D.track)
	if redFrom then band(x, y, D_RADIUS - 1, D_RADIUS + 1, angleOf(redFrom), 135, Color(255, 59, 48, 178)) end
	for dialValue = 0, max, major / 2 do
		local angle = angleOf(dialValue)
		local isMajor = abs(dialValue / major - math.Round(dialValue / major)) < 1e-6
		local x0, y0 = polar(x, y, isMajor and D_RADIUS - 16 or D_RADIUS - 11, angle)
		local x1, y1 = polar(x, y, D_RADIUS - 6, angle)
		line(x0, y0, x1, y1, (isMajor and 2.2 or 1.3) * pixel, isMajor and D.major or D.tick)
		if isMajor then
			local numberX, numberY = polar(x, y, D_RADIUS - 34, angle)
			draw.SimpleText(label(dialValue), "AudioHud_D_Num", floor(numberX + 0.5), floor(numberY + 0.5),
				(redFrom and dialValue >= redFrom) and D.redNumber or D.number, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
	end
	local valueAngle = angleOf(value)
	band(x, y, D_RADIUS - 4.5, D_RADIUS + 4.5, -135, valueAngle, faded(fillColor, 60))
	band(x, y, D_RADIUS - 2.25, D_RADIUS + 2.25, -135, valueAngle, faded(fillColor, 217))
	local x0, y0 = polar(x, y, 140, valueAngle)
	local x1, y1 = polar(x, y, 170, valueAngle)
	line(x0, y0, x1, y1, 7 * pixel, faded(needleColor, 60))
	line(x0, y0, x1, y1, 3 * pixel, needleColor)
end

-- a LIGHTS / SIREN line of D's centre panel: label, dot, value
local function modernStatus(y, title, dotColor, value, valueColor)
	text(title, "D_Tiny", 430, y, D.label, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
	local dotX, dotY = place(433.5, y + 25)
	if dotColor ~= D.dotOff then disc(dotX, dotY, 7, faded(dotColor, 50), 16) end
	disc(dotX, dotY, 3.5, dotColor, 16)
	text(value, "D_Mode", 445, y + 25, valueColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
end

local function drawModern(info, vehicle, police)
	-- faces (a little see-through, like the design's 0.92) and the centre panel
	for _, centreX in ipairs({ 220, 780 }) do
		local x, y = place(centreX, 230)
		disc(x, y + 10 * pixel, 190, Color(0, 0, 0, 70))
		disc(x, y, 186, faded(D.face, 235))
		disc(x, y - 12 * pixel, 140, faded(D.faceIn, 70))
		band(x, y, 185, 186, 0, 360, D.rim, 6)
		band(x, y, 115.5, 116.5, 0, 360, D.innerRim, 6)
	end
	-- the centre panel: full height with LIGHTS / SIREN, else just round the fuel block (207.5..252.5)
	local panelTop, panelHeight = 147, 166
	if not police then panelTop, panelHeight = 192, 76 end
	local panelX, panelY = place(416, panelTop)
	draw.RoundedBox(max(1, floor(12 * pixel)), panelX, panelY + 10 * pixel, 168 * pixel, panelHeight * pixel, Color(0, 0, 0, 70))
	draw.RoundedBox(max(1, floor(12 * pixel)), panelX, panelY, 168 * pixel, panelHeight * pixel, faded(D.face, 235))
	draw.NoTexture()

	local revColor = info.rpm >= info.redline and D.red or D.accent
	modernDial(220, info.dialSpeed, info.speedMajor, info.speed, WHITE, WHITE, nil, function(value) return string.format("%d", value) end)
	modernDial(780, info.dialRpm, info.majorRpm, info.rpm, revColor, info.rpm >= info.redline and D.needleRed or WHITE, info.redline,
		function(value) return string.format("%d", value / 1000) end)

	-- read-outs in the dials
	textShadowed(tostring(info.speedDigits), "D_Speed", 220, 166, WHITE, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
	text(info.usesMph and "mph" or "km/h", "D_Unit", 220, 254, D.soft, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
	text(info.gear, "D_Gear", 780, 166, D.accent, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, faded(D.accent, 102))
	text(info.rpmDigits .. " rpm", "D_Unit", 780, 254, D.soft, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
	text("×1000 rpm", "D_Small", 780, 318, D.faint, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)

	if info.left then indicatorGlow(472, 120, 14, D.green) end
	ICONS.arrowA(472, 120, 28, info.left and D.green or D.off, true)
	if info.right then indicatorGlow(528, 120, 14, D.green) end
	ICONS.arrowA(528, 120, 28, info.right and D.green or D.off, false)

	-- the centre panel: LIGHTS / SIREN in a police car, then fuel
	local rowY = police and 158.5 or 207.5
	if police then
		local lightMode = vehicle:GetNW2Int("audio_lights", 0)
		local dotColor = D.dotOff
		if lightMode > 0 then
			-- red while the driver's side is lit, blue the passenger's (cl_police's timing)
			if AudioEngine.PoliceSideLit then
				dotColor = AudioEngine.PoliceSideLit(vehicle, -1) and D.policeRed or (AudioEngine.PoliceSideLit(vehicle, 1) and D.policeBlue or D.dotOff)
			else
				dotColor = RealTime() % 0.25 < 0.125 and D.policeRed or D.policeBlue
			end
		end
		local modeText = lightMode == 1 and "CODE 2" or (lightMode == 2 and "CODE 3" or "OFF")
		modernStatus(rowY, "LIGHTS", dotColor, modeText, lightMode == 1 and D.policeBlue or (lightMode == 2 and D.policeRed or D.grey))
		rowY = rowY + 42
		rectangle(430, rowY, 140, 1, D.divider)
		rowY = rowY + 7
		local tone = sirenTone(vehicle)
		local sounding = tone ~= ""
		modernStatus(rowY, "SIREN", sounding and D.sirenAmber or D.dotOff, sounding and tone or "OFF", sounding and D.sirenAmber or D.grey)
		rowY = rowY + 42
		rectangle(430, rowY, 140, 1, D.divider)
		rowY = rowY + 7
	end
	ICONS.fuel(438.5, rowY + 8.5, 17, info.lowFuel and D.amber or D.off, 2.2)
	text(string.format("%d%%", floor(info.fuelShown * 100 + 0.5)), "D_Small", 570, rowY + 8.5,
		info.lowFuel and D.amber or Color(255, 255, 255, 179), TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
	rectangle(430, rowY + 22, 140, 5, D.off)
	if info.fuelShown > 0.005 then rectangle(430, rowY + 22, 140 * clamp(info.fuelShown, 0, 1), 5, info.lowFuel and D.amber or WHITE) end
	text("E", "D_Tiny", 430, rowY + 32, D.faint, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
	text("F", "D_Tiny", 570, rowY + 32, D.faint, TEXT_ALIGN_RIGHT, TEXT_ALIGN_TOP)

	-- lamps under the panel
	ICONS.headlights(456.5, 336, 26, info.headlights and D.green or D.off, 2.4)
	ICONS.handbrake(499, 336, 27, info.handbrake and D.red or D.off, 2.2)
	ICONS.engine(542.5, 336, 28, info.engine and D.amber or D.off, 2.2)
end

---------------------------------------------------------------------------
-- A5: German hatch (twin dials in a stadium-shaped housing, a red LCD between them)
---------------------------------------------------------------------------
local G = {
	lighting = rgb("3d8bff"), needle = rgb("ff2a14"), lcd = rgb("ff3b2a"), red = rgb("ff3b2a"), redNumber = rgb("ff7a66"),
	green = rgb("3ddc6a"), amber = rgb("ffb53a"), off = rgb("2c2e31"), house = rgb("0f1011"), bevel = rgb("2e3134"),
	chrome = rgb("8d9094"), chromeLight = rgb("dcdee0"), face = rgb("07080a"), lcdBack = rgb("030303"), lcdRim = rgb("2a2c2e"),
	cap = rgb("0f1011"), capLight = rgb("2e3033"), button = rgb("141618"), buttonLed = rgb("26282b"), buttonBase = rgb("1c1e21"),
	policeRed = rgb("e0392e"), policeBlue = rgb("3d8bff"),
}
G.core = mix(G.lighting, WHITE, 0.45)
G.glow = faded(G.lighting, 170)
G.tickGlow = faded(G.lighting, 60)
G.lcdGlow = faded(G.lcd, 150)
G.buttonLabel = mix(G.lighting, WHITE, 0.4)
local G_SWEEP = 125

-- the housing: a box between two half circles round the dials' centres
local function stadium(centreY, radius, color)
	rectangle(290, centreY - radius, 420, radius * 2, color)
	local x, y = place(290, centreY)
	disc(x, y, radius, color)
	x, y = place(710, centreY)
	disc(x, y, radius, color)
end

local function germanDial(centreX, max, major, redFrom, font, label)
	local x, y = place(centreX, 230)
	disc(x, y, 160, BLACK)
	band(x, y, 156.25, 158.75, 0, 360, G.chrome, 6)
	band(x, y, 156.25, 158.75, -80, 10, G.chromeLight)
	disc(x, y, 155, G.face)
	band(x, y, 145, 155, 0, 360, Color(0, 0, 0, 110), 8)
	for value = 0, max, major / 2 do
		local angle = -G_SWEEP + value / max * 2 * G_SWEEP
		local isMajor = abs(value / major - math.Round(value / major)) < 1e-6
		local inRed = redFrom and value >= redFrom - 1e-9
		local x0, y0 = polar(x, y, isMajor and 124 or 134, angle)
		local x1, y1 = polar(x, y, 145, angle)
		if not inRed then line(x0, y0, x1, y1, (isMajor and 3.6 or 1.8) * 1.8 * pixel, G.tickGlow) end
		line(x0, y0, x1, y1, ((inRed or isMajor) and 2.6 or 1.1) * pixel, inRed and G.red or G.core)
		if isMajor then
			local numberX, numberY = polar(x, y, 106, angle)
			numberX, numberY = floor(numberX + 0.5), floor(numberY + 0.5)
			draw.SimpleText(label(value), "AudioHud_" .. font .. "_Glow", numberX, numberY, inRed and Color(255, 42, 26, 170) or G.glow, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			draw.SimpleText(label(value), "AudioHud_" .. font, numberX, numberY, inRed and G.redNumber or G.core, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
	end
end

local function germanNeedle(centreX, centreY, length, tail, halfWidth, degrees, capRadius)
	local x, y = place(centreX, centreY)
	wedge(x + 2 * pixel, y + 4 * pixel, -tail, halfWidth, length, 0.5, degrees, Color(0, 0, 0, 130))
	wedge(x, y, -tail, halfWidth * 2.2, length, 1.6, degrees, faded(G.needle, 70))
	wedge(x, y, -tail, halfWidth, length, 0.5, degrees, G.needle)
	disc(x + 1.5 * pixel, y + 3 * pixel, capRadius, Color(0, 0, 0, 150))
	disc(x, y, capRadius, G.cap)
	disc(x - capRadius * 0.15 * pixel, y - capRadius * 0.25 * pixel, capRadius * 0.55, G.capLight)
	disc(x, y, capRadius * 0.45, G.cap)
end

local G_BUTTON_HEIGHT = 26
local function germanButton(x, y, width, label, active, lit, color)
	rectangle(x, y, width, G_BUTTON_HEIGHT, active and mix(color, G.buttonBase, 0.82) or G.button)
	outline(x, y, width, G_BUTTON_HEIGHT, BLACK)
	rectangle(x + width / 2 - 8, y + 3, 16, 3, lit and color or (active and mix(color, BLACK, 0.5) or G.buttonLed))
	text(label, "G_Button", x + width / 2, y + 15, active and WHITE or G.buttonLabel, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end

local function drawGerman(info, vehicle, police)
	stadium(242, 176, Color(0, 0, 0, 90))
	stadium(230, 174, G.bevel)
	stadium(230, 170, G.house)

	germanDial(290, info.dialSpeed, info.speedMajor, nil, "G_Speed", function(value) return string.format("%d", value) end)
	germanDial(710, info.dialRpm, info.majorRpm, info.redline, "G_Tach", function(value) return string.format("%d", value / 1000) end)

	-- the fuel gauge inside the rev counter
	local fuelX, fuelY = place(710, 336)
	for tick = 0, 4 do
		local x0, y0 = polar(fuelX, fuelY, 30, -50 + tick * 25)
		local x1, y1 = polar(fuelX, fuelY, tick % 2 == 0 and 40 or 36, -50 + tick * 25)
		line(x0, y0, x1, y1, 1.6 * pixel, tick == 0 and G.red or G.core)
	end
	text("0", "G_Small", 676, 330, G.core, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, G.glow)
	text("1/1", "G_Small", 744, 330, G.core, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, G.glow)
	ICONS.fuel(710, 352, 15, info.lowFuel and G.amber or G.off, 2.4)

	text(info.usesMph and "mph" or "km/h", "G_Unit", 290, 296, G.core, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, G.glow)
	text("×1000 /min", "G_Small", 710, 168, G.core, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, G.glow)

	-- the LCD: gear and speed
	rectangle(462, 162, 76, 118, G.lcdBack)
	outline(462, 162, 76, 118, G.lcdRim)
	text("GEAR", "G_LcdSmall", 500, 181.5, faded(G.lcd, 190), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, G.lcdGlow)
	text(info.gear, "G_LcdGear", 500, 218.5, G.lcd, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, G.lcdGlow)
	text(info.speedDigits .. (info.usesMph and " mph" or " km/h"), "G_LcdSpeed", 500, 258.5, G.lcd, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, G.lcdGlow)

	-- police: CODE 2 / CODE 3, then the siren tones, under the LCD
	if police then
		local lightMode = vehicle:GetNW2Int("audio_lights", 0)
		local flashing = lightsFlashing(vehicle, lightMode)
		germanButton(436, 318, 62, "CODE 2", lightMode == 1, lightMode == 1 and flashing, G.policeBlue)
		germanButton(502, 318, 62, "CODE 3", lightMode == 2, lightMode == 2 and flashing, G.policeRed)
		local tone = sirenTone(vehicle)
		for index, name in ipairs({ "WAIL", "YELP", "PHASER" }) do
			germanButton(415 + (index - 1) * 58, 350, 54, name, tone == name, tone == name, G.amber)
		end
	end

	-- the lamp row over the LCD
	if info.left then indicatorGlow(424, 106, 13, G.green) end
	ICONS.arrowA(424, 106, 24, info.left and G.green or G.off, true)
	ICONS.headlights(461, 106, 22, info.headlights and G.green or G.off, 2.4)
	ICONS.handbrake(498, 106, 24, info.handbrake and G.red or G.off, 2.2)
	ICONS.engine(537, 106, 26, info.engine and G.amber or G.off, 2.2)
	if info.right then indicatorGlow(576, 106, 13, G.green) end
	ICONS.arrowA(576, 106, 24, info.right and G.green or G.off, false)

	germanNeedle(290, 230, 142, 26, 2.6, -G_SWEEP + clamp(info.speed, 0, info.dialSpeed) / info.dialSpeed * 2 * G_SWEEP, 17)
	germanNeedle(710, 230, 142, 26, 2.6, -G_SWEEP + clamp(info.rpm, 0, info.dialRpm) / info.dialRpm * 2 * G_SWEEP, 17)
	germanNeedle(710, 336, 36, 6, 1.4, -50 + clamp(info.fuelShown, 0, 1) * 100, 6)
end

---------------------------------------------------------------------------
-- A3: 60s vintage (cream faces, chrome rims, jewel lamps)
---------------------------------------------------------------------------
local V = {
	face = rgb("e9e0c8"), ink = rgb("1d1c1a"), red = rgb("b8261a"), needle = rgb("151515"), tip = rgb("c0281c"),
	rim = rgb("0d0d0d"), chrome = rgb("b4b7bb"), chromeLight = rgb("eef0f2"), chromeDark = rgb("5c5f63"),
	jewelRim = rgb("c3c6ca"), green = rgb("3fcf5a"), redLamp = rgb("e0392e"), amber = rgb("f2a630"),
	gearText = rgb("f3ecd9"), gearRim = rgb("b9bcc0"), gearBack = rgb("111111"),
	cap = rgb("9a9da1"), capLight = rgb("fafafa"), capDark = rgb("3a3c3f"),
	iconOn = Color(20, 20, 20, 190), iconOff = Color(255, 255, 255, 46), shadow = Color(42, 31, 16, 110),
}
V.faceLight = mix(V.face, WHITE, 0.25)
V.faceDark = mix(V.face, BLACK, 0.18)

local function vintageDial(gauge)
	local x, y = place(gauge.cx, gauge.cy)
	local faceRadius = gauge.bezel - 8
	disc(x, y, gauge.bezel + 4, V.rim)
	band(x, y, faceRadius, faceRadius + gauge.chrome, 0, 360, V.chrome, 8)
	band(x, y, faceRadius, faceRadius + gauge.chrome, -80, 10, V.chromeLight)
	band(x, y, faceRadius, faceRadius + gauge.chrome, 100, 190, V.chromeDark)
	disc(x, y, faceRadius, V.faceDark)
	disc(x, y, faceRadius - 5, V.face)
	disc(x, y - faceRadius * 0.12 * pixel, faceRadius * 0.6, faded(V.faceLight, 120))
	band(x, y, faceRadius - 8, faceRadius, 0, 360, Color(42, 31, 16, 45), 8)

	local outer = faceRadius - 9
	local function angleOf(value) return -gauge.sweep / 2 + value / gauge.max * gauge.sweep end
	band(x, y, outer - 0.6, outer + 0.6, angleOf(0), angleOf(gauge.max), V.ink)
	if gauge.redFrom then band(x, y, outer - 7.5, outer - 0.5, angleOf(gauge.redFrom), angleOf(gauge.redTo), V.red) end
	local count = math.Round(gauge.max / gauge.minor)
	for i = 0, count do
		local value = i * gauge.minor
		local angle = angleOf(value)
		local isMajor = abs(value / gauge.major - math.Round(value / gauge.major)) < 1e-6
		local isHalf = not isMajor and abs(value / gauge.half - math.Round(value / gauge.half)) < 1e-6
		local length = faceRadius * (isMajor and 0.13 or (isHalf and 0.08 or 0.04))
		local x0, y0 = polar(x, y, outer - length, angle)
		local x1, y1 = polar(x, y, outer, angle)
		line(x0, y0, x1, y1, (isMajor and 3.2 or (isHalf and 2 or 1.2)) * pixel, V.ink)
		if isMajor then
			local inRed = gauge.redFrom and value >= gauge.redFrom - 1e-9 and value <= gauge.redTo + 1e-9
			local numberX, numberY = polar(x, y, faceRadius * gauge.numberRadius, angle)
			draw.SimpleText(gauge.label(value), "AudioHud_" .. gauge.font, floor(numberX + 0.5), floor(numberY + 0.5), inRed and V.red or V.ink,
				TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
	end
end

-- a jewel lamp: a chrome-ringed glass dome, the symbol in dark ink when lit
local function jewel(x, y, on, color, icon)
	local screenX, screenY = place(x, y)
	if on then disc(screenX, screenY, 20, faded(color, 55), 24) end
	disc(screenX, screenY, 13, V.jewelRim, 24)
	disc(screenX, screenY, 10, on and color or mix(color, BLACK, 0.72), 24)
	disc(screenX - 3 * pixel, screenY - 3.5 * pixel, 4, on and faded(mix(color, WHITE, 0.45), 210) or faded(mix(color, BLACK, 0.4), 160), 16)
	if icon then icon(x, y, on and V.iconOn or V.iconOff) end
end

local function vintageNeedle(centreX, centreY, length, tail, halfWidth, degrees, capRadius)
	local x, y = place(centreX, centreY)
	wedge(x + 3 * pixel, y + 5 * pixel, -tail, halfWidth, length, 0.9, degrees, V.shadow)
	wedge(x, y, -tail, halfWidth, length, 0.9, degrees, V.needle)
	wedge(x, y, length * 0.78, 1.4, length, 0.9, degrees, V.tip)
	disc(x + 1.5 * pixel, y + 3 * pixel, capRadius, V.shadow, 24)
	disc(x, y, capRadius, V.capDark, 24)
	disc(x, y, capRadius * 0.85, V.cap, 24)
	disc(x - capRadius * 0.3 * pixel, y - capRadius * 0.35 * pixel, capRadius * 0.4, V.capLight, 16)
end

local function drawVintage(info)
	local tach = { cx = 219, cy = 230, bezel = 125, chrome = 10, sweep = 270, max = info.dialRpm, major = info.majorRpm, half = info.majorRpm / 2,
		minor = info.majorRpm / 4, redFrom = info.redline, redTo = info.dialRpm, numberRadius = 0.68, font = "V_Tach",
		label = function(value) return string.format("%d", value / 1000) end }
	local speedo = { cx = 529, cy = 220, bezel = 165, chrome = 12, sweep = 270, max = info.dialSpeed, major = info.speedMajor, half = info.speedMajor / 2,
		minor = info.speedMajor / 10, numberRadius = 0.68, font = "V_Speed", label = function(value) return string.format("%d", value) end }
	local fuelGauge = { cx = 814, cy = 240, bezel = 95, chrome = 10, sweep = 120, max = 1, major = 0.5, half = 0.25, minor = 0.125, redFrom = 0, redTo = 0.125,
		numberRadius = 0.58, font = "V_Fuel", label = function(value) return value == 0 and "E" or (value == 1 and "F" or "½") end }
	vintageDial(tach)
	vintageDial(speedo)
	vintageDial(fuelGauge)

	text("R.P.M. × 1000", "V_Label", 219, 168, V.ink, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
	rectangle(205, 268, 28, 32, V.gearRim)
	rectangle(207, 270, 24, 28, V.gearBack)
	text(info.gear, "V_Gear", 219, 284, V.gearText, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	text("GEAR", "V_Label", 219, 306, V.ink, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
	text(info.usesMph and "M.P.H." or "KM/H", "V_Unit", 529, 160, V.ink, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
	text("FUEL", "V_Label", 814, 196, V.ink, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)

	jewel(395, 82, info.left, V.green, function(x, y, color) ICONS.arrowA(x, y, 14, color, true) end)
	jewel(663, 82, info.right, V.green, function(x, y, color) ICONS.arrowA(x, y, 14, color, false) end)
	jewel(489, 286, info.headlights, V.green, function(x, y, color) ICONS.headlights(x, y, 15, color, 2.6) end)
	jewel(529, 286, info.handbrake, V.redLamp, function(x, y, color) ICONS.handbrake(x, y, 16, color, 2.6) end)
	jewel(569, 286, info.engine, V.amber, function(x, y, color) ICONS.engine(x, y, 16, color, 2.6) end)
	jewel(814, 286, info.lowFuel, V.amber, function(x, y, color) ICONS.fuel(x, y, 12, color, 2.6) end)
	jewel(219, 198, info.share > 0.92, V.redLamp)

	vintageNeedle(219, 230, 100, 22, 2.6, -135 + clamp(info.rpm, 0, info.dialRpm) / info.dialRpm * 270, 9)
	vintageNeedle(529, 220, 138, 28, 3, -135 + clamp(info.speed, 0, info.dialSpeed) / info.dialSpeed * 270, 11)
	vintageNeedle(814, 240, 72, 16, 2.2, -60 + clamp(info.fuelShown, 0, 1) * 120, 7)
end

---------------------------------------------------------------------------
-- A4: 80s digital (a VFD panel: an arc of rev blocks, seven-segment speed and gear)
---------------------------------------------------------------------------
local F = {
	vfd = rgb("5ef2d2"), amber = rgb("ffb03a"), red = rgb("ff4a3a"), green = rgb("7dff6a"),
	bezel = rgb("26292c"), panel = rgb("090c0d"),
}
F.ghost = mix(F.vfd, BLACK, 0.82)
F.dim = mix(F.vfd, BLACK, 0.3)
F.scale = mix(F.vfd, BLACK, 0.25)
F.amberGhost = mix(F.amber, BLACK, 0.82)
local F_BLOCKS, F_CENTRE_X, F_CENTRE_Y, F_RADIUS = 40, 500, 372, 290

local function drawDigital(info)
	-- the panel: an arch on a flat foot
	halfEllipse(500, 400, 404, 370, F.bezel)
	rectangle(96, 400, 808, 8, F.bezel)
	halfEllipse(500, 400, 396, 362, F.panel)

	-- rev blocks, taller to the right; amber under the redline, red over it
	local step = info.dialRpm / F_BLOCKS
	for i = 0, F_BLOCKS - 1 do
		local angle = -60 + (i + 0.5) * 3
		local value = (i + 1) * step
		local height = 14 + i * 0.5
		local on = info.rpm >= value - step / 2
		local color = value <= info.redline * 0.85 and F.vfd or (value <= info.redline and F.amber or F.red)
		local blockX = F_CENTRE_X + (F_RADIUS + height / 2) * sin(rad(angle))
		local blockY = F_CENTRE_Y - (F_RADIUS + height / 2) * cos(rad(angle))
		if on then rotatedBox(blockX, blockY, 15, height + 4, angle, faded(color, 50)) end
		rotatedBox(blockX, blockY, 11, height, angle, on and color or mix(color, BLACK, 0.82))
	end
	local marks = math.Round(info.dialRpm / info.majorRpm)
	for mark = 0, marks do
		local angle = rad(-60 + mark * 120 / marks)
		local rpm = mark * info.majorRpm
		local color = rpm >= info.redline and F.red or F.scale
		text(string.format("%d", rpm / 1000), "F_Scale", F_CENTRE_X + 268 * sin(angle), F_CENTRE_Y - 268 * cos(angle), color,
			TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, faded(color, 140))
	end
	text("RPM ×1000", "F_Label", 500, 126, F.dim, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)

	-- speed and gear
	local speedText = string.format("%3d", min(999, info.speedDigits))
	for digit = 1, 3 do sevenSegment(402 + (digit - 1) * 70, 186, 56, 104, 11, speedText:sub(digit, digit), F.vfd, F.ghost) end
	text(info.usesMph and "MPH" or "KM/H", "F_Unit", 616, 266, F.vfd, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, faded(F.vfd, 140))
	text("GEAR", "F_Label", 186, 252, F.dim, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
	sevenSegment(190, 272, 40, 72, 8, info.gear, F.amber, F.amberGhost)

	-- fuel: eight bars, wider towards full
	text("F", "F_Fuel", 791.5, 246, F.dim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	local fuelColor = info.lowFuel and F.amber or F.vfd
	for row = 0, 7 do
		local bar = 7 - row
		local lit = info.fuelShown >= (bar + 0.5) / 8 or (bar == 0 and info.fuelShown > 0.02)
		local width = 26 + bar * 3
		leaningBox(791.5 - width / 2, 258 + row * 11, width, 7, 8, lit and fuelColor or F.ghost)
	end
	text("E", "F_Fuel", 791.5, 347, F.dim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	ICONS.fuel(834, 336, 20, info.lowFuel and F.amber or F.ghost, 2.2)

	if info.left then indicatorGlow(140, 382, 15, F.green) end
	ICONS.arrowA(140, 382, 30, info.left and F.green or F.ghost, true)
	if info.right then indicatorGlow(860, 382, 15, F.green) end
	ICONS.arrowA(860, 382, 30, info.right and F.green or F.ghost, false)
	ICONS.headlights(447, 347, 28, info.headlights and F.green or F.ghost, 2.4)
	ICONS.engine(499, 347, 32, info.engine and F.amber or F.ghost, 2.2)
	ICONS.handbrake(552, 347, 30, info.handbrake and F.red or F.ghost, 2.2)
end

---------------------------------------------------------------------------
-- HUD
---------------------------------------------------------------------------
-- smoothRevs: the cluster shows the revs as a bar / segments (smoothRpmValue), not a needle alone.
-- police: it has emergency-light controls, shown in a police car
local CLUSTERS = {
	a = { box = A, draw = drawClassic, fonts = "A", police = true },
	d = { box = A, draw = drawModern, fonts = "D", police = true, smoothRevs = true },
	a5 = { box = A, draw = drawGerman, fonts = "G", police = true },
	a3 = { box = A, draw = drawVintage, fonts = "V" },
	a4 = { box = A, draw = drawDigital, fonts = "F", smoothRevs = true },
	b = { box = B, draw = drawArc, fonts = "B", smoothRevs = true },
	c = { box = C, draw = drawStrip, fonts = "C", smoothRevs = true },
}

local function isPoliceCar(vehicle)
	return vehicle:GetNW2String("audio_lightscheme", "") == "police" and IsValid(vehicle:GetNW2Entity("audio_lightbar"))
end

-- audio_engine_cluster's numbers (the user's order) -> the design's clusters; 0 or anything else = the classic
local CLUSTER_NUMBERS = { "a", "d", "a5", "a3", "a4", "b", "c" }

local function clusterFor()
	return CLUSTER_NUMBERS[clusterConVar:GetInt()] or "a"
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
	local clusterId = clusterFor()
	local cluster = CLUSTERS[clusterId]
	local box = cluster.box
	local police = cluster.police and isPoliceCar(vehicle) or false
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
	cluster.draw(info, vehicle, police)

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
	-- (the siren's tone); a cluster with light controls shows them itself in a police car
	local lightLabel = AudioEngine.LIGHT_MODES[vehicle:GetNW2Int("audio_lights", 0)]
	if not police and lightLabel and IsValid(vehicle:GetNW2Entity("audio_lightbar")) then
		local extra = hook.Run("audio_engine/lights-label", vehicle)
		if isstring(extra) and extra ~= "" then lightLabel = lightLabel .. " · " .. extra end
		draw.SimpleText(lightLabel, "AudioHud_Status", leftX, topY, RealTime() % 0.5 < 0.25 and POLICE_RED or WHITE, TEXT_ALIGN_LEFT, TEXT_ALIGN_BOTTOM)
	end
end)

hook.Add("OnScreenSizeChanged", "audio_engine_hud", function() fontScales, statusFontScale = {}, nil end)
