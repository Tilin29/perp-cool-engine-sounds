--[[
	Audio Engine - driver HUD (client)
	Tachometer with red zone and shift lights, gear, speed, rpm, throttle and brake.
	Same look as the Rev Bench instrument cluster.
]]

local E = PerpAudioEngine

local cvHud = CreateClientConVar("audio_engine_hud", "1", true, false, "Show the speed/rpm HUD")
local cvUnits = CreateClientConVar("audio_engine_units", "mph", true, false, "HUD speed units: mph or kmh")
-- the default used to be kmh, and the old value is archived: move everyone to mph once
-- (a cookie remembers it, so choosing kmh again afterwards sticks)
if cookie.GetNumber("audio_engine_units_mph", 0) == 0 then
	cookie.Set("audio_engine_units_mph", "1")
	if cvUnits:GetString() ~= "mph" then RunConsoleCommand("audio_engine_units", "mph") end
end
local cvScale = CreateClientConVar("audio_engine_hud_scale", "1", true, false, "HUD size multiplier", 0.5, 2)

local C = {
	panel = Color(23, 27, 33, 235),
	face = Color(18, 21, 26, 255),
	line = Color(42, 48, 57, 255),
	fg = Color(232, 227, 214, 255),
	muted = Color(141, 147, 156, 255),
	amber = Color(255, 165, 61, 255),
	amberGlow = Color(255, 165, 61, 50),
	red = Color(255, 75, 58, 255),
	green = Color(95, 211, 138, 255),
}
local LED_AT = { 0.74, 0.81, 0.87, 0.92, 0.96 }
local LED_COL = { C.green, C.green, C.amber, C.amber, C.red }

local cos, sin, pi, min, max, floor = math.cos, math.sin, math.pi, math.min, math.max, math.floor

---------------------------------------------------------------------------
-- fonts (rebuilt when the resolution or scale changes)
---------------------------------------------------------------------------
local fontScale
local function makeFonts(s)
	if fontScale == s then return end
	fontScale = s
	local function f(name, size, weight)
		surface.CreateFont(
			name,
			{ font = "Roboto", size = math.max(8, floor(size * s)), weight = weight, antialias = true, extended = true }
		)
	end
	f("AudioHud_Gear", 96, 800)
	f("AudioHud_Big", 40, 700)
	f("AudioHud_Num", 30, 700)
	f("AudioHud_Dial", 18, 700)
	f("AudioHud_Unit", 15, 500)
	f("AudioHud_Label", 13, 600)
end

