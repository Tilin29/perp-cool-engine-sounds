--[[
	Audio Engine - in-game tuning menu (client)

	The Rev Bench controls for the car you're in (or looking at): engine presets, layout,
	pitch, exhaust tone, volume, realism, turbo, idle, redline, gear ratios and final drive.
	Apply sends the profile to the server, which shares it with everyone; each client then
	generates the new engine sound in the background.

	Open with: !engine in chat, `audio_engine_menu` in console, or right-click the car in the
	context menu (C) -> "Engine tuning".
]]

local E = AUDIO_ENGINE

local C = {
	bg = Color(15, 18, 22, 250),
	panel = Color(23, 27, 33, 255),
	face = Color(18, 21, 26, 255),
	line = Color(42, 48, 57, 255),
	fg = Color(232, 227, 214, 255),
	muted = Color(141, 147, 156, 255),
	amber = Color(255, 165, 61, 255),
	amberDim = Color(107, 71, 25, 255),
	red = Color(255, 75, 58, 255),
	green = Color(95, 211, 138, 255),
}

local frame
local floor = math.floor

local function makeFonts(s)
	local function f(name, size, weight)
		surface.CreateFont(name, { font = "Roboto", size = math.max(9, floor(size * s)), weight = weight, extended = true })
	end
	f("AudioMenu_Title", 30, 800)
	f("AudioMenu_H", 14, 700)
	f("AudioMenu_Body", 16, 500)
	f("AudioMenu_Small", 13, 500)
	f("AudioMenu_Num", 16, 700)
end

local function roundBox(r, x, y, w, h, fill, border)
	draw.RoundedBox(r, x, y, w, h, border or C.line)
	draw.RoundedBox(r, x + 1, y + 1, w - 2, h - 2, fill)
end

local function fmtThousands(n)
	local s = tostring(floor(n + 0.5))
	return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

local function ord(g)
	return g == 1 and "1st" or g == 2 and "2nd" or g == 3 and "3rd" or (g .. "th")
end

---------------------------------------------------------------------------
-- styled controls
---------------------------------------------------------------------------
local function label(parent, text, font, col)
	local l = vgui.Create("DLabel", parent)
	l:SetFont(font or "AudioMenu_Body")
	l:SetTextColor(col or C.fg)
	l:SetText(text)
	l:SizeToContents()
	return l
end

local function styleCombo(cb)
	cb:SetFont("AudioMenu_Body")
	cb:SetTextColor(C.fg)
	cb.Paint = function(self, w, h) roundBox(6, 0, 0, w, h, C.face) end
end

local function styleEntry(te)
	te:SetFont("AudioMenu_Num")
	te.Paint = function(self, w, h)
		roundBox(6, 0, 0, w, h, C.face, self:IsEditing() and C.amber or C.line)
		self:DrawTextEntryText(C.fg, C.amber, C.fg)
	end
end

local function slider(parent, s, text, minV, maxV, decimals, value, onChange, fmtFn)
	local row = vgui.Create("DPanel", parent)
	row:SetTall(floor(44 * s))
	row.Paint = nil
	local lbl = label(row, text)
	local out = label(row, "", "AudioMenu_Num", C.amber)
	local sl = vgui.Create("DSlider", row)
	sl:SetLockY(0.5)
	sl:SetTrapInside(true)
	sl.Paint = function(self, w, h)
		draw.RoundedBox(3, 0, h / 2 - 3, w, 6, C.line)
		draw.RoundedBox(3, 0, h / 2 - 3, w * self:GetSlideX(), 6, C.amberDim)
	end
	sl.Knob:SetSize(floor(14 * s), floor(14 * s))
	sl.Knob.Paint = function(self, w, h) draw.RoundedBox(w / 2, 0, 0, w, h, C.amber) end
	local function show(v)
		out:SetText(fmtFn and fmtFn(v) or string.format("%." .. decimals .. "f", v))
		out:SizeToContents()
		row:InvalidateLayout()
	end
	local cur = value
	sl:SetSlideX((value - minV) / (maxV - minV))
	show(value)
	sl.TranslateValues = function(self, x, y)
		local v = minV + (maxV - minV) * x
		local m = 10 ^ decimals
		v = floor(v * m + 0.5) / m
		if v ~= cur then
			cur = v
			show(v)
			onChange(v)
		end
		return (v - minV) / (maxV - minV), y
	end
	row.PerformLayout = function(self, w, h)
		lbl:SetPos(0, 0)
		out:SetPos(w - out:GetWide(), 0)
		sl:SetPos(0, lbl:GetTall() + 4)
		sl:SetSize(w, h - lbl:GetTall() - 4)
	end
	return row
