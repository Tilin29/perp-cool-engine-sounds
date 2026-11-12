--[[
	Audio Engine debug module - the debug menu (client). Not part of the final addon (see sh_debug.lua).

	audio_engine_debug_menu (or !enginedebug, or right-click a car in the context menu), on the car
	you sit in or look at. Superadmins, while audio_engine_debug is 1 (the default). Pages:

	  Handling script  the car's vehicle script: edit its values, apply them to the car live, copy
	                   the txt (or save it to data/audio_engine_debug/scripts/) for PERP's script pack
	  Gearing          how many gears and where each changes up / down, by speed and rpm; applied
	                   live for everyone; copies an E.CAR_GEARING entry for sh_carlist.lua
	  Rev response     how fast the revs climb and drop back standing still (Space + W), this car or
	                   every car; copies an E.CAR_REV entry or the DT.REV line
	  Handling         the addon's handling changes on / off (all off = PERP's own handling) and
	                   their main values live
	  Settings         the client and server convars and test commands as controls
]]

local E = AUDIO_ENGINE
local DBG = E.Debug
local KV = E.KV
local DT = E.Drivetrain

local floor, max, min = math.floor, math.max, math.min
local MS_PER_MPH = 0.44704

local C = {
	bg = Color(18, 21, 26, 252), panel = Color(26, 30, 37), face = Color(34, 39, 47), line = Color(52, 58, 68),
	fg = Color(232, 227, 214), muted = Color(150, 156, 165), amber = Color(255, 165, 61), amberDim = Color(120, 80, 30),
	red = Color(255, 90, 70), green = Color(95, 211, 138), blue = Color(110, 170, 255),
}

local frame, status
local target          -- the car the menu works on
local state = { cvars = {}, tunables = {} }
local onState = {}    -- pages that follow the server state
local scriptData      -- the target's vehicle script (from the server)
local onScript

local function fmtK(n)
	local s = tostring(floor(n + 0.5))
	return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end
local function ord(g)
	return g == 1 and "1st" or g == 2 and "2nd" or g == 3 and "3rd" or (g .. "th")
end

local function say(ok, msg)
	if IsValid(status) then
		status:SetText(msg)
		status:SetTextColor(ok and C.green or C.red)
	end
	chat.AddText(C.amber, "[Audio Engine debug] ", ok and C.fg or C.red, msg)
end

---------------------------------------------------------------------------
-- controls
---------------------------------------------------------------------------
local function label(parent, text, col, font)
	local l = vgui.Create("DLabel", parent)
	l:SetFont(font or "DermaDefault")
	l:SetText(text)
	l:SetTextColor(col or C.fg)
	l:SizeToContents()
	return l
end

local function para(parent, text, col)
	local l = label(parent, text, col or C.muted)
	l:Dock(TOP)
	l:DockMargin(0, 2, 0, 6)
	l:SetWrap(true)
	l:SetAutoStretchVertical(true)
	return l
end

local function heading(parent, text)
	local l = label(parent, text, C.amber, "DermaDefaultBold")
	l:Dock(TOP)
	l:DockMargin(0, 10, 0, 4)
	return l
end

local function button(parent, text, fn, primary)
	local b = vgui.Create("DButton", parent)
	b:SetText(text)
	b:SetTextColor(primary and Color(27, 18, 6) or C.fg)
	b.Paint = function(self, w, h)
		local fill = primary and C.amber or C.face
		if self:IsHovered() then fill = primary and Color(255, 190, 110) or C.line end
		draw.RoundedBox(4, 0, 0, w, h, fill)
	end
	b.DoClick = fn
	surface.SetFont("DermaDefault")
	b:SetWide(surface.GetTextSize(text) + 24)
	return b
end

-- a row of buttons
local function buttonRow(parent)
	local r = vgui.Create("DPanel", parent)
	r:Dock(TOP)
	r:SetTall(26)
	r:DockMargin(0, 4, 0, 4)
	r.Paint = nil
	r.Add = function(self, text, fn, primary)
		local b = button(self, text, fn, primary)
		b:Dock(LEFT)
		b:DockMargin(0, 0, 6, 0)
		return b
	end
	return r
end

local function slider(parent, text, lo, hi, dec, value, onChange)
	local s = vgui.Create("DNumSlider", parent)
	s:Dock(TOP)
	s:SetTall(26)
	s:SetText(text)
	s:SetMinMax(lo, hi)
	s:SetDecimals(dec)
	s.quiet = true
	s:SetValue(value)
	s.quiet = false
	s.Label:SetTextColor(C.fg)
	s.Label:SetWide(260)
	s.TextArea:SetTextColor(C.amber)
	s.OnValueChanged = function(self, v)
		if self.quiet then return end
		onChange(v)
	end
	s.Set = function(self, v) self.quiet = true; self:SetValue(v); self.quiet = false end
	return s
end

local function check(parent, text, value, onChange)
	local c = vgui.Create("DCheckBoxLabel", parent)
	c:Dock(TOP)
	c:DockMargin(0, 3, 0, 3)
	c:SetText(text)
	c:SetTextColor(C.fg)
	c:SetChecked(value and true or false)
	c.OnChange = function(self, v) if not self.quiet then onChange(v) end end
	c.Set = function(self, v) self.quiet = true; self:SetChecked(v and true or false); self.quiet = false end
	return c
end

local function scroll(parent)
	local s = vgui.Create("DScrollPanel", parent)
	s:Dock(FILL)
	s:GetCanvas():DockPadding(8, 4, 12, 8)
	return s
end

---------------------------------------------------------------------------
-- talking to the server
---------------------------------------------------------------------------
-- a slider being dragged sends once it rests for a moment, not every step
local function debounce(id, fn) timer.Create("audio_dbg_" .. id, 0.25, 1, fn) end