---------------------------------------------------------------------------
-- drawing helpers
---------------------------------------------------------------------------
-- a list of { pts, col } the dial is drawn from: built once per car and size, not per frame
local function addPoly(list, pts, col)
	list[#list + 1] = { pts = pts, col = col }
end

-- draw.RoundedBox / text change the bound texture, so polygons reset it first; otherwise the
-- needle and dial draw with a corner texture and vanish
local function drawPolys(list)
	draw.NoTexture()
	for _, item in ipairs(list) do
		surface.SetDrawColor(item.col)
		surface.DrawPoly(item.pts)
	end
end

-- both windings, so either orientation shows
local function addThickLine(list, x1, y1, x2, y2, w, col)
	local dx, dy = x2 - x1, y2 - y1
	local len = math.sqrt(dx * dx + dy * dy)
	if len < 0.001 then return end
	local nx, ny = -dy / len * w / 2, dx / len * w / 2
	local a, b = { x = x1 + nx, y = y1 + ny }, { x = x2 + nx, y = y2 + ny }
	local c, d = { x = x2 - nx, y = y2 - ny }, { x = x1 - nx, y = y1 - ny }
	addPoly(list, { a, b, c, d }, col)
	addPoly(list, { d, c, b, a }, col)
end

local function addArc(list, cx, cy, r0, r1, a0, a1, col)
	local segs = max(4, floor((a1 - a0) / (pi / 48)))
	for i = 0, segs - 1 do
		local t0 = a0 + (a1 - a0) * i / segs
		local t1 = a0 + (a1 - a0) * (i + 1) / segs
		local c0, s0, c1, s1 = cos(t0), sin(t0), cos(t1), sin(t1)
		addPoly(list, {
			{ x = cx + c0 * r1, y = cy + s0 * r1 },
			{ x = cx + c1 * r1, y = cy + s1 * r1 },
			{ x = cx + c1 * r0, y = cy + s1 * r0 },
			{ x = cx + c0 * r0, y = cy + s0 * r0 },
		}, col)
	end
end

local function addCircle(list, cx, cy, r, col)
	local pts = {}
	local n = 40
	for i = 0, n - 1 do
		local a = i / n * pi * 2
		pts[#pts + 1] = { x = cx + cos(a) * r, y = cy + sin(a) * r }
	end
	addPoly(list, pts, col)
end

local function box(x, y, w, h, s, col, border)
	draw.RoundedBox(floor(10 * s), x - 1, y - 1, w + 2, h + 2, border or C.line)
	draw.RoundedBox(floor(10 * s), x, y, w, h, col or C.face)
end

local function fmtThousands(n)
	local s = tostring(floor(n + 0.5))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end

---------------------------------------------------------------------------
-- tachometer
---------------------------------------------------------------------------
local DIAL_START, DIAL_SWEEP = pi * 0.75, pi * 1.5
local DIAL_PAGE_RADIUS = 194 -- the page's dial is this many px in radius

local function dialAngle(r, maxR)
	return DIAL_START + DIAL_SWEEP * math.Clamp(r, 0, maxR) / maxR
end

-- everything on the dial that doesn't move
local function buildDial(cx, cy, R, redline)
	local stepMajor = (redline + 500 > 12000) and 2000 or 1000
	local maxR = math.ceil((redline + 500) / stepMajor) * stepMajor
	local k = R / DIAL_PAGE_RADIUS
	local dial = { cx = cx, cy = cy, R = R, redline = redline, maxR = maxR, polys = {}, hub = {}, numerals = {} }
	local polys = dial.polys

	addCircle(polys, cx, cy, R + 2 * k, C.line)
	addCircle(polys, cx, cy, R, C.face)

	-- red zone
	addArc(polys, cx, cy, R - 19 * k, R - 9 * k, dialAngle(redline, maxR), dialAngle(maxR, maxR), C.red)

	-- ticks and numerals
	local minor = stepMajor / 4
	for r = 0, maxR, minor do
		local a = dialAngle(r, maxR)
		local major = r % stepMajor == 0
		local half = r % (stepMajor / 2) == 0
		local len = (major and 18 or half and 11 or 6) * k
		local c, sn = cos(a), sin(a)
		local col = r >= redline and C.red or (major and C.fg or C.muted)
		local outer, inner = R - 8 * k, R - 8 * k - len
		addThickLine(
			polys,
			cx + c * outer,
			cy + sn * outer,
			cx + c * inner,
			cy + sn * inner,
			(major and 3 or 1.5) * k,
			col
		)
		if major then
			dial.numerals[#dial.numerals + 1] = {
				text = tostring(r / 1000),
				x = cx + c * (R - 44 * k),
				y = cy + sn * (R - 44 * k),
				col = r >= redline and C.red or C.fg,
			}
		end
	end

	addCircle(dial.hub, cx, cy, 11 * k, C.line)
	addCircle(dial.hub, cx, cy, 4 * k, C.amber)

	return dial
end

local dial
local needle = {}

local function drawTach(cx, cy, R, rpm, cfg)
	if not dial or dial.cx ~= cx or dial.cy ~= cy or dial.R ~= R or dial.redline ~= cfg.redline then
		dial = buildDial(cx, cy, R, cfg.redline)
	end
	local k = R / DIAL_PAGE_RADIUS

	drawPolys(dial.polys)
	for _, n in ipairs(dial.numerals) do
		draw.SimpleText(n.text, "AudioHud_Dial", n.x, n.y, n.col, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end
	draw.SimpleText("x1000 r/min", "AudioHud_Label", cx, cy + R * 0.34, C.muted, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	draw.SimpleText(fmtThousands(rpm), "AudioHud_Dial", cx, cy + R * 0.52, C.fg, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

	-- needle with a soft glow
	local a = dialAngle(rpm, dial.maxR)
	local c, sn = cos(a), sin(a)
	local bx, by = cx - c * 16 * k, cy - sn * 16 * k
	local tx, ty = cx + c * (R - 22 * k), cy + sn * (R - 22 * k)
	for i = #needle, 1, -1 do
		needle[i] = nil
	end
	addThickLine(needle, bx, by, tx, ty, 12 * k, C.amberGlow)
	addThickLine(needle, bx, by, tx, ty, 4.5 * k, C.amber)
	drawPolys(needle)
	drawPolys(dial.hub)
end

---------------------------------------------------------------------------
-- HUD
---------------------------------------------------------------------------
local disp, blink, brk = 0, 0, 0

hook.Add("HUDPaint", "perpheads/audio-engine/hud", function()
	if not cvHud:GetBool() then return end
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	local veh = ply:GetVehicle()
	if not IsValid(veh) then return end
	local car = E.GetClientCar and E.GetClientCar(veh)
	if not car then return end

	local cfg, st = car.cfg, car.st
	local dt = RealFrameTime()
	disp = disp + (st.rpm - disp) * min(1, dt * 18)
	blink = blink + dt

	local s = ScrH() / 1080 * cvScale:GetFloat()
	makeFonts(s)
	draw.NoTexture()

	local pad = 18 * s
	local R = 120 * s
	local ledH = 9 * s
	local colW = 236 * s
	local W = pad + 2 * R + 22 * s + colW + pad
	local H = pad + ledH + 12 * s + 2 * R + pad
	local x = ScrW() - W - 32 * s
	local y = ScrH() - H - 32 * s

	draw.RoundedBox(floor(14 * s), x - 1, y - 1, W + 2, H + 2, C.line)
	draw.RoundedBox(floor(14 * s), x, y, W, H, C.panel)

	-- ignition prompt
	if not st.on or st.phase ~= "run" then
		local msg
		if not st.on then
			local cv = GetConVar("audio_engine_startkey")
			local key = string.upper(cv and cv:GetString() or "I")
			msg = (key == "" or key == "NONE") and "Engine off · audio_engine_toggle starts it"
				or ("Engine off · press " .. key .. " to start")
		else
			msg = "Starting…"
		end
		draw.SimpleText(
			msg,
			"AudioHud_Num",
			x + W / 2,
			y - 10 * s,
			st.on and C.amber or C.fg,
			TEXT_ALIGN_CENTER,
			TEXT_ALIGN_BOTTOM
		)
	end

	-- speed limiter (sv_cruise.lua): the limit, in the HUD's units
	local cruise = veh:GetNW2Float("audio_cruise", 0)
	if cruise > 0 and st.on and st.phase == "run" then
		local mphU = cvUnits:GetString() == "mph"
		local txt = mphU and string.format("LIMIT %d mph", math.floor(cruise + 0.5))
			or string.format("LIMIT %d km/h", math.floor(cruise * 1.609344 + 0.5))
		draw.SimpleText(txt, "AudioHud_Num", x + W - 10 * s, y - 10 * s, C.green, TEXT_ALIGN_RIGHT, TEXT_ALIGN_BOTTOM)
	end

	-- shift lights
	local frac = disp / cfg.redline
	local limiter = st.limHold > 0 or frac > 0.985
	local ledW, ledGap = 26 * s, 10 * s
	local cx = x + pad + R
	local lx = cx - (5 * ledW + 4 * ledGap) / 2
	for i = 1, 5 do
		local lit = limiter and (blink % 0.14 < 0.07) or (frac >= LED_AT[i])
		draw.RoundedBox(floor(3 * s), lx + (i - 1) * (ledW + ledGap), y + pad, ledW, ledH, lit and LED_COL[i] or C.line)
	end

	-- tach
	local cy = y + pad + ledH + 12 * s + R
	drawTach(cx, cy, R, disp, cfg)

	-- readouts
	local rx = x + pad + 2 * R + 22 * s
	local ry = y + pad
	local gap = 10 * s
	local gearW = 92 * s
	local topH = 160 * s

	-- gear
	box(rx, ry, gearW, topH, s)
	draw.SimpleText("GEAR", "AudioHud_Label", rx + 10 * s, ry + 8 * s, C.muted)
	local gear = "N"
	if not st.on then
		gear = "-"
	elseif st.phase ~= "run" then
		gear = "N"
	elseif st.gear == -1 then
		gear = "R"
	elseif st.gear > 0 then
		gear = tostring(st.gear)
	end
	draw.SimpleText(
		gear,
		"AudioHud_Gear",
		rx + gearW / 2,
		ry + topH / 2 + 8 * s,
		C.amber,
		TEXT_ALIGN_CENTER,
		TEXT_ALIGN_CENTER
	)

	-- speed
	local bx = rx + gearW + gap
	local bw = colW - gearW - gap
	local bh = (topH - gap) / 2
	local mph = cvUnits:GetString() == "mph"
	local speed = math.abs(car.v) * (mph and 2.23694 or 3.6)
	box(bx, ry, bw, bh, s)
	draw.SimpleText("SPEED", "AudioHud_Label", bx + 10 * s, ry + 8 * s, C.muted)
	surface.SetFont("AudioHud_Big")
	local sTxt = tostring(floor(speed + 0.5))
	local tw = surface.GetTextSize(sTxt)
	draw.SimpleText(sTxt, "AudioHud_Big", bx + 10 * s, ry + bh - 6 * s, C.fg, TEXT_ALIGN_LEFT, TEXT_ALIGN_BOTTOM)
	draw.SimpleText(
		mph and "mph" or "km/h",
		"AudioHud_Unit",
		bx + 14 * s + tw,
		ry + bh - 12 * s,
		C.muted,
		TEXT_ALIGN_LEFT,
		TEXT_ALIGN_BOTTOM
	)

	-- rpm
	local by2 = ry + bh + gap
	box(bx, by2, bw, bh, s)
	draw.SimpleText("ENGINE", "AudioHud_Label", bx + 10 * s, by2 + 8 * s, C.muted)
	surface.SetFont("AudioHud_Num")
	local rTxt = fmtThousands(disp)
	local rw = surface.GetTextSize(rTxt)
	draw.SimpleText(
		rTxt,
		"AudioHud_Num",
		bx + 10 * s,
		by2 + bh - 6 * s,
		frac >= 1 and C.red or C.fg,
		TEXT_ALIGN_LEFT,
		TEXT_ALIGN_BOTTOM
	)
	draw.SimpleText(
		"rpm",
		"AudioHud_Unit",
		bx + 14 * s + rw,
		by2 + bh - 10 * s,
		C.muted,
		TEXT_ALIGN_LEFT,
		TEXT_ALIGN_BOTTOM
	)

	-- throttle / brake
	local braking = (ply:KeyDown(IN_BACK) and car.v > 0.6)
		or (ply:KeyDown(IN_FORWARD) and car.v < -0.6)
		or ply:KeyDown(IN_JUMP)
	brk = brk + math.Clamp((braking and 1 or 0) - brk, -dt * 8, dt * 4)
	local ty = ry + topH + gap
	local th = y + H - pad - ty
	box(rx, ty, colW, th, s)
	local barW = colW - 20 * s
	local barH = 8 * s
	local thrPct = floor(st.thr * 100 + 0.5)
	local brkPct = floor(brk * 100 + 0.5)
	draw.SimpleText("THROTTLE " .. thrPct .. "%", "AudioHud_Label", rx + 10 * s, ty + 8 * s, C.muted)
	draw.RoundedBox(floor(4 * s), rx + 10 * s, ty + 26 * s, barW, barH, C.line)
	if thrPct > 0 then draw.RoundedBox(floor(4 * s), rx + 10 * s, ty + 26 * s, barW * st.thr, barH, C.amber) end
	draw.SimpleText("BRAKE " .. brkPct .. "%", "AudioHud_Label", rx + 10 * s, ty + 42 * s, C.muted)
	draw.RoundedBox(floor(4 * s), rx + 10 * s, ty + 60 * s, barW, barH, C.line)
	if brkPct > 0 then draw.RoundedBox(floor(4 * s), rx + 10 * s, ty + 60 * s, barW * brk, barH, C.red) end
end)

hook.Add("OnScreenSizeChanged", "perpheads/audio-engine/hud-fonts", function()
	fontScale = nil
end)