end

local function checkbox(parent, text, value, onChange)
	local cb = vgui.Create("DCheckBoxLabel", parent)
	cb:SetText(text)
	cb:SetFont("AudioMenu_Body")
	cb:SetTextColor(C.fg)
	cb:SetValue(value and 1 or 0)
	cb.OnChange = function(_, v) onChange(v) end
	return cb
end

local function button(parent, text, primary, onClick)
	local b = vgui.Create("DButton", parent)
	b:SetText(text)
	b:SetFont("AudioMenu_H")
	b:SetTextColor(primary and Color(27, 18, 6) or C.fg)
	b.Paint = function(self, w, h)
		local fill = primary and C.amber or C.face
		if self:IsHovered() then fill = primary and Color(255, 185, 100) or C.line end
		roundBox(8, 0, 0, w, h, fill, primary and C.amber or C.line)
	end
	b.DoClick = onClick
	return b
end

local function card(parent, title, s)
	local p = vgui.Create("DPanel", parent)
	p.Paint = function(self, w, h)
		roundBox(12, 0, 0, w, h, C.panel)
		draw.SimpleText(string.upper(title), "AudioMenu_H", 16 * s, 14 * s, C.muted)
	end
	p:DockPadding(16 * s, 38 * s, 16 * s, 14 * s)
	return p
end

---------------------------------------------------------------------------
-- the menu
---------------------------------------------------------------------------
local function toneName(t)
	return t < 0.3 and "Stock" or t < 0.7 and "Sport" or "Straight pipe"
end

