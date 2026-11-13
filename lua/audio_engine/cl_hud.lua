--[[
	Audio Engine - driver HUD (client)
	Tachometer with red zone and shift lights, gear, speed, rpm, throttle and brake.
	Same look as the Rev Bench instrument cluster.
]]

local AudioEngine = AUDIO_ENGINE

local hudConVar = CreateClientConVar("audio_engine_hud", "1", true, false, "Show the speed/rpm HUD")
local unitsConVar = CreateClientConVar("audio_engine_units", "mph", true, false, "HUD speed units: mph or kmh")
-- the default used to be kmh, and the old value is archived: move everyone to mph once
-- (a cookie remembers it, so choosing kmh again afterwards sticks)
if cookie.GetNumber("audio_engine_units_mph", 0) == 0 then
	cookie.Set("audio_engine_units_mph", "1")
	if unitsConVar:GetString() ~= "mph" then RunConsoleCommand("audio_engine_units", "mph") end
end
local scaleConVar = CreateClientConVar("audio_engine_hud_scale", "1", true, false, "HUD size multiplier", 0.5, 2)

local COLORS = {
	panel = Color(23, 27, 33, 235),
	face = Color(18, 21, 26, 255),
	line = Color(42, 48, 57, 255),
	text = Color(232, 227, 214, 255),
	muted = Color(141, 147, 156, 255),
	amber = Color(255, 165, 61, 255),
	amberGlow = Color(255, 165, 61, 50),
	red = Color(255, 75, 58, 255),
	green = Color(95, 211, 138, 255),
}
local SHIFT_LIGHT_AT = { 0.74, 0.81, 0.87, 0.92, 0.96 }
local SHIFT_LIGHT_COLORS = { COLORS.green, COLORS.green, COLORS.amber, COLORS.amber, COLORS.red }

local cos, sin, pi, min, max, floor = math.cos, math.sin, math.pi, math.min, math.max, math.floor

---------------------------------------------------------------------------
-- fonts (rebuilt when the resolution or scale changes)
---------------------------------------------------------------------------
local fontScale
local function makeFonts(scale)
	if fontScale == scale then return end
	fontScale = scale
	local function createFont(name, size, weight)
		surface.CreateFont(name, { font = "Roboto", size = math.max(8, floor(size * scale)), weight = weight, antialias = true, extended = true })
	end
	createFont("AudioHud_Gear", 96, 800)
	createFont("AudioHud_Big", 40, 700)
	createFont("AudioHud_Num", 30, 700)
	createFont("AudioHud_Dial", 18, 700)
	createFont("AudioHud_Unit", 15, 500)
	createFont("AudioHud_Label", 13, 600)
end

---------------------------------------------------------------------------
-- drawing helpers
---------------------------------------------------------------------------
-- draw.RoundedBox / text change the bound texture, so every polygon resets it first;
-- otherwise the needle and dial draw with a corner texture and vanish
local function poly(points, color)
	draw.NoTexture()
	surface.SetDrawColor(color)
	surface.DrawPoly(points)
	-- draw the reversed winding too, so either orientation shows
	local reversed = {}
	for i = #points, 1, -1 do reversed[#reversed + 1] = points[i] end
	surface.DrawPoly(reversed)
end

local function thickLine(startX, startY, endX, endY, width, color)
	local deltaX, deltaY = endX - startX, endY - startY
	local length = math.sqrt(deltaX * deltaX + deltaY * deltaY)
	if length < 0.001 then return end
	local offsetX, offsetY = -deltaY / length * width / 2, deltaX / length * width / 2
	poly({
		{ x = startX + offsetX, y = startY + offsetY },
		{ x = endX + offsetX, y = endY + offsetY },
		{ x = endX - offsetX, y = endY - offsetY },
		{ x = startX - offsetX, y = startY - offsetY },
	}, color)
end

local function arc(centerX, centerY, innerRadius, outerRadius, startAngle, endAngle, color)
	local segmentCount = max(4, floor((endAngle - startAngle) / (pi / 48)))
	draw.NoTexture()
	surface.SetDrawColor(color)
	for i = 0, segmentCount - 1 do
		local segmentStart = startAngle + (endAngle - startAngle) * i / segmentCount
		local segmentEnd = startAngle + (endAngle - startAngle) * (i + 1) / segmentCount
		local startCos, startSin, endCos, endSin = cos(segmentStart), sin(segmentStart), cos(segmentEnd), sin(segmentEnd)
		surface.DrawPoly({
			{ x = centerX + startCos * outerRadius, y = centerY + startSin * outerRadius },
			{ x = centerX + endCos * outerRadius, y = centerY + endSin * outerRadius },
			{ x = centerX + endCos * innerRadius, y = centerY + endSin * innerRadius },
			{ x = centerX + startCos * innerRadius, y = centerY + startSin * innerRadius },
		})
	end