local function sendCvars(list)
	net.Start("audio_dbg_cvar")
	net.WriteUInt(#list, 4)
	for _, c in ipairs(list) do net.WriteString(c[1]); net.WriteString(tostring(c[2])) end
	net.SendToServer()
end

local function requestState() net.Start("audio_dbg_state_req") net.SendToServer() end

local function requestScript()
	if not IsValid(target) then return end
	net.Start("audio_dbg_script_req")
	net.WriteEntity(target)
	net.SendToServer()
end

net.Receive("audio_dbg_result", function()
	local ok, msg = net.ReadBool(), net.ReadString()
	say(ok, msg)
end)

net.Receive("audio_dbg_state", function()
	local n = net.ReadUInt(8)
	for _ = 1, n do
		local name, v = net.ReadString(), net.ReadString()
		state.cvars[name] = v
	end
	local m = net.ReadUInt(8)
	for i = 1, m do state.tunables[i] = net.ReadFloat() end
	for _, fn in pairs(onState) do fn() end
end)

net.Receive("audio_dbg_script", function()
	local veh = net.ReadEntity()
	local path, fallback = net.ReadString(), net.ReadBool()
	local len = net.ReadUInt(16)
	local raw = util.Decompress(net.ReadData(len)) or ""
	local current, fileText = raw:match("^(.-)%z(.*)$")
	local live = {}
	for _ = 1, net.ReadUInt(12) do live[net.ReadUInt(12)] = true end
	if not current then return end
	local entries = KV.Parse(current)
	local values = {}
	for _, e in ipairs(entries) do values[e.idx] = e.value end
	scriptData = {
		veh = veh, path = path, fallback = fallback, fileText = fileText, fileEntries = KV.Parse(fileText),
		applied = values, values = table.Copy(values), entries = entries, live = live,
	}
	if onScript then onScript() end
end)

---------------------------------------------------------------------------
-- page: handling script
---------------------------------------------------------------------------
local function scriptText()
	return KV.Rebuild(scriptData.fileText, scriptData.fileEntries, scriptData.values)
end

local function buildScriptPage(pnl)
	local top = vgui.Create("DPanel", pnl)
	top:Dock(TOP)
	top:DockPadding(8, 6, 8, 0)
	top.Paint = nil
	local info = para(top, "Loading the car's vehicle script...", C.fg)
	local warn = para(top, "", C.red)
	local bar = buttonRow(top)
	local filterRow = vgui.Create("DPanel", top)
	filterRow:Dock(TOP)
	filterRow:SetTall(22)
	filterRow.Paint = nil
	local fl = label(filterRow, "Filter:", C.muted)
	fl:Dock(LEFT)
	fl:DockMargin(0, 0, 6, 0)
	local filter = vgui.Create("DTextEntry", filterRow)
	filter:Dock(LEFT)
	filter:SetWide(200)
	local showSounds = vgui.Create("DCheckBoxLabel", filterRow)
	showSounds:Dock(LEFT)
	showSounds:DockMargin(12, 3, 0, 0)
	showSounds:SetText("Show sound blocks")
	showSounds:SetTextColor(C.fg)
	showSounds:SetWide(140)
	local count = label(filterRow, "", C.muted)
	count:Dock(FILL)
	count:DockMargin(12, 0, 0, 0)
	top:SetTall(150)

	local list = scroll(pnl)
	local rows = {}

	local function refreshCount()
		if not scriptData then count:SetText("") return end
		local fromFile, pending = 0, 0
		for _, e in ipairs(scriptData.fileEntries) do
			if scriptData.values[e.idx] ~= e.value then fromFile = fromFile + 1 end
			if scriptData.values[e.idx] ~= scriptData.applied[e.idx] then pending = pending + 1 end
		end
		count:SetText(string.format("%d value%s changed from the file · %d not applied yet", fromFile, fromFile == 1 and "" or "s", pending))
		count:SetTextColor(pending > 0 and C.amber or C.muted)
	end

	local function rebuild()
		list:Clear()
		rows = {}
		if not scriptData then return end
		local f = filter:GetValue():lower()
		local lastLabel
		for _, e in ipairs(scriptData.entries) do
			local sound = e.path:find("sound", 1, true) ~= nil
			local hit = f == "" or e.lkey:find(f, 1, true) or e.label:lower():find(f, 1, true)
			if hit and (showSounds:GetChecked() or not sound) then
				if e.label ~= lastLabel then
					lastLabel = e.label
					local h = label(list, e.label == "" and "vehicle" or e.label, C.amber, "DermaDefaultBold")
					h:Dock(TOP)
					h:DockMargin(0, 8, 0, 2)
				end
				local row = vgui.Create("DPanel", list)
				row:Dock(TOP)
				row:SetTall(22)
				row:DockMargin(0, 1, 0, 1)
				row.Paint = nil
				local k = label(row, e.key .. (e.occ > 1 and ("  #" .. e.occ) or ""), C.fg)
				k:Dock(LEFT)
				k:SetWide(230)
				local te = vgui.Create("DTextEntry", row)
				te:Dock(LEFT)
				te:SetWide(150)
				te:SetValue(scriptData.values[e.idx])
				local fileVal = scriptData.fileEntries[e.idx] and scriptData.fileEntries[e.idx].value
				te.Paint = function(self, w, h)
					local v = self:GetValue()
					local bg = not KV.ValidValue(v) and Color(90, 30, 30) or v ~= fileVal and Color(70, 52, 25) or C.face
					draw.RoundedBox(3, 0, 0, w, h, bg)
					self:DrawTextEntryText(C.fg, C.amber, C.fg)
				end
				te.OnChange = function(self)
					local v = self:GetValue()
					if KV.ValidValue(v) then scriptData.values[e.idx] = v end
					refreshCount()
				end
				local mk = label(row, scriptData.live[e.idx] and "live" or "respawn", scriptData.live[e.idx] and C.green or C.muted)
				mk:Dock(LEFT)
				mk:SetWide(60)
				mk:DockMargin(8, 0, 0, 0)
				if e.comment then
					local cm = label(row, "// " .. e.comment, C.muted)
					cm:Dock(FILL)
				end
				rows[e.idx] = te
			end
		end
		refreshCount()
	end
	filter.OnChange = function() rebuild() end
	showSounds.OnChange = function() rebuild() end

	onScript = function()
		if not (scriptData and IsValid(info)) then return end
		local car = IsValid(scriptData.veh) and E.GetCarConfig(scriptData.veh)
		info:SetText(string.format("%s  ·  %s", car and car.name or "?", scriptData.path))
		warn:SetText(scriptData.fallback and ("PERP's vehicle scripts aren't mounted here: this is test_car.txt carrying PERP's physics values for "
			.. scriptData.path .. " (what the car drives on). Its sounds, materials and other fields are test_car's, not PERP's file.") or "")
		rebuild()
	end

	bar:Add("Apply live", function()
		if not (scriptData and IsValid(scriptData.veh)) then return end
		local data = util.Compress(scriptText()) or ""
		net.Start("audio_dbg_script_apply")
		net.WriteEntity(scriptData.veh)
		net.WriteUInt(#data, 16)
		net.WriteData(data, #data)
		net.SendToServer()
	end, true)
	bar:Add("Copy txt", function()
		if not scriptData then return end
		SetClipboardText(scriptText())
		say(true, "Copied " .. scriptData.path .. " to the clipboard.")
	end)
	bar:Add("Save to data/", function()
		if not scriptData then return end
		local rel = "audio_engine_debug/scripts/" .. scriptData.path:gsub("^scripts/vehicles/", "")
		file.CreateDir(string.GetPathFromFilename(rel))
		file.Write(rel, scriptText())
		say(true, "Saved to garrysmod/data/" .. rel)
	end)
	bar:Add("Undo unapplied", function()
		if not scriptData then return end
		scriptData.values = table.Copy(scriptData.applied)
		rebuild()
	end)
	bar:Add("Reset car to file", function()
		if not (scriptData and IsValid(scriptData.veh)) then return end
		net.Start("audio_dbg_script_apply")
		net.WriteEntity(scriptData.veh)
		net.WriteUInt(0, 16)
		net.SendToServer()
	end)
	bar:Add("Reload", requestScript)

	if scriptData and scriptData.veh == target then onScript() else requestScript() end
end

---------------------------------------------------------------------------
-- page: gearing
---------------------------------------------------------------------------
local function buildGearPage(pnl)
	local spec, base, preview
	local K = 1

	local function prepare()
		base = IsValid(target) and DBG.BaseConfig(target)
		if not base then return false end
		K = 60 / (2 * math.pi * base.wheelRadius)
		return true
	end
	local function recompute()
		preview = {}
		for k, v in pairs(base) do preview[k] = v end
		E.ApplyGearing(preview, spec)
	end
	local function ratio(i) return preview.gears[i] * preview.final end
	local function rpmAt(i, mph) return mph * MS_PER_MPH * K * ratio(i) end
	-- the speed where gear i changes up flat out (top gear: the top speed)
	local function upMph(i)
		if i >= #preview.gears then return preview.topSpeed / 1.609344 end
		return preview.shiftPlan.up[i] / (K * ratio(i)) / MS_PER_MPH
	end
	local topMph = function() return base.topSpeed / 1.609344 end

	local function autoSpace(n)
		local red = base.redline
		local s = { topRpm = floor(red * E.TopGearShare(red) + 0.5) }
		if n >= 2 then
			local ends = E.FitGearEnds(base.topSpeed, n, red, base.powerKg, n)
			for i = 1, n - 1 do
				s[i] = { rpm = floor(red * E.GEAR_FIT.upShare / 50 + 0.5) * 50, mph = floor(ends[i] * E.GEAR_FIT.upShare / 1.609344 * 10 + 0.5) / 10 }
			end
		end
		s[n] = {}
		return s
	end

	local head = vgui.Create("DPanel", pnl)
	head:Dock(TOP)
	head:SetTall(64)
	head:DockPadding(8, 6, 8, 0)
	head.Paint = nil
	local info = para(head, "", C.fg)
	local bar = buttonRow(head)

	local chart = vgui.Create("DPanel", pnl)
	chart:Dock(TOP)
	chart:SetTall(200)
	chart:DockMargin(8, 0, 8, 4)

	local list = scroll(pnl)
	local infoLabels = {}

	local function refreshInfo()
		if not (preview and IsValid(info)) then return end
		local n = #preview.gears
		for i = 1, n do
			local l = infoLabels[i]
			if IsValid(l) then
				local parts = {}
				local col = C.muted
				if i < n then
					local up = preview.shiftPlan.up[i]
					local v = upMph(i)
					local land = rpmAt(i + 1, v)
					local drop = 1 - land / up
					parts[#parts + 1] = string.format("Changes up at %.0f mph, %s rpm -> %s rpm in %s (-%d%%)", v, fmtK(up), fmtK(land), ord(i + 1), floor(drop * 100 + 0.5))
					if drop < 0.12 then
						parts[#parts + 1] = "barely audible: space this gear further"
						col = C.red
					elseif drop > 0.45 then
						parts[#parts + 1] = "a big step: the revs fall a long way"
						col = C.amber
					end
				else
					parts[#parts + 1] = string.format("Top gear: %s rpm at %.0f mph (redline at %.0f mph)", fmtK(rpmAt(i, topMph())), topMph(),
						base.redline / (K * ratio(i)) / MS_PER_MPH)
				end
				local d = preview.shiftPlan.down[i]
				if d then
					parts[#parts + 1] = string.format("down to %s under %.0f mph (%s -> %s rpm)", ord(i - 1), d / MS_PER_MPH,
						fmtK(d * K * ratio(i)), fmtK(d * K * ratio(i - 1)))
				elseif i > 1 then
					parts[#parts + 1] = "down: default points"
				end
				l:SetText(table.concat(parts, "  ·  "))
				l:SetTextColor(col)
			end
		end
		if not IsValid(target) then return end
		info:SetText(string.format("%s · redline %s rpm · top speed %.0f mph · %d gears%s", E.GetCarConfig(target).name,
			fmtK(base.redline), topMph(), n, target:GetNW2String("audio_dbg_gear", "") ~= "" and " · live override on" or ""))
	end

	chart.Paint = function(self, w, h)
		draw.RoundedBox(4, 0, 0, w, h, C.panel)
		if not preview then return end
		local L, R, T, B = 44, 10, 8, 18
		local xMax, yMax = topMph() * 1.08, base.redline * 1.05
		local function X(mph) return floor(L + (w - L - R) * mph / xMax) end
		local function Y(rpm) return floor(h - B - (h - T - B) * rpm / yMax) end
		surface.SetDrawColor(C.line)
		for r = 1000, yMax, 1000 do
			surface.DrawLine(L, Y(r), w - R, Y(r))
			draw.SimpleText(floor(r / 1000) .. "k", "DermaDefault", L - 6, Y(r), C.muted, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		end
		for v = 20, xMax, 20 do
			draw.SimpleText(v, "DermaDefault", X(v), h - B + 2, C.muted, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
		end
		surface.SetDrawColor(C.red)
		surface.DrawLine(L, Y(base.redline), w - R, Y(base.redline))
		local n = #preview.gears
		local from = 0
		for i = 1, n do
			-- the whole gear, faint
			local vRed = min(xMax, base.redline / (K * ratio(i)) / MS_PER_MPH)
			surface.SetDrawColor(C.amberDim)
			surface.DrawLine(X(0), Y(0), X(vRed), Y(rpmAt(i, vRed)))
			-- the part used flat out, and the drop into the next gear
			local to = upMph(i)
			surface.SetDrawColor(C.amber)
			for o = 0, 1 do surface.DrawLine(X(from), Y(rpmAt(i, from)) - o, X(to), Y(rpmAt(i, to)) - o) end
			if i < n then
				surface.DrawLine(X(to), Y(rpmAt(i, to)), X(to), Y(rpmAt(i + 1, to)))
				draw.SimpleText(ord(i), "DermaDefault", X((from + to) / 2), Y(rpmAt(i, (from + to) / 2)) - 12, C.fg, TEXT_ALIGN_CENTER)
			end
			local d = preview.shiftPlan.down[i]
			if d then
				local dm = d / MS_PER_MPH
				surface.SetDrawColor(C.blue)
				surface.DrawLine(X(dm), Y(rpmAt(i, dm)), X(dm), Y(rpmAt(i - 1, dm)))
			end
			from = to
		end
		draw.SimpleText("full throttle shifts (amber), downshifts (blue), redline (red)", "DermaDefault", w - R, T, C.muted, TEXT_ALIGN_RIGHT)
	end

	local rebuild
	rebuild = function()
		list:Clear()
		infoLabels = {}
		if not prepare() then para(list, "Sit in or look at a car first.", C.red) return end
		recompute()
		local n = #spec
		local countRow = vgui.Create("DPanel", list)
		countRow:Dock(TOP)
		countRow:SetTall(24)
		countRow.Paint = nil
		local cl = label(countRow, "Number of gears (changing it spaces them again)", C.fg)
		cl:Dock(LEFT)
		cl:SetWide(300)
		local wang = vgui.Create("DNumberWang", countRow)
		wang:Dock(LEFT)
		wang:SetWide(50)
		wang:SetMinMax(1, 8)
		wang:SetDecimals(0)
		wang:SetValue(n)
		wang.OnValueChanged = function(_, v)
			v = math.Clamp(floor(tonumber(v) or n), 1, 8)
			if v == #spec then return end
			spec = autoSpace(v)
			timer.Simple(0, rebuild)
		end
		local redline = base.redline
		local lo = floor(base.idle * 1.5)
		for i = 1, n do
			heading(list, i < n and (ord(i) .. " gear") or (ord(i) .. " gear (top)"))
			local g = spec[i]
			if i < n then
				slider(list, "Changes up at (mph)", 1, floor(topMph()), 1, g.mph or 10, function(v)
					g.mph = v; recompute(); refreshInfo()
				end)
				slider(list, "... at (rpm, flat out)", lo, floor(redline * 0.99), 0, g.rpm or redline * 0.92, function(v)
					g.rpm = floor(v / 25 + 0.5) * 25; recompute(); refreshInfo()
				end)
			else
				slider(list, "Revs at top speed (rpm)", lo, floor(redline * 0.985), 0, spec.topRpm or redline * 0.85, function(v)
					spec.topRpm = floor(v / 25 + 0.5) * 25; recompute(); refreshInfo()
				end)
			end
			if i > 1 then
				local prevUp = (spec[i - 1] and spec[i - 1].mph) or topMph()
				slider(list, "Changes down under (mph, 0 = default)", 0, max(5, floor(prevUp)), 1, g.down or 0, function(v)
					g.down = v > 0 and v or nil; recompute(); refreshInfo()
				end)
			end
			local l = para(list, "", C.muted)
			infoLabels[i] = l
		end
		heading(list, "Notes")
		para(list, "The upshift rpm is where it changes up with W held and the car pulling hard; pulling gently it changes up a little earlier (" ..
			floor(DT.SHIFT.lazyUpRpm / DT.SHIFT.upRpm * 100 + 0.5) .. "% of it). Kickdown and the cornering rules stay as they are. " ..
			"Each gear is kept at least " .. floor((E.GEAR_MIN_STEP - 1) * 100 + 0.5) .. "% taller than the one below, so every upshift drops the revs " ..
			"far enough to hear; aim for 15-35%. The top gear follows the car's top speed. Gearing only changes the sound: the car's speed comes from its script.")
		refreshInfo()
	end

	local function loadFromCar()
		if not prepare() then return end
		local cur = IsValid(target) and E.GetEngineConfig(target)
		spec = DBG.GearingFromConfig(cur or base)
	end

	bar:Add("Apply live", function()
		if not IsValid(target) then return end
		net.Start("audio_dbg_gear")
		net.WriteEntity(target)
		net.WriteString(DBG.EncodeGearing(spec))
		net.SendToServer()
		timer.Simple(0.3, refreshInfo)
	end, true)
	bar:Add("Load from car", function() loadFromCar(); rebuild() end)
	bar:Add("Auto-space", function() if prepare() then spec = autoSpace(#spec); rebuild() end end)
	bar:Add("Back to the car's own", function()
		if not IsValid(target) then return end
		net.Start("audio_dbg_gear")
		net.WriteEntity(target)
		net.WriteString("")
		net.SendToServer()
		timer.Simple(0.3, function() loadFromCar(); rebuild() end)
	end)
	bar:Add("Copy for sh_carlist (E.CAR_GEARING)", function()
		local car = IsValid(target) and E.GetCarConfig(target)
		if not car then return end
		local line = DBG.GearingLua(car.name, DBG.SanitizeGearing(spec))
		if not car.perp then line = "gearing = " .. line:match("= (.*),$") .. ",   -- in its RegisterCar entry (sh_config.lua)" end
		SetClipboardText(line)
		say(true, "Copied: " .. line)
	end)

	if prepare() then loadFromCar() end
	if spec then rebuild() else para(list, "Sit in or look at a car first.", C.red) end
end

---------------------------------------------------------------------------
-- page: rev response
---------------------------------------------------------------------------
-- a blip at a standstill: W from idle to 90% of redline, let go until back near idle, twice
local simCache = {}
local function simulateRevs(cfg, rise, fall)
	local key = string.format("%d_%d_%d_%d", cfg.idle, cfg.redline, rise, fall)
	local c = simCache[key]
	if c then return c[1], c[2], c[3], c[4] end
	local sim = { redline = cfg.redline, idle = cfg.idle, revRise = rise, revFall = fall }
	local dt = 1 / 120
	local rpm, thr = cfg.idle, 0
	local pts = {}
	local tUp, tDown, phaseStart = nil, nil, 0
	local want, cycles, t = 1, 0, 0
	while t < 12 and cycles < 2 do
		thr = thr + DT.clamp(want - thr, -dt * 7, dt * 5)
		local idleThr = DT.clamp((cfg.idle - rpm) / 400, 0, 0.3)
		rpm = DT.clamp(rpm + DT.FreeSpinRate(sim, rpm, max(thr, idleThr)) * dt, 0, cfg.redline)
		t = t + dt
		pts[#pts + 1] = { t, rpm }
		if want == 1 and rpm >= cfg.redline * 0.9 then
			tUp = tUp or (t - phaseStart)
			want, phaseStart = 0, t
		elseif want == 0 and rpm <= cfg.idle + (cfg.redline - cfg.idle) * 0.08 then
			tDown = tDown or (t - phaseStart)
			want, phaseStart, cycles = 1, t, cycles + 1
		end
	end
	if table.Count(simCache) > 64 then simCache = {} end
	simCache[key] = { pts, tUp, tDown, t }
	return pts, tUp, tDown, t
end

local function buildRevPage(pnl)
	local list = scroll(pnl)
	local scope = "car"
	local rise, fall = DT.REV.rise, DT.REV.fall
	local cfg
	local chart, riseS, fallS, info

	local function load()
		cfg = IsValid(target) and E.GetEngineConfig(target)
		if scope == "car" and cfg then
			rise, fall = cfg.revRise or DT.REV.rise, cfg.revFall or DT.REV.fall
		else
			rise, fall = DT.REV.rise, DT.REV.fall
		end
		if IsValid(riseS) then riseS:Set(rise); fallS:Set(fall) end
	end

	local function refresh()
		if not (cfg and IsValid(info)) then return end
		local _, tUp, tDown = simulateRevs(cfg, rise, fall)
		local _, _, dDown = simulateRevs(cfg, DBG.REV_DEFAULT.rise, DBG.REV_DEFAULT.fall)
		if not tUp then
			info:SetText("The revs never reach 90% of redline: the fall is too strong for the rise.")
			info:SetTextColor(C.red)
			return
		end
		info:SetTextColor(C.fg)
		info:SetText(string.format("Idle to 90%% of redline: %.2f s  ·  back down to near idle: %.2f s  (default %d / %d drops in %.2f s)",
			tUp, tDown or 0, DBG.REV_DEFAULT.rise, DBG.REV_DEFAULT.fall, dDown or 0))
	end

	heading(list, "Applies to")
	local combo = vgui.Create("DComboBox", list)
	combo:Dock(TOP)
	combo:SetTall(22)
	combo:AddChoice("This car", "car", true)
	combo:AddChoice("Every car (DT.REV)", "all")
	combo.OnSelect = function(_, _, _, v) scope = v; load(); refresh() end

	heading(list, "Response")
	riseS = slider(list, "Rise (how fast the revs climb on W)", DBG.REV_RANGE[1], DBG.REV_RANGE[2], 0, rise, function(v) rise = floor(v + 0.5); refresh() end)
	fallS = slider(list, "Fall (how fast they drop when you let go)", DBG.REV_RANGE[1], DBG.REV_RANGE[2], 0, fall, function(v) fall = floor(v + 0.5); refresh() end)
	info = para(list, "", C.fg)
	chart = vgui.Create("DPanel", list)
	chart:Dock(TOP)
	chart:SetTall(160)
	chart:DockMargin(0, 4, 0, 6)
	chart.Paint = function(self, w, h)
		draw.RoundedBox(4, 0, 0, w, h, C.panel)
		if not cfg then return end
		local L, R, T, B = 44, 10, 8, 18
		local function plot(pts, col, tMax)
			surface.SetDrawColor(col)
			local px, py
			for _, p in ipairs(pts) do
				local x = floor(L + (w - L - R) * p[1] / tMax)
				local y = floor(h - B - (h - T - B) * p[2] / (cfg.redline * 1.05))
				if px then surface.DrawLine(px, py, x, y) end
				px, py = x, y
			end
		end
		local pts, _, _, tEnd = simulateRevs(cfg, rise, fall)
		local dpts, _, _, dEnd = simulateRevs(cfg, DBG.REV_DEFAULT.rise, DBG.REV_DEFAULT.fall)
		local tMax = max(tEnd, dEnd, 1)
		for s = 1, tMax do
			local x = floor(L + (w - L - R) * s / tMax)
			draw.SimpleText(s .. " s", "DermaDefault", x, h - B + 2, C.muted, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
		end
		local yr = floor(h - B - (h - T - B) / 1.05)
		surface.SetDrawColor(C.red)
		surface.DrawLine(L, yr, w - R, yr)
		draw.SimpleText(fmtK(cfg.redline), "DermaDefault", L - 4, yr, C.muted, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		plot(dpts, C.line, tMax)
		plot(pts, C.amber, tMax)
		draw.SimpleText("two blips to 90% and back (amber), the default (grey)", "DermaDefault", w - R, T, C.muted, TEXT_ALIGN_RIGHT)
	end

	local bar = buttonRow(list)
	bar:Add("Apply live", function()
		net.Start("audio_dbg_rev")
		net.WriteBool(scope == "all")
		if scope ~= "all" then net.WriteEntity(target) end
		net.WriteString(DBG.EncodeRev(rise, fall))
		net.SendToServer()
	end, true)
	bar:Add("Back to default", function()
		net.Start("audio_dbg_rev")
		net.WriteBool(scope == "all")
		if scope ~= "all" then net.WriteEntity(target) end
		net.WriteString("")
		net.SendToServer()
		timer.Simple(0.3, function() load(); refresh() end)
	end)
	bar:Add("Copy", function()
		local car = IsValid(target) and E.GetCarConfig(target)
		local line
		if scope == "all" then
			line = string.format("DT.REV = { rise = %d, fall = %d }   -- sh_drivetrain.lua", rise, fall)
		elseif car and car.perp then
			line = string.format('["%s"] = { rise = %d, fall = %d },   -- sh_carlist.lua E.CAR_REV', car.name, rise, fall)
		else
			line = string.format("rev = { rise = %d, fall = %d },   -- its RegisterCar entry", rise, fall)
		end
		SetClipboardText(line)
		say(true, "Copied: " .. line)
	end)
	para(list, "To test: stand still, hold Space (handbrake: neutral) and tap W. Rise and fall are torques in the units of " ..
		"DT.TMAX (320, the Rev Bench value the baked sounds use; the game now defaults to 500 / 500). A higher fall lets the revs " ..
		"drop back quicker between blips. Only the free-revving engine changes: driving, the gears set the revs.")
	load()
	refresh()
end

---------------------------------------------------------------------------
-- page: handling
---------------------------------------------------------------------------
local function cvOn(name) return (tonumber(state.cvars[name]) or 1) ~= 0 end

local function buildHandlingPage(pnl)
	local list = scroll(pnl)
	heading(list, "Handling changes")
	local master = check(list, "PERP's own handling: switch all of the addon's handling changes off", false, function(v)
		local t = {}
		for _, n in ipairs(DBG.HANDLING_CVARS) do t[#t + 1] = { n, v and 0 or 1 } end
		sendCvars(t)
	end)
	para(list, "Off = the cars drive on their vehicle script alone, as on PERP without this addon: no anti-spin setup, traction control " ..
		"or stability control. PERP's physics still go onto cars that fell back to the test script, so they match the server.")
	local boxes = {}
	for _, n in ipairs({ "audio_engine_handling", "audio_engine_traction", "audio_engine_stability", "audio_engine_cruise" }) do
		local c = DBG.SERVER_CVAR_SET[n]
		boxes[n] = check(list, c[3] .. "   (" .. n .. ")", true, function(v) sendCvars({ { n, v and 1 or 0 } }) end)
	end
	para(list, "Power cut after a turn: when you let go of A/D with W held, the stability control's straight-line hold takes over " ..
		"and counts the car's leftover rotation from the turn as sliding; traction control then takes the power down to the slide " ..
		"floor. Switch traction or stability off above, or lower Straight-line hold / raise the slide floor below, to compare.", C.amber)

	heading(list, "Values (live, until a map change)")
	local sliders = {}
	for i, t in ipairs(DBG.TUNABLES) do
		sliders[i] = slider(list, t[6], t[3], t[4], t[5], state.tunables[i] or t[3], function(v)
			debounce("tune" .. i, function()
				net.Start("audio_dbg_tune")
				net.WriteUInt(i, 8)
				net.WriteFloat(v)
				net.SendToServer()
			end)
		end)
		sliders[i]:SetTooltip("E." .. t[1] .. "." .. t[2])
	end
	local bar = buttonRow(list)
	bar:Add("Copy values as Lua", function()
		local lines = {}
		for i, t in ipairs(DBG.TUNABLES) do
			local file = t[1] == "STABILITY_DEFAULTS" and "sv_stability.lua" or "sv_handling.lua"
			lines[#lines + 1] = string.format("E.%s.%s = %s   -- %s", t[1], t[2], KV.Num(state.tunables[i] or 0), file)
		end
		SetClipboardText(table.concat(lines, "\n"))
		say(true, "Copied " .. #lines .. " values to the clipboard.")
	end)
	heading(list, "Logs (server console)")
	local logs = buttonRow(list)
	logs:Add("Acceleration log (30 s)", function() RunConsoleCommand("audio_engine_accel_log", "30") say(true, "Logging to the console: hold W from a standstill.") end)
	logs:Add("Handling info", function() RunConsoleCommand("audio_engine_handling_info") say(true, "Printed to the console.") end)

	onState.handling = function()
		local allOff = true
		for _, n in ipairs(DBG.HANDLING_CVARS) do if cvOn(n) then allOff = false end end
		if IsValid(master) then master:Set(allOff) end
		for n, b in pairs(boxes) do if IsValid(b) then b:Set(cvOn(n)) end end
		for i, s in ipairs(sliders) do if IsValid(s) and state.tunables[i] and not s:IsEditing() then s:Set(state.tunables[i]) end end
	end
	onState.handling()
end

---------------------------------------------------------------------------
-- page: settings
---------------------------------------------------------------------------
local function buildSettingsPage(pnl)
	local list = scroll(pnl)
	heading(list, "This client")
	local function cvSlider(name, text, lo, hi, dec)
		local s = vgui.Create("DNumSlider", list)
		s:Dock(TOP)
		s:SetTall(26)
		s:SetText(text)
		s:SetMinMax(lo, hi)
		s:SetDecimals(dec)
		s:SetConVar(name)
		s.Label:SetTextColor(C.fg)
		s.Label:SetWide(260)
		s.TextArea:SetTextColor(C.amber)
		s:SetTooltip(name)
	end
	local function cvCheck(name, text)
		local c = vgui.Create("DCheckBoxLabel", list)
		c:Dock(TOP)
		c:DockMargin(0, 3, 0, 3)
		c:SetText(text .. "   (" .. name .. ")")
		c:SetTextColor(C.fg)
		c:SetConVar(name)
	end
	local function cvCombo(name, text, choices)
		local row = vgui.Create("DPanel", list)
		row:Dock(TOP)
		row:SetTall(24)
		row.Paint = nil
		local l = label(row, text, C.fg)
		l:Dock(LEFT)
		l:SetWide(260)
		local cb = vgui.Create("DComboBox", row)
		cb:Dock(LEFT)
		cb:SetWide(220)
		local cur = GetConVar(name) and GetConVar(name):GetString() or ""
		for _, ch in ipairs(choices) do cb:AddChoice(ch[2], ch[1], tostring(ch[1]) == cur) end
		cb.OnSelect = function(_, _, _, v) RunConsoleCommand(name, tostring(v)) end
		cb:SetTooltip(name)
	end
	cvSlider("audio_engine_volume", "Engine volume", 0, 2, 2)
	cvSlider("audio_engine_roadnoise", "Tyre roar", 0, 2, 2)
	cvSlider("audio_engine_windnoise", "Wind noise", 0, 2, 2)
	cvSlider("audio_engine_doppler", "Doppler (0.25 = real)", 0, 1, 2)
	cvSlider("audio_engine_passby", "Pass-by swell", 0, 2, 2)
	cvCombo("audio_engine_tunnel", "Tunnel effect", { { 0, "Off" }, { 1, "The map's own (default)" }, { 6, "Medium tunnel" }, { 7, "Large tunnel" } })
	cvCheck("audio_engine_hud", "Speed / rpm HUD")
	cvCombo("audio_engine_units", "HUD units", { { "mph", "mph" }, { "kmh", "km/h" } })
	cvSlider("audio_engine_hud_scale", "HUD size", 0.5, 2, 2)
	cvCombo("audio_engine_samplerate", "Generated sound quality", { { 44100, "44.1 kHz" }, { 22050, "22.05 kHz (faster)" } })
	cvSlider("audio_engine_genbudget", "Generation budget (ms per frame)", 1, 50, 0)
	cvSlider("audio_engine_maxsounds", "Generated sounds kept", 2, 40, 0)
	cvCheck("audio_engine_baked", "Play the pre-generated (baked) stock sounds")
	local keyRow = vgui.Create("DPanel", list)
	keyRow:Dock(TOP)
	keyRow:SetTall(24)
	keyRow.Paint = nil
	local kl = label(keyRow, "Start key (a key name, none = off)", C.fg)
	kl:Dock(LEFT)
	kl:SetWide(260)
	local ke = vgui.Create("DTextEntry", keyRow)
	ke:Dock(LEFT)
	ke:SetWide(80)
	ke:SetConVar("audio_engine_startkey")
	local cl = buttonRow(list)
	cl:Add("Regenerate engine sounds", function() RunConsoleCommand("audio_engine_rebuild") end)

	heading(list, "Server")
	local boxes, others = {}, {}
	for _, c in ipairs(DBG.SERVER_CVARS) do
		local n = c[1]
		if c[2] == "bool" and not table.HasValue(DBG.HANDLING_CVARS, n) and n ~= "audio_engine_cruise" then
			boxes[n] = check(list, c[3] .. "   (" .. n .. ")", false, function(v) sendCvars({ { n, v and 1 or 0 } }) end)
		elseif c[2] ~= "bool" then
			others[n] = slider(list, c[3], c[4], c[5], c[2] == "int" and 0 or 1, tonumber(state.cvars[n]) or c[4], function(v)
				debounce(n, function() sendCvars({ { n, v } }) end)
			end)
		end
	end
	local sv = buttonRow(list)
	sv:Add("Open the Rev Bench editor", function() RunConsoleCommand("audio_engine_menu") end)
	sv:Add("Show the brake flap (10 s)", function() RunConsoleCommand("audio_engine_wingflap") end)
	sv:Add("Dump bone manipulations", function() RunConsoleCommand("audio_engine_bonedump") end)

	onState.settings = function()
		for n, b in pairs(boxes) do if IsValid(b) then b:Set(cvOn(n)) end end
		for n, s in pairs(others) do if IsValid(s) and state.cvars[n] and not s:IsEditing() then s:Set(tonumber(state.cvars[n]) or 0) end end
	end
	onState.settings()
end

---------------------------------------------------------------------------
-- the menu
---------------------------------------------------------------------------
local function pickTarget()
	local ply = LocalPlayer()
	local veh = ply:GetVehicle()
	if IsValid(veh) and E.GetCarConfig(veh) then return veh end
	local tr = ply:GetEyeTrace()
	if IsValid(tr.Entity) and E.GetCarConfig(tr.Entity) and tr.HitPos:DistToSqr(ply:GetShootPos()) < 400 * 400 then return tr.Entity end
	return nil
end

function DBG.OpenMenu(veh)
	local ply = LocalPlayer()
	if not DBG.Allowed(ply) then
		chat.AddText(C.amber, "[Audio Engine debug] ", C.fg, DBG.Enabled() and "Superadmins only." or "The debug tools are off on this server (audio_engine_debug 0).")
		return
	end
	target = IsValid(veh) and E.GetCarConfig(veh) and veh or pickTarget()
	if not target then
		chat.AddText(C.amber, "[Audio Engine debug] ", C.fg, "Sit in or look at a car with the procedural engine.")
		return
	end
	if IsValid(frame) then frame:Remove() end
	onState, onScript = {}, nil
	if scriptData and scriptData.veh ~= target then scriptData = nil end

	frame = vgui.Create("DFrame")
	frame:SetSize(min(1000, ScrW() - 40), min(820, ScrH() - 40))
	frame:Center()
	frame:SetTitle("")
	frame:SetSizable(true)
	frame:SetMinWidth(700)
	frame:SetMinHeight(500)
	frame:MakePopup()
	frame:DockPadding(10, 30, 10, 8)
	frame.Paint = function(self, w, h)
		draw.RoundedBox(8, 0, 0, w, h, C.bg)
		local car = IsValid(target) and E.GetCarConfig(target)
		draw.SimpleText("AUDIO ENGINE · DEBUG", "DermaDefaultBold", 12, 8, C.amber)
		draw.SimpleText(car and car.name or "(no car)", "DermaDefaultBold", 170, 8, C.fg)
	end
	local retarget = button(frame, "Use the car I'm in / looking at", function()
		local v = pickTarget()
		if v then DBG.OpenMenu(v) else say(false, "No car in reach.") end
	end)
	retarget:SetPos(frame:GetWide() - retarget:GetWide() - 40, 4)
	retarget:SetTall(20)
	local oldLayout = frame.PerformLayout
	frame.PerformLayout = function(self, w, h)
		if oldLayout then oldLayout(self, w, h) end
		retarget:SetPos(w - retarget:GetWide() - 40, 4)
	end

	status = label(frame, "Changes made here are live tests: copy what works back into the files.", C.muted)
	status:Dock(BOTTOM)
	status:DockMargin(4, 6, 0, 0)

	local sheet = vgui.Create("DPropertySheet", frame)
	sheet:Dock(FILL)
	sheet.Paint = function(self, w, h) draw.RoundedBox(4, 0, 20, w, h - 20, C.panel) end
	local function page(name, icon, build)
		local p = vgui.Create("DPanel", sheet)
		p.Paint = nil
		build(p)
		sheet:AddSheet(name, p, icon)
	end
	page("Handling script", "icon16/page_edit.png", buildScriptPage)
	page("Gearing", "icon16/cog.png", buildGearPage)
	page("Rev response", "icon16/chart_curve.png", buildRevPage)
	page("Handling", "icon16/car.png", buildHandlingPage)
	page("Settings", "icon16/wrench.png", buildSettingsPage)
	requestState()
end

-- (a Lua refresh of the core replaces E.GetEngineConfig: wrap it again)
timer.Create("audio_engine_debug_install", 5, 0, DBG.Install)

concommand.Add("audio_engine_debug_menu", function() DBG.OpenMenu() end, nil, "Audio Engine debug tools (superadmins)")

if properties and properties.Add then
	properties.Add("audio_engine_debug", {
		MenuLabel = "Engine debug tools",
		Order = 2001,
		MenuIcon = "icon16/bug.png",
		Filter = function(self, ent, ply) return DBG.Allowed(ply) and IsValid(ent) and E.GetCarConfig(ent) ~= nil end,
		Action = function(self, ent) DBG.OpenMenu(ent) end,
	})
end