function E.OpenMenu(veh)
	local ply = LocalPlayer()
	if not IsValid(veh) then
		veh = ply:GetVehicle()
		if not (IsValid(veh) and E.GetCarConfig(veh)) then
			local tr = ply:GetEyeTrace()
			veh = tr.Entity
			if not (IsValid(veh) and tr.HitPos:DistToSqr(ply:GetShootPos()) < 300 * 300) then veh = nil end
		end
	end
	if not (IsValid(veh) and E.GetCarConfig(veh)) then
		chat.AddText(C.amber, "[Audio Engine] ", C.fg, "Sit in or look at a car with the procedural engine to tune its engine.")
		return
	end
	if IsValid(frame) then frame:Remove() end

	local car = E.GetCarConfig(veh)
	local cur = E.GetEngineConfig(veh).profile
	-- an editable copy
	local prof = {}
	for k, v in pairs(cur) do prof[k] = v end
	prof.gears = {}
	for i, r in ipairs(cur.gears) do prof.gears[i] = r end

	local s = math.Clamp(ScrH() / 1080, 0.7, 1.6)
	if 870 * s > ScrH() - 40 then s = (ScrH() - 40) / 870 end   -- always fits on screen
	makeFonts(s)
	local W, H = floor(1000 * s), floor(870 * s)
	frame = vgui.Create("DFrame")
	frame:SetSize(W, H)
	frame:Center()
	frame:SetTitle("")
	frame:ShowCloseButton(false)
	frame:SetDraggable(true)
	frame:MakePopup()
	frame:DockPadding(20 * s, 20 * s, 20 * s, 16 * s)
	frame.Paint = function(self, w, h)
		roundBox(16, 0, 0, w, h, C.bg)
	end

	-- header
	local head = vgui.Create("DPanel", frame)
	head:Dock(TOP)
	head:SetTall(floor(54 * s))
	head.Paint = function(self, w, h)
		surface.SetFont("AudioMenu_Title")
		local tw = surface.GetTextSize("REV")
		draw.SimpleText("REV", "AudioMenu_Title", 0, 0, C.fg)
		draw.SimpleText("·", "AudioMenu_Title", tw + 2 * s, 0, C.amber)
		local dw = surface.GetTextSize("·")
		draw.SimpleText("BENCH", "AudioMenu_Title", tw + dw + 4 * s, 0, C.fg)
		draw.SimpleText(car.name .. " · engine generated live on every client", "AudioMenu_Small", 0, 34 * s, C.muted)
	end
	local close = button(head, "✕", false, function() frame:Remove() end)
	close:SetSize(floor(34 * s), floor(34 * s))
	head.PerformLayout = function(self, w) close:SetPos(w - close:GetWide(), 0) end

	-- preset row
	local row = vgui.Create("DPanel", frame)
	row:Dock(TOP)
	row:SetTall(floor(38 * s))
	row:DockMargin(0, 6 * s, 0, 14 * s)
	row.Paint = nil
	local presetBox = vgui.Create("DComboBox", row)
	styleCombo(presetBox)
	presetBox:Dock(LEFT)
	presetBox:SetWide(floor(380 * s))
	local applyBtn = button(row, "Apply to car", true, nil)
	applyBtn:Dock(RIGHT)
	applyBtn:SetWide(floor(150 * s))
	local stockBtn = button(row, "Back to stock", false, nil)
	stockBtn:Dock(RIGHT)
	stockBtn:SetWide(floor(140 * s))
	stockBtn:DockMargin(0, 0, 10 * s, 0)

	local body = vgui.Create("DPanel", frame)
	body:Dock(FILL)
	body.Paint = nil

	local footer = label(frame, "", "AudioMenu_Small", C.muted)
	footer:Dock(BOTTOM)
	footer:DockMargin(0, 10 * s, 0, 0)
	footer:SetTall(floor(18 * s))

	local stats = {}  -- labels refreshed on every change
	local rebuild

	-- the car with its real (stock) top speed filled in
	local carEff = {}
	for k, v in pairs(car) do carEff[k] = v end
	carEff.topSpeed = E.CarTopSpeed(veh, car)

	local function refreshStats()
		local cfg = E.ResolveProfile(carEff, E.SanitizeProfile(prof))
		local cyl = E.LAYOUT_CYL[prof.layout] or 4
		local fIdle = prof.idle / 60 * cyl / 2 * prof.pitch
		local fRed = prof.redline / 60 * cyl / 2 * prof.pitch
		if stats.engine then
			local what
			if prof.layout == "electric" then
				what = string.format("Electric motor · up to %s rpm", fmtThousands(prof.redline))
			elseif prof.layout == "rotary2" or prof.layout == "rotary3" then
				what = string.format("%d rotors · fires %d Hz at idle, %d Hz at redline", prof.layout == "rotary2" and 2 or 3, fIdle, fRed)
			else
				what = string.format("%d cylinders · fires %d Hz at idle, %d Hz at redline", cyl, fIdle, fRed)
			end
			stats.engine:SetText(string.format("%s\n%d loops to generate (~%.1f s of CPU per player)",
				what, #cfg.bands * 2 + 6, 0.13 * #cfg.bands + 0.4))
		end
		if stats.gears then
			local K = 60 / (2 * math.pi * car.wheelRadius)
			local parts = {}
			for i, r in ipairs(cfg.gears) do   -- the gears the box uses (a slow car drops its top ones)
				parts[#parts + 1] = string.format("%s %d", ord(i), prof.redline / (K * r * cfg.final) * 2.23694)
			end
			stats.gears:SetText("Top speed per gear (mph): " .. table.concat(parts, " · "))
		end
		if stats.final then
			stats.final:SetText(prof.fit > 0 and string.format("Final drive %.2f (fitted)", cfg.final) or "Final drive")
			stats.final:SizeToContents()
		end
		local p = E.EnginePreset(prof.preset)
		presetBox:SetText(p and p.name or "Custom engine")
	end

	local function changed()
		prof.preset = "custom"
		refreshStats()
	end

	rebuild = function()
		body:Clear()
		stats = {}
		local colW = floor((W - 40 * s - 2 * 14 * s) / 3)

		-------------------------------------------------- Sound
		local snd = card(body, "Sound", s)
		snd:Dock(LEFT)
		snd:SetWide(colW)
		local l = label(snd, "Engine layout")
		l:Dock(TOP)
		local lay = vgui.Create("DComboBox", snd)
		styleCombo(lay)
		lay:Dock(TOP)
		lay:SetTall(floor(30 * s))
		lay:DockMargin(0, 4 * s, 0, 10 * s)
		for _, o in ipairs(E.LAYOUT_ORDER) do lay:AddChoice(o[2], o[1], o[1] == prof.layout) end
		lay.OnSelect = function(_, _, _, key) prof.layout = key; changed(); timer.Simple(0, rebuild) end
		local function add(p) p:Dock(TOP); p:DockMargin(0, 0, 0, 6 * s) end
		add(slider(snd, s, "Pitch", 0.5, 2, 2, prof.pitch, function(v) prof.pitch = v; changed() end, function(v) return string.format("×%.2f", v) end))
		add(slider(snd, s, "Exhaust tone", 0, 1, 2, prof.tone, function(v) prof.tone = v; changed() end, toneName))
		add(slider(snd, s, "Volume", 0, 1.5, 2, prof.volume, function(v) prof.volume = v; changed() end, function(v) return floor(v * 100 + 0.5) .. "%" end))
		add(slider(snd, s, "Realism", 0, 1, 1, prof.realism, function(v) prof.realism = v; changed() end,
			function(v) return v == 0 and "Rev Bench" or v < 1 and string.format("%d%%", v * 100) or "Full" end))
		add(slider(snd, s, "Gurgle (off-throttle burble)", 0, 1, 2, prof.gurgle, function(v) prof.gurgle = v; changed() end,
			function(v) return v <= 0 and "Off" or v < 0.3 and "Light" or v < 0.65 and "Burbly" or "Heavy" end))
		add(slider(snd, s, "Pops & bangs (how often)", 0, 1, 2, prof.pops, function(v) prof.pops = v; changed() end,
			function(v) return v <= 0 and "Off" or v < 0.25 and "Rare" or v < 0.5 and "Occasional" or v < 0.8 and "Frequent" or "Constant" end))
		add(slider(snd, s, "Pops & bangs volume", 0, 2, 2, prof.popVol, function(v) prof.popVol = v; changed() end,
			function(v) return floor(v * 100 + 0.5) .. "%" end))
		add(slider(snd, s, "Pops & bangs tone", 0, 1, 2, prof.popTone, function(v) prof.popTone = v; changed() end,
			function(v) return v < 0.25 and "Muffled" or v < 0.6 and "Sport" or v < 0.85 and "Loud pipe" or "Straight pipe" end))
		local tb = checkbox(snd, "Turbocharged (whistle)", prof.turbo, function(v) prof.turbo = v; changed(); timer.Simple(0, rebuild) end)
		tb:Dock(TOP)
		tb:DockMargin(0, 6 * s, 0, 0)
		if prof.turbo then
			local pct = function(v) return floor(v * 100 + 0.5) .. "%" end
			local tv = slider(snd, s, "Turbo whistle volume", 0, 2, 2, prof.turboVol or 1, function(v) prof.turboVol = v; changed() end, pct)
			tv:Dock(TOP)
			tv:DockMargin(0, 6 * s, 0, 0)
			local bv = checkbox(snd, "Blow-off valve (pssh when you lift)", prof.bov, function(v) prof.bov = v; changed(); timer.Simple(0, rebuild) end)
			bv:Dock(TOP)
			bv:DockMargin(0, 6 * s, 0, 0)
			if prof.bov then
				local bvv = slider(snd, s, "Blow-off valve volume", 0, 2, 2, prof.bovVol or 1, function(v) prof.bovVol = v; changed() end, pct)
				bvv:Dock(TOP)
				bvv:DockMargin(0, 6 * s, 0, 0)
			end
		end

		-------------------------------------------------- RPM
		local rpm = card(body, "RPM & performance", s)
		rpm:Dock(LEFT)
		rpm:SetWide(colW)
		rpm:DockMargin(14 * s, 0, 0, 0)
		local add2 = function(p) p:Dock(TOP); p:DockMargin(0, 0, 0, 6 * s) end
		add2(slider(rpm, s, "Idle", 500, 1500, 0, prof.idle, function(v) prof.idle = floor(v / 25 + 0.5) * 25; changed() end,
			function(v) return fmtThousands(floor(v / 25 + 0.5) * 25) end))
		add2(slider(rpm, s, "Redline", 3500, prof.layout == "electric" and 16000 or 12000, 0, prof.redline, function(v) prof.redline = floor(v / 100 + 0.5) * 100; changed() end,
			function(v) return fmtThousands(floor(v / 100 + 0.5) * 100) end))
		-- real performance: changes how the car actually drives; the revs and gears follow
		add2(slider(rpm, s, "Acceleration", 0.5, 2.5, 2, prof.accel, function(v) prof.accel = floor(v * 20 + 0.5) / 20; changed() end,
			function(v) return string.format("×%.2f", floor(v * 20 + 0.5) / 20) end))
		-- shown in mph (the profile keeps km/h): steps of 5 mph, snapping to the car's stock speed
		local KMH_PER_MPH = 1.609344
		local stockMph = floor(E.CarTopSpeed(veh, car) / KMH_PER_MPH + 0.5)
		local function snapMph(v)
			v = floor(v + 0.5)
			if math.abs(v - stockMph) < 3 then return stockMph, true end
			return floor(v / 5 + 0.5) * 5, false
		end
		add2(slider(rpm, s, "Top speed", 25, 280, 0, prof.vmax > 0 and prof.vmax / KMH_PER_MPH or stockMph, function(v)
			local mph, stock = snapMph(v)
			prof.vmax = stock and 0 or floor(mph * KMH_PER_MPH + 0.5)
			changed()
		end, function(v)
			local mph, stock = snapMph(v)
			return stock and (mph .. " mph (stock)") or (mph .. " mph")
		end))
		stats.engine = label(rpm, "", "AudioMenu_Small", C.muted)
		stats.engine:Dock(TOP)
		stats.engine:DockMargin(0, 8 * s, 0, 0)
		stats.engine:SetWrap(true)
		stats.engine:SetAutoStretchVertical(true)
		local note = label(rpm, "Acceleration and top speed change the car's real physics; the revs, gears and sound follow.", "AudioMenu_Small", C.muted)
		note:Dock(BOTTOM)
		note:SetWrap(true)
		note:SetAutoStretchVertical(true)

		-- generation quality: a setting of this client only (audio_engine_samplerate)
		local ql = label(rpm, "Sound quality (your PC only)")
		ql:Dock(TOP)
		ql:DockMargin(0, 14 * s, 0, 0)
		local q = vgui.Create("DComboBox", rpm)
		styleCombo(q)
		q:Dock(TOP)
		q:SetTall(floor(30 * s))
		q:DockMargin(0, 4 * s, 0, 0)
		local rate = GetConVar("audio_engine_samplerate")
		local cur = rate and rate:GetInt() or 44100
		q:AddChoice("44.1 kHz (best, ~2 s per engine)", 44100, cur ~= 22050)
		q:AddChoice("22.05 kHz (twice as fast, half the memory)", 22050, cur == 22050)
		q.OnSelect = function(_, _, _, v)
			-- changing it regenerates every engine sound at the new rate
			RunConsoleCommand("audio_engine_samplerate", tostring(v))
		end

		-------------------------------------------------- Gearbox
		local gb = card(body, "Gear ratios", s)
		gb:Dock(FILL)
		gb:DockMargin(14 * s, 0, 0, 0)
		local top = vgui.Create("DPanel", gb)
		top:Dock(TOP)
		top:SetTall(floor(30 * s))
		top.Paint = nil
		local gp = vgui.Create("DComboBox", top)
		styleCombo(gp)
		gp:Dock(FILL)
		gp:SetValue("Gearbox preset…")
		for _, g in ipairs(E.GEAR_PRESETS) do gp:AddChoice(g.name, g.id) end
		gp.OnSelect = function(_, _, _, id)
			local g = E.GearPreset(id)
			prof.gears = {}
			for i, r in ipairs(g.gears) do prof.gears[i] = r end
			prof.final = g.final
			prof.preset = "custom"
			rebuild()
		end
		local ng = vgui.Create("DNumberWang", top)
		ng:Dock(RIGHT)
		ng:SetWide(floor(56 * s))
		ng:DockMargin(8 * s, 0, 0, 0)
		ng:SetMinMax(1, 8)
		ng:SetDecimals(0)
		ng:SetValue(#prof.gears)
		styleEntry(ng)
		ng.OnValueChanged = function(_, v)
			v = math.Clamp(floor(tonumber(v) or 6), 1, 8)
			if v == #prof.gears then return end
			while #prof.gears < v do prof.gears[#prof.gears + 1] = floor(prof.gears[#prof.gears] * 84 + 0.5) / 100 end
			while #prof.gears > v do prof.gears[#prof.gears] = nil end
			prof.preset = "custom"
			timer.Simple(0, rebuild)
		end

		local grid = vgui.Create("DIconLayout", gb)
		grid:Dock(TOP)
		grid:DockMargin(0, 10 * s, 0, 0)
		grid:SetSpaceX(8 * s)
		grid:SetSpaceY(6 * s)
		local cellW = floor((colW - 32 * s - 8 * s) / 2)
		for i = 1, #prof.gears do
			local cell = grid:Add("DPanel")
			cell:SetSize(cellW, floor(28 * s))
			cell.Paint = nil
			local gl = label(cell, ord(i), "AudioMenu_Small", C.muted)
			gl:SetPos(0, 6 * s)
			local te = vgui.Create("DTextEntry", cell)
			styleEntry(te)
			te:SetNumeric(true)
			te:SetPos(floor(40 * s), 0)
			te:SetSize(cellW - floor(40 * s), floor(28 * s))
			te:SetValue(string.format("%.2f", prof.gears[i]))
			te:SetUpdateOnType(true)
			te.OnValueChange = function(_, v)
				local n = tonumber(v)
				if n and n >= 0.3 and n <= 8 then prof.gears[i] = n; changed() end
			end
		end

		local finRow = vgui.Create("DPanel", gb)
		finRow:Dock(TOP)
		finRow:SetTall(floor(28 * s))
		finRow:DockMargin(0, 10 * s, 0, 0)
		finRow.Paint = nil
		stats.final = label(finRow, "Final drive", "AudioMenu_Small", C.muted)
		stats.final:SetPos(0, 6 * s)
		local fin = vgui.Create("DTextEntry", finRow)
		styleEntry(fin)
		fin:SetNumeric(true)
		fin:Dock(RIGHT)
		fin:SetWide(cellW - floor(40 * s))
		fin:SetValue(string.format("%.2f", prof.final))
		fin:SetUpdateOnType(true)
		fin:SetEnabled(prof.fit == 0)
		fin.OnValueChange = function(_, v)
			local n = tonumber(v)
			if n and n >= 2 and n <= 6 then prof.final = n; changed() end
		end

		local fitCb = checkbox(gb, "Fit gearing to the top speed (uses every gear)", prof.fit > 0, function(v)
			prof.fit = v and 1 or 0
			changed()
			timer.Simple(0, rebuild)
		end)
		fitCb:Dock(TOP)
		fitCb:DockMargin(0, 10 * s, 0, 4 * s)
		stats.gears = label(gb, "", "AudioMenu_Small", C.muted)
		stats.gears:Dock(TOP)
		stats.gears:DockMargin(0, 8 * s, 0, 0)
		stats.gears:SetWrap(true)
		stats.gears:SetAutoStretchVertical(true)

		refreshStats()
	end

	for _, p in ipairs(E.ENGINE_PRESETS) do presetBox:AddChoice(p.name, p.id) end
	presetBox:AddChoice("Custom engine", "custom")
	presetBox.OnSelect = function(_, _, _, id)
		if id == "custom" then return end
		-- switching engines keeps the performance settings
		local accel, vmax = prof.accel, prof.vmax
		prof = E.ProfileFromPreset(id)
		prof.accel, prof.vmax = accel, vmax
		rebuild()
	end

	local function send(str)
		if not IsValid(veh) then return end
		net.Start("audio_engine_set")
		net.WriteEntity(veh)
		net.WriteString(str)
		net.SendToServer()
	end
	applyBtn.DoClick = function()
		send(E.EncodeProfile(prof))
		surface.PlaySound("buttons/button14.wav")
	end
	stockBtn.DoClick = function()
		send("")
		prof = E.CarStockProfile(car)
		rebuild()
	end

	local access = GetConVar("audio_engine_tuneaccess")
	local a = access and access:GetInt() or 1
	local allowed = a == 0 or (a == 1 and ply:IsAdmin()) or (a >= 2 and ply:IsSuperAdmin())
	footer:SetText(allowed
		and "Applies to this car for everyone. A new engine takes a few seconds to generate; the old sound keeps playing until it's ready."
		or "Only " .. (a >= 2 and "superadmins" or "admins") .. " can apply engine changes on this server. You can still try settings here.")
	footer:SetTextColor(allowed and C.muted or C.red)

	rebuild()
end

concommand.Add("audio_engine_menu", function() E.OpenMenu() end, nil, "Open the engine tuning menu")

-- right-click the car in the context menu (sandbox-based gamemodes)
if properties and properties.Add then
	properties.Add("audio_engine_tune", {
		MenuLabel = "Engine tuning",
		Order = 2000,
		MenuIcon = "icon16/car.png",
		Filter = function(self, ent, ply) return IsValid(ent) and E.GetCarConfig(ent) ~= nil end,
		Action = function(self, ent) E.OpenMenu(ent) end,
	})
end