end

local function circle(centerX, centerY, radius, color)
	local points = {}
	local segmentCount = 40
	for i = 0, segmentCount - 1 do
		local angle = i / segmentCount * pi * 2
		points[#points + 1] = { x = centerX + cos(angle) * radius, y = centerY + sin(angle) * radius }
	end
	draw.NoTexture()
	surface.SetDrawColor(color)
	surface.DrawPoly(points)
end

local function box(x, y, width, height, scale, color, border)
	draw.RoundedBox(floor(10 * scale), x - 1, y - 1, width + 2, height + 2, border or COLORS.line)
	draw.RoundedBox(floor(10 * scale), x, y, width, height, color or COLORS.face)
end

local function formatThousands(number)
	local digits = tostring(floor(number + 0.5))
	local grouped = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (grouped:gsub("^,", ""))
end

---------------------------------------------------------------------------
-- tachometer
---------------------------------------------------------------------------
local function drawTachometer(centerX, centerY, radius, scale, rpm, config)
	local redline = config.redline
	local majorStep = (redline + 500 > 12000) and 2000 or 1000
	local dialMaxRpm = math.ceil((redline + 500) / majorStep) * majorStep
	local startAngle, sweep = pi * 0.75, pi * 1.5
	local function angleOf(dialRpm) return startAngle + sweep * math.Clamp(dialRpm, 0, dialMaxRpm) / dialMaxRpm end
	local pixelScale = radius / 194 -- the page's dial is 194 px in radius

	circle(centerX, centerY, radius + 2 * pixelScale, COLORS.line)
	circle(centerX, centerY, radius, COLORS.face)

	-- red zone
	arc(centerX, centerY, radius - 19 * pixelScale, radius - 9 * pixelScale, angleOf(redline), angleOf(dialMaxRpm), COLORS.red)

	-- ticks and numerals
	local minorStep = majorStep / 4
	for tickRpm = 0, dialMaxRpm, minorStep do
		local angle = angleOf(tickRpm)
		local isMajor = tickRpm % majorStep == 0
		local isHalf = tickRpm % (majorStep / 2) == 0
		local tickLength = (isMajor and 18 or isHalf and 11 or 6) * pixelScale
		local angleCos, angleSin = cos(angle), sin(angle)
		local tickColor = tickRpm >= redline and COLORS.red or (isMajor and COLORS.text or COLORS.muted)
		local tickOuter, tickInner = radius - 8 * pixelScale, radius - 8 * pixelScale - tickLength
		thickLine(centerX + angleCos * tickOuter, centerY + angleSin * tickOuter, centerX + angleCos * tickInner, centerY + angleSin * tickInner,
			(isMajor and 3 or 1.5) * pixelScale, tickColor)
		if isMajor then
			draw.SimpleText(tostring(tickRpm / 1000), "AudioHud_Dial", centerX + angleCos * (radius - 44 * pixelScale), centerY + angleSin * (radius - 44 * pixelScale),
				tickRpm >= redline and COLORS.red or COLORS.text, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
	end

	draw.SimpleText("x1000 r/min", "AudioHud_Label", centerX, centerY + radius * 0.34, COLORS.muted, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	draw.SimpleText(formatThousands(rpm), "AudioHud_Dial", centerX, centerY + radius * 0.52, COLORS.text, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

	-- needle with a soft glow
	local angle = angleOf(rpm)
	local angleCos, angleSin = cos(angle), sin(angle)
	local needleBaseX, needleBaseY = centerX - angleCos * 16 * pixelScale, centerY - angleSin * 16 * pixelScale
	local needleTipX, needleTipY = centerX + angleCos * (radius - 22 * pixelScale), centerY + angleSin * (radius - 22 * pixelScale)
	thickLine(needleBaseX, needleBaseY, needleTipX, needleTipY, 12 * pixelScale, COLORS.amberGlow)
	thickLine(needleBaseX, needleBaseY, needleTipX, needleTipY, 4.5 * pixelScale, COLORS.amber)
	circle(centerX, centerY, 11 * pixelScale, COLORS.line)
	circle(centerX, centerY, 4 * pixelScale, COLORS.amber)
end

---------------------------------------------------------------------------
-- HUD
---------------------------------------------------------------------------
local displayedRpm, blinkTime, brakeDisplay = 0, 0, 0

hook.Add("HUDPaint", "audio_engine_hud", function()
	if not hudConVar:GetBool() then return end
	local player = LocalPlayer()
	if not IsValid(player) then return end
	local vehicle = player:GetVehicle()
	if not IsValid(vehicle) then return end
	local car = AudioEngine.GetClientCar and AudioEngine.GetClientCar(vehicle)
	if not car then return end

	local config, engineState = car.config, car.engineState
	local deltaTime = RealFrameTime()
	displayedRpm = displayedRpm + (engineState.rpm - displayedRpm) * min(1, deltaTime * 18)
	blinkTime = blinkTime + deltaTime

	local scale = ScrH() / 1080 * scaleConVar:GetFloat()
	makeFonts(scale)
	draw.NoTexture()

	local padding = 18 * scale
	local tachRadius = 120 * scale
	local shiftLightHeight = 9 * scale
	local readoutWidth = 236 * scale
	local panelWidth = padding + 2 * tachRadius + 22 * scale + readoutWidth + padding
	local panelHeight = padding + shiftLightHeight + 12 * scale + 2 * tachRadius + padding
	local panelX = ScrW() - panelWidth - 32 * scale
	local panelY = ScrH() - panelHeight - 32 * scale

	draw.RoundedBox(floor(14 * scale), panelX - 1, panelY - 1, panelWidth + 2, panelHeight + 2, COLORS.line)
	draw.RoundedBox(floor(14 * scale), panelX, panelY, panelWidth, panelHeight, COLORS.panel)

	-- ignition prompt
	if not engineState.on or engineState.phase ~= "run" then
		local message
		if not engineState.on then
			local startKeyConVar = GetConVar("audio_engine_startkey")
			local key = string.upper(startKeyConVar and startKeyConVar:GetString() or "R")
			message = (key == "" or key == "NONE") and "Engine off · audio_engine_toggle starts it" or ("Engine off · press " .. key .. " to start")
		else
			message = "Starting…"
		end
		draw.SimpleText(message, "AudioHud_Num", panelX + panelWidth / 2, panelY - 10 * scale, engineState.on and COLORS.amber or COLORS.text, TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM)
	end

	-- speed limiter (sv_cruise.lua): the limit, in the HUD's units
	local speedLimit = vehicle:GetNW2Float("audio_cruise", 0)
	if speedLimit > 0 and engineState.on and engineState.phase == "run" then
		local usesMph = unitsConVar:GetString() == "mph"
		local limitText = usesMph and string.format("LIMIT %d mph", math.floor(speedLimit + 0.5)) or string.format("LIMIT %d km/h", math.floor(speedLimit * 1.609344 + 0.5))
		draw.SimpleText(limitText, "AudioHud_Num", panelX + panelWidth - 10 * scale, panelY - 10 * scale, COLORS.green, TEXT_ALIGN_RIGHT, TEXT_ALIGN_BOTTOM)
	end

	-- police lights (sv_police.lua). Other addons can add a word after the mode through the
	-- audio_engine/lights-label hook (the police siren shows its tone)
	local lightLabel = AudioEngine.LIGHT_MODES[vehicle:GetNW2Int("audio_lights", 0)]
	if lightLabel and IsValid(vehicle:GetNW2Entity("audio_lightbar")) then
		local extra = hook.Run("audio_engine/lights-label", vehicle)
		if isstring(extra) and extra ~= "" then lightLabel = lightLabel .. " · " .. extra end
		local labelColor = blinkTime % 0.5 < 0.25 and COLORS.red or COLORS.text
		draw.SimpleText(lightLabel, "AudioHud_Num", panelX + 10 * scale, panelY - 10 * scale, labelColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_BOTTOM)
	end

	-- shift lights
	local redlineShare = displayedRpm / config.redline
	local onLimiter = engineState.limiterHoldTimer > 0 or redlineShare > 0.985
	local shiftLightWidth, shiftLightGap = 26 * scale, 10 * scale
	local tachCenterX = panelX + padding + tachRadius
	local shiftLightsX = tachCenterX - (5 * shiftLightWidth + 4 * shiftLightGap) / 2
	for i = 1, 5 do
		local lit = onLimiter and (blinkTime % 0.14 < 0.07) or (redlineShare >= SHIFT_LIGHT_AT[i])
		draw.RoundedBox(floor(3 * scale), shiftLightsX + (i - 1) * (shiftLightWidth + shiftLightGap), panelY + padding, shiftLightWidth, shiftLightHeight, lit and SHIFT_LIGHT_COLORS[i] or COLORS.line)
	end

	-- tach
	local tachCenterY = panelY + padding + shiftLightHeight + 12 * scale + tachRadius
	drawTachometer(tachCenterX, tachCenterY, tachRadius, scale, displayedRpm, config)

	-- readouts
	local readoutX = panelX + padding + 2 * tachRadius + 22 * scale
	local readoutY = panelY + padding
	local gap = 10 * scale
	local gearBoxWidth = 92 * scale
	local topRowHeight = 160 * scale

	-- gear
	box(readoutX, readoutY, gearBoxWidth, topRowHeight, scale)
	draw.SimpleText("GEAR", "AudioHud_Label", readoutX + 10 * scale, readoutY + 8 * scale, COLORS.muted)
	local gearLabel = "N"
	if not engineState.on then gearLabel = "-"
	elseif engineState.phase ~= "run" then gearLabel = "N"
	elseif engineState.gear == -1 then gearLabel = "R"
	elseif engineState.gear > 0 then gearLabel = tostring(engineState.gear) end
	draw.SimpleText(gearLabel, "AudioHud_Gear", readoutX + gearBoxWidth / 2, readoutY + topRowHeight / 2 + 8 * scale, COLORS.amber, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

	-- speed
	local speedBoxX = readoutX + gearBoxWidth + gap
	local speedBoxWidth = readoutWidth - gearBoxWidth - gap
	local speedBoxHeight = (topRowHeight - gap) / 2
	local usesMph = unitsConVar:GetString() == "mph"
	local speed = math.abs(car.speedAlongNose) * (usesMph and 2.23694 or 3.6)
	box(speedBoxX, readoutY, speedBoxWidth, speedBoxHeight, scale)
	draw.SimpleText("SPEED", "AudioHud_Label", speedBoxX + 10 * scale, readoutY + 8 * scale, COLORS.muted)
	surface.SetFont("AudioHud_Big")
	local speedText = tostring(floor(speed + 0.5))
	local speedTextWidth = surface.GetTextSize(speedText)
	draw.SimpleText(speedText, "AudioHud_Big", speedBoxX + 10 * scale, readoutY + speedBoxHeight - 6 * scale, COLORS.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_BOTTOM)
	draw.SimpleText(usesMph and "mph" or "km/h", "AudioHud_Unit", speedBoxX + 14 * scale + speedTextWidth, readoutY + speedBoxHeight - 12 * scale, COLORS.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_BOTTOM)

	-- rpm
	local engineBoxY = readoutY + speedBoxHeight + gap
	box(speedBoxX, engineBoxY, speedBoxWidth, speedBoxHeight, scale)
	draw.SimpleText("ENGINE", "AudioHud_Label", speedBoxX + 10 * scale, engineBoxY + 8 * scale, COLORS.muted)
	surface.SetFont("AudioHud_Num")
	local rpmText = formatThousands(displayedRpm)
	local rpmTextWidth = surface.GetTextSize(rpmText)
	draw.SimpleText(rpmText, "AudioHud_Num", speedBoxX + 10 * scale, engineBoxY + speedBoxHeight - 6 * scale, redlineShare >= 1 and COLORS.red or COLORS.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_BOTTOM)
	draw.SimpleText("rpm", "AudioHud_Unit", speedBoxX + 14 * scale + rpmTextWidth, engineBoxY + speedBoxHeight - 10 * scale, COLORS.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_BOTTOM)

	-- throttle / brake
	local braking = (player:KeyDown(IN_BACK) and car.speedAlongNose > 0.6) or (player:KeyDown(IN_FORWARD) and car.speedAlongNose < -0.6) or player:KeyDown(IN_JUMP)
	brakeDisplay = brakeDisplay + math.Clamp((braking and 1 or 0) - brakeDisplay, -deltaTime * 8, deltaTime * 4)
	local pedalBoxY = readoutY + topRowHeight + gap
	local pedalBoxHeight = panelY + panelHeight - padding - pedalBoxY
	box(readoutX, pedalBoxY, readoutWidth, pedalBoxHeight, scale)
	local barWidth = readoutWidth - 20 * scale
	local barHeight = 8 * scale
	local throttlePercent = floor(engineState.throttle * 100 + 0.5)
	local brakePercent = floor(brakeDisplay * 100 + 0.5)
	draw.SimpleText("THROTTLE " .. throttlePercent .. "%", "AudioHud_Label", readoutX + 10 * scale, pedalBoxY + 8 * scale, COLORS.muted)
	draw.RoundedBox(floor(4 * scale), readoutX + 10 * scale, pedalBoxY + 26 * scale, barWidth, barHeight, COLORS.line)
	if throttlePercent > 0 then
		draw.RoundedBox(floor(4 * scale), readoutX + 10 * scale, pedalBoxY + 26 * scale, barWidth * engineState.throttle, barHeight, COLORS.amber)
	end
	draw.SimpleText("BRAKE " .. brakePercent .. "%", "AudioHud_Label", readoutX + 10 * scale, pedalBoxY + 42 * scale, COLORS.muted)
	draw.RoundedBox(floor(4 * scale), readoutX + 10 * scale, pedalBoxY + 60 * scale, barWidth, barHeight, COLORS.line)
	if brakePercent > 0 then
		draw.RoundedBox(floor(4 * scale), readoutX + 10 * scale, pedalBoxY + 60 * scale, barWidth * brakeDisplay, barHeight, COLORS.red)
	end
end)

hook.Add("OnScreenSizeChanged", "audio_engine_hud", function() fontScale = nil end)
