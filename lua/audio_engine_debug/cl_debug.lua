--[[
	Audio Engine debug module - the debug menu (client). Not part of the final addon (see sh_debug.lua).

	audio_engine_debug_menu (or !enginedebug, or right-click a car in the context menu), on the car
	you sit in or look at. Superadmins, while audio_engine_debug is 1 (the default). Pages:

	  Handling script  the car's vehicle script: edit its values, apply them to the car live, copy
	                   the txt (or save it to data/audio_engine_debug/scripts/) for PERP's script pack
	  Gearing          how many gears and where each changes up / down, by speed and rpm; applied
	                   live for everyone; copies an AudioEngine.CAR_GEARING entry for sh_carlist.lua
	  Rev response     how fast the revs climb and drop back standing still (Space + W), this car or
	                   every car; copies an AudioEngine.CAR_REV entry or the Drivetrain.REV line
	  Handling         the addon's handling changes on / off (all off = PERP's own handling) and
	                   their main values live
	  Settings         the client and server convars and test commands as controls
]]

local AudioEngine = AUDIO_ENGINE
local EngineDebug = AudioEngine.Debug
local KeyValues = AudioEngine.KV
local Drivetrain = AudioEngine.Drivetrain

local floor, max, min = math.floor, math.max, math.min
local MS_PER_MPH = 0.44704

local COLORS = {
	background = Color(18, 21, 26, 252), panel = Color(26, 30, 37), face = Color(34, 39, 47), line = Color(52, 58, 68),
	text = Color(232, 227, 214), muted = Color(150, 156, 165), amber = Color(255, 165, 61), amberDim = Color(120, 80, 30),
	red = Color(255, 90, 70), green = Color(95, 211, 138), blue = Color(110, 170, 255),
}

local frame, status
local targetCar          -- the car the menu works on
local serverState = { cvars = {}, tunables = {} }
local stateListeners = {}    -- pages that follow the server state
local scriptData      -- the target's vehicle script (from the server)
local scriptListener

local function formatThousands(number)
	local digits = tostring(floor(number + 0.5))
	return (digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end
local function ordinal(gear)
	return gear == 1 and "1st" or gear == 2 and "2nd" or gear == 3 and "3rd" or (gear .. "th")
end

local function report(succeeded, message)
	if IsValid(status) then
		status:SetText(message)
		status:SetTextColor(succeeded and COLORS.green or COLORS.red)
	end
	chat.AddText(COLORS.amber, "[Audio Engine debug] ", succeeded and COLORS.text or COLORS.red, message)
end

---------------------------------------------------------------------------
-- controls
---------------------------------------------------------------------------
local function label(parent, text, color, font)
	local labelPanel = vgui.Create("DLabel", parent)
	labelPanel:SetFont(font or "DermaDefault")
	labelPanel:SetText(text)
	labelPanel:SetTextColor(color or COLORS.text)
	labelPanel:SizeToContents()
	return labelPanel
end

local function paragraph(parent, text, color)
	local labelPanel = label(parent, text, color or COLORS.muted)
	labelPanel:Dock(TOP)
	labelPanel:DockMargin(0, 2, 0, 6)
	labelPanel:SetWrap(true)
	labelPanel:SetAutoStretchVertical(true)
	return labelPanel
end

local function heading(parent, text)
	local labelPanel = label(parent, text, COLORS.amber, "DermaDefaultBold")
	labelPanel:Dock(TOP)
	labelPanel:DockMargin(0, 10, 0, 4)
	return labelPanel
end

local function button(parent, text, onClick, primary)
	local buttonPanel = vgui.Create("DButton", parent)
	buttonPanel:SetText(text)
	buttonPanel:SetTextColor(primary and Color(27, 18, 6) or COLORS.text)
	buttonPanel.Paint = function(self, width, height)
		local fill = primary and COLORS.amber or COLORS.face
		if self:IsHovered() then fill = primary and Color(255, 190, 110) or COLORS.line end
		draw.RoundedBox(4, 0, 0, width, height, fill)
	end
	buttonPanel.DoClick = onClick
	surface.SetFont("DermaDefault")
	buttonPanel:SetWide(surface.GetTextSize(text) + 24)
	return buttonPanel
end

-- a row of buttons
local function buttonRow(parent)
	local row = vgui.Create("DPanel", parent)
	row:Dock(TOP)
	row:SetTall(26)
	row:DockMargin(0, 4, 0, 4)
	row.Paint = nil
	row.Add = function(self, text, onClick, primary)
		local buttonPanel = button(self, text, onClick, primary)
		buttonPanel:Dock(LEFT)
		buttonPanel:DockMargin(0, 0, 6, 0)
		return buttonPanel
	end
	return row
end

local function slider(parent, text, low, high, decimals, value, onChange)
	local sliderPanel = vgui.Create("DNumSlider", parent)
	sliderPanel:Dock(TOP)
	sliderPanel:SetTall(26)
	sliderPanel:SetText(text)
	sliderPanel:SetMinMax(low, high)
	sliderPanel:SetDecimals(decimals)
	sliderPanel.quiet = true
	sliderPanel:SetValue(value)
	sliderPanel.quiet = false
	sliderPanel.Label:SetTextColor(COLORS.text)
	sliderPanel.Label:SetWide(260)
	sliderPanel.TextArea:SetTextColor(COLORS.amber)
	sliderPanel.OnValueChanged = function(self, newValue)
		if self.quiet then return end
		onChange(newValue)
	end
	sliderPanel.Set = function(self, newValue) self.quiet = true; self:SetValue(newValue); self.quiet = false end
	return sliderPanel
end

local function check(parent, text, value, onChange)
	local checkBox = vgui.Create("DCheckBoxLabel", parent)
	checkBox:Dock(TOP)
	checkBox:DockMargin(0, 3, 0, 3)
	checkBox:SetText(text)
	checkBox:SetTextColor(COLORS.text)
	checkBox:SetChecked(value and true or false)
	checkBox.OnChange = function(self, checked) if not self.quiet then onChange(checked) end end
	checkBox.Set = function(self, checked) self.quiet = true; self:SetChecked(checked and true or false); self.quiet = false end
	return checkBox
end

local function scroll(parent)
	local scrollPanel = vgui.Create("DScrollPanel", parent)
	scrollPanel:Dock(FILL)
	scrollPanel:GetCanvas():DockPadding(8, 4, 12, 8)
	return scrollPanel
end

---------------------------------------------------------------------------
-- talking to the server
---------------------------------------------------------------------------
-- a slider being dragged sends once it rests for a moment, not every step
local function debounce(id, callback) timer.Create("audio_dbg_" .. id, 0.25, 1, callback) end

local function sendCvars(changes)
	net.Start("audio_dbg_cvar")
	net.WriteUInt(#changes, 4)
	for _, change in ipairs(changes) do net.WriteString(change[1]); net.WriteString(tostring(change[2])) end
	net.SendToServer()
end

local function requestState() net.Start("audio_dbg_state_req") net.SendToServer() end

local function requestScript()
	if not IsValid(targetCar) then return end
	net.Start("audio_dbg_script_req")
	net.WriteEntity(targetCar)
	net.SendToServer()
end

net.Receive("audio_dbg_result", function()
	local succeeded, message = net.ReadBool(), net.ReadString()
	report(succeeded, message)
end)

net.Receive("audio_dbg_state", function()
	local cvarCount = net.ReadUInt(8)
	for _ = 1, cvarCount do
		local name, value = net.ReadString(), net.ReadString()
		serverState.cvars[name] = value
	end
	local tunableCount = net.ReadUInt(8)
	for i = 1, tunableCount do serverState.tunables[i] = net.ReadFloat() end
	for _, listener in pairs(stateListeners) do listener() end
end)

net.Receive("audio_dbg_script", function()
	local vehicle = net.ReadEntity()
	local path, fallback = net.ReadString(), net.ReadBool()
	local dataLength = net.ReadUInt(16)
	local raw = util.Decompress(net.ReadData(dataLength)) or ""
	local current, fileText = raw:match("^(.-)%z(.*)$")
	local live = {}
	for _ = 1, net.ReadUInt(12) do live[net.ReadUInt(12)] = true end
	if not current then return end
	local entries = KeyValues.Parse(current)
	local values = {}
	for _, entry in ipairs(entries) do values[entry.index] = entry.value end
	scriptData = {
		vehicle = vehicle, path = path, fallback = fallback, fileText = fileText, fileEntries = KeyValues.Parse(fileText),
		applied = values, values = table.Copy(values), entries = entries, live = live,
	}
	if scriptListener then scriptListener() end
end)

---------------------------------------------------------------------------
-- page: handling script
---------------------------------------------------------------------------
local function scriptText()
	return KeyValues.Rebuild(scriptData.fileText, scriptData.fileEntries, scriptData.values)
end

local function buildScriptPage(pagePanel)
	local header = vgui.Create("DPanel", pagePanel)
	header:Dock(TOP)
	header:DockPadding(8, 6, 8, 0)
	header.Paint = nil
	local infoLabel = paragraph(header, "Loading the car's vehicle script...", COLORS.text)
	local warningLabel = paragraph(header, "", COLORS.red)
	local buttons = buttonRow(header)
	local filterRow = vgui.Create("DPanel", header)
	filterRow:Dock(TOP)
	filterRow:SetTall(22)
	filterRow.Paint = nil
	local filterLabel = label(filterRow, "Filter:", COLORS.muted)
	filterLabel:Dock(LEFT)
	filterLabel:DockMargin(0, 0, 6, 0)
	local filter = vgui.Create("DTextEntry", filterRow)
	filter:Dock(LEFT)
	filter:SetWide(200)
	local showSounds = vgui.Create("DCheckBoxLabel", filterRow)
	showSounds:Dock(LEFT)
	showSounds:DockMargin(12, 3, 0, 0)
	showSounds:SetText("Show sound blocks")
	showSounds:SetTextColor(COLORS.text)
	showSounds:SetWide(140)
	local countLabel = label(filterRow, "", COLORS.muted)
	countLabel:Dock(FILL)
	countLabel:DockMargin(12, 0, 0, 0)
	header:SetTall(150)

	local scrollPanel = scroll(pagePanel)
	local rows = {}

	local function refreshCount()
		if not scriptData then countLabel:SetText("") return end
		local fromFile, pending = 0, 0
		for _, entry in ipairs(scriptData.fileEntries) do
			if scriptData.values[entry.index] ~= entry.value then fromFile = fromFile + 1 end
			if scriptData.values[entry.index] ~= scriptData.applied[entry.index] then pending = pending + 1 end
		end
		countLabel:SetText(string.format("%d value%s changed from the file · %d not applied yet", fromFile, fromFile == 1 and "" or "s", pending))
		countLabel:SetTextColor(pending > 0 and COLORS.amber or COLORS.muted)
	end

	local function rebuild()
		scrollPanel:Clear()
		rows = {}
		if not scriptData then return end
		local filterText = filter:GetValue():lower()
		local lastLabel
		for _, entry in ipairs(scriptData.entries) do
			local isSound = entry.path:find("sound", 1, true) ~= nil
			local matches = filterText == "" or entry.lowerKey:find(filterText, 1, true) or entry.label:lower():find(filterText, 1, true)
			if matches and (showSounds:GetChecked() or not isSound) then
				if entry.label ~= lastLabel then
					lastLabel = entry.label
					local groupLabel = label(scrollPanel, entry.label == "" and "vehicle" or entry.label, COLORS.amber, "DermaDefaultBold")
					groupLabel:Dock(TOP)
					groupLabel:DockMargin(0, 8, 0, 2)
				end
				local row = vgui.Create("DPanel", scrollPanel)
				row:Dock(TOP)
				row:SetTall(22)
				row:DockMargin(0, 1, 0, 1)
				row.Paint = nil
				local keyLabel = label(row, entry.key .. (entry.occurrence > 1 and ("  #" .. entry.occurrence) or ""), COLORS.text)
				keyLabel:Dock(LEFT)
				keyLabel:SetWide(230)
				local valueEntry = vgui.Create("DTextEntry", row)
				valueEntry:Dock(LEFT)
				valueEntry:SetWide(150)
				valueEntry:SetValue(scriptData.values[entry.index])
				local fileValue = scriptData.fileEntries[entry.index] and scriptData.fileEntries[entry.index].value
				valueEntry.Paint = function(self, width, height)
					local value = self:GetValue()
					local background = not KeyValues.ValidValue(value) and Color(90, 30, 30) or value ~= fileValue and Color(70, 52, 25) or COLORS.face
					draw.RoundedBox(3, 0, 0, width, height, background)
					self:DrawTextEntryText(COLORS.text, COLORS.amber, COLORS.text)
				end
				valueEntry.OnChange = function(self)
					local value = self:GetValue()
					if KeyValues.ValidValue(value) then scriptData.values[entry.index] = value end
					refreshCount()
				end
				local liveLabel = label(row, scriptData.live[entry.index] and "live" or "respawn", scriptData.live[entry.index] and COLORS.green or COLORS.muted)
				liveLabel:Dock(LEFT)
				liveLabel:SetWide(60)
				liveLabel:DockMargin(8, 0, 0, 0)
				if entry.comment then
					local commentLabel = label(row, "// " .. entry.comment, COLORS.muted)
					commentLabel:Dock(FILL)
				end
				rows[entry.index] = valueEntry
			end
		end
		refreshCount()
	end
	filter.OnChange = function() rebuild() end
	showSounds.OnChange = function() rebuild() end

	scriptListener = function()
		if not (scriptData and IsValid(infoLabel)) then return end
		local carConfig = IsValid(scriptData.vehicle) and AudioEngine.GetCarConfig(scriptData.vehicle)
		infoLabel:SetText(string.format("%s  ·  %s", carConfig and carConfig.name or "?", scriptData.path))
		warningLabel:SetText(scriptData.fallback and ("PERP's vehicle scripts aren't mounted here: this is test_car.txt carrying PERP's physics values for "
			.. scriptData.path .. " (what the car drives on). Its sounds, materials and other fields are test_car's, not PERP's file.") or "")
		rebuild()
	end

	buttons:Add("Apply live", function()
		if not (scriptData and IsValid(scriptData.vehicle)) then return end
		local data = util.Compress(scriptText()) or ""
		net.Start("audio_dbg_script_apply")
		net.WriteEntity(scriptData.vehicle)
		net.WriteUInt(#data, 16)
		net.WriteData(data, #data)
		net.SendToServer()
	end, true)
	buttons:Add("Copy txt", function()
		if not scriptData then return end
		SetClipboardText(scriptText())
		report(true, "Copied " .. scriptData.path .. " to the clipboard.")
	end)
	buttons:Add("Save to data/", function()
		if not scriptData then return end
		local relativePath = "audio_engine_debug/scripts/" .. scriptData.path:gsub("^scripts/vehicles/", "")
		sourceFile.CreateDir(string.GetPathFromFilename(relativePath))
		sourceFile.Write(relativePath, scriptText())
		report(true, "Saved to garrysmod/data/" .. relativePath)
	end)
	buttons:Add("Undo unapplied", function()
		if not scriptData then return end
		scriptData.values = table.Copy(scriptData.applied)
		rebuild()
	end)
	buttons:Add("Reset car to file", function()
		if not (scriptData and IsValid(scriptData.vehicle)) then return end
		net.Start("audio_dbg_script_apply")
		net.WriteEntity(scriptData.vehicle)
		net.WriteUInt(0, 16)
		net.SendToServer()
	end)
	buttons:Add("Reload", requestScript)

	if scriptData and scriptData.vehicle == targetCar then scriptListener() else requestScript() end
end

---------------------------------------------------------------------------
-- page: gearing
---------------------------------------------------------------------------
local function buildGearPage(pagePanel)
	local spec, baseConfig, preview
	local rpmPerSpeed = 1

	local function prepare()
		baseConfig = IsValid(targetCar) and EngineDebug.BaseConfig(targetCar)
		if not baseConfig then return false end
		rpmPerSpeed = 60 / (2 * math.pi * baseConfig.wheelRadius)
		return true
	end
	local function recompute()
		preview = {}
		for key, value in pairs(baseConfig) do preview[key] = value end
		AudioEngine.ApplyGearing(preview, spec)
	end
	local function overallRatio(gear) return preview.gears[gear] * preview.final end
	local function rpmAt(gear, mph) return mph * MS_PER_MPH * rpmPerSpeed * overallRatio(gear) end
	-- the speed where gear i changes up flat out (top gear: the top speed)
	local function upMph(gear)
		if gear >= #preview.gears then return preview.topSpeed / 1.609344 end
		return preview.shiftPlan.up[gear] / (rpmPerSpeed * overallRatio(gear)) / MS_PER_MPH
	end
	local topMph = function() return baseConfig.topSpeed / 1.609344 end

	local function autoSpace(gearCount)
		local redline = baseConfig.redline
		local spacing = { topRpm = floor(redline * AudioEngine.TopGearShare(redline) + 0.5) }
		if gearCount >= 2 then
			local gearEnds = AudioEngine.FitGearEnds(baseConfig.topSpeed, gearCount, redline, baseConfig.powerKg, gearCount)
			for i = 1, gearCount - 1 do
				spacing[i] = { rpm = floor(redline * AudioEngine.GEAR_FIT.upShare / 50 + 0.5) * 50, mph = floor(gearEnds[i] * AudioEngine.GEAR_FIT.upShare / 1.609344 * 10 + 0.5) / 10 }
			end
		end
		spacing[gearCount] = {}
		return spacing
	end

	local header = vgui.Create("DPanel", pagePanel)
	header:Dock(TOP)
	header:SetTall(64)
	header:DockPadding(8, 6, 8, 0)
	header.Paint = nil
	local infoLabel = paragraph(header, "", COLORS.text)
	local buttons = buttonRow(header)

	local chart = vgui.Create("DPanel", pagePanel)
	chart:Dock(TOP)
	chart:SetTall(200)
	chart:DockMargin(8, 0, 8, 4)

	local scrollPanel = scroll(pagePanel)
	local infoLabels = {}

	local function refreshInfo()
		if not (preview and IsValid(infoLabel)) then return end
		local gearCount = #preview.gears
		for i = 1, gearCount do
			local infoLabel = infoLabels[i]
			if IsValid(infoLabel) then
				local parts = {}
				local color = COLORS.muted
				if i < gearCount then
					local upshiftRpm = preview.shiftPlan.up[i]
					local upshiftMph = upMph(i)
					local landingRpm = rpmAt(i + 1, upshiftMph)
					local drop = 1 - landingRpm / upshiftRpm
					parts[#parts + 1] = string.format("Changes up at %.0f mph, %s rpm -> %s rpm in %s (-%d%%)",
						upshiftMph, formatThousands(upshiftRpm), formatThousands(landingRpm), ordinal(i + 1), floor(drop * 100 + 0.5))
					if drop < 0.12 then
						parts[#parts + 1] = "barely audible: space this gear further"
						color = COLORS.red
					elseif drop > 0.45 then
						parts[#parts + 1] = "a big step: the revs fall a long way"
						color = COLORS.amber
					end
				else
					parts[#parts + 1] = string.format("Top gear: %s rpm at %.0f mph (redline at %.0f mph)", formatThousands(rpmAt(i, topMph())), topMph(),
						baseConfig.redline / (rpmPerSpeed * overallRatio(i)) / MS_PER_MPH)
				end
				local downshiftSpeed = preview.shiftPlan.down[i]
				if downshiftSpeed then
					parts[#parts + 1] = string.format("down to %s under %.0f mph (%s -> %s rpm)", ordinal(i - 1), downshiftSpeed / MS_PER_MPH,
						formatThousands(downshiftSpeed * rpmPerSpeed * overallRatio(i)), formatThousands(downshiftSpeed * rpmPerSpeed * overallRatio(i - 1)))
				elseif i > 1 then
					parts[#parts + 1] = "down: default points"
				end
				infoLabel:SetText(table.concat(parts, "  ·  "))
				infoLabel:SetTextColor(color)
			end
		end
		if not IsValid(targetCar) then return end
		infoLabel:SetText(string.format("%s · redline %s rpm · top speed %.0f mph · %d gears%s", AudioEngine.GetCarConfig(targetCar).name,
			formatThousands(baseConfig.redline), topMph(), gearCount, targetCar:GetNW2String("audio_dbg_gear", "") ~= "" and " · live override on" or ""))
	end

	chart.Paint = function(self, width, height)
		draw.RoundedBox(4, 0, 0, width, height, COLORS.panel)
		if not preview then return end
		local leftMargin, rightMargin, topMargin, bottomMargin = 44, 10, 8, 18
		local maxMph, maxRpm = topMph() * 1.08, baseConfig.redline * 1.05
		local function xOf(mph) return floor(leftMargin + (width - leftMargin - rightMargin) * mph / maxMph) end
		local function yOf(rpm) return floor(height - bottomMargin - (height - topMargin - bottomMargin) * rpm / maxRpm) end
		surface.SetDrawColor(COLORS.line)
		for gridRpm = 1000, maxRpm, 1000 do
			surface.DrawLine(leftMargin, yOf(gridRpm), width - rightMargin, yOf(gridRpm))
			draw.SimpleText(floor(gridRpm / 1000) .. "k", "DermaDefault", leftMargin - 6, yOf(gridRpm), COLORS.muted, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		end
		for gridMph = 20, maxMph, 20 do
			draw.SimpleText(gridMph, "DermaDefault", xOf(gridMph), height - bottomMargin + 2, COLORS.muted, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
		end
		surface.SetDrawColor(COLORS.red)
		surface.DrawLine(leftMargin, yOf(baseConfig.redline), width - rightMargin, yOf(baseConfig.redline))
		local gearCount = #preview.gears
		local fromMph = 0
		for i = 1, gearCount do
			-- the whole gear, faint
			local redlineMph = min(maxMph, baseConfig.redline / (rpmPerSpeed * overallRatio(i)) / MS_PER_MPH)
			surface.SetDrawColor(COLORS.amberDim)
			surface.DrawLine(xOf(0), yOf(0), xOf(redlineMph), yOf(rpmAt(i, redlineMph)))
			-- the part used flat out, and the drop into the next gear
			local toMph = upMph(i)
			surface.SetDrawColor(COLORS.amber)
			for offset = 0, 1 do surface.DrawLine(xOf(fromMph), yOf(rpmAt(i, fromMph)) - offset, xOf(toMph), yOf(rpmAt(i, toMph)) - offset) end
			if i < gearCount then
				surface.DrawLine(xOf(toMph), yOf(rpmAt(i, toMph)), xOf(toMph), yOf(rpmAt(i + 1, toMph)))
				draw.SimpleText(ordinal(i), "DermaDefault", xOf((fromMph + toMph) / 2), yOf(rpmAt(i, (fromMph + toMph) / 2)) - 12, COLORS.text, TEXT_ALIGN_CENTER)
			end
			local downshiftSpeed = preview.shiftPlan.down[i]
			if downshiftSpeed then
				local downshiftMph = downshiftSpeed / MS_PER_MPH
				surface.SetDrawColor(COLORS.blue)
				surface.DrawLine(xOf(downshiftMph), yOf(rpmAt(i, downshiftMph)), xOf(downshiftMph), yOf(rpmAt(i - 1, downshiftMph)))
			end
			fromMph = toMph
		end
		draw.SimpleText("full throttle shifts (amber), downshifts (blue), redline (red)", "DermaDefault", width - rightMargin, topMargin, COLORS.muted, TEXT_ALIGN_RIGHT)
	end

	local rebuild
	rebuild = function()
		scrollPanel:Clear()
		infoLabels = {}
		if not prepare() then paragraph(scrollPanel, "Sit in or look at a car first.", COLORS.red) return end
		recompute()
		local gearCount = #spec
		local countRow = vgui.Create("DPanel", scrollPanel)
		countRow:Dock(TOP)
		countRow:SetTall(24)
		countRow.Paint = nil
		local countLabel = label(countRow, "Number of gears (changing it spaces them again)", COLORS.text)
		countLabel:Dock(LEFT)
		countLabel:SetWide(300)
		local gearCountBox = vgui.Create("DNumberWang", countRow)
		gearCountBox:Dock(LEFT)
		gearCountBox:SetWide(50)
		gearCountBox:SetMinMax(1, 8)
		gearCountBox:SetDecimals(0)
		gearCountBox:SetValue(gearCount)
		gearCountBox.OnValueChanged = function(_, newCount)
			newCount = math.Clamp(floor(tonumber(newCount) or gearCount), 1, 8)
			if newCount == #spec then return end
			spec = autoSpace(newCount)
			timer.Simple(0, rebuild)
		end
		local redline = baseConfig.redline
		local lowestRpm = floor(baseConfig.idle * 1.5)
		for i = 1, gearCount do
			heading(scrollPanel, i < gearCount and (ordinal(i) .. " gear") or (ordinal(i) .. " gear (top)"))
			local gearSpec = spec[i]
			if i < gearCount then
				slider(scrollPanel, "Changes up at (mph)", 1, floor(topMph()), 1, gearSpec.mph or 10, function(value)
					gearSpec.mph = value; recompute(); refreshInfo()
				end)
				slider(scrollPanel, "... at (rpm, flat out)", lowestRpm, floor(redline * 0.99), 0, gearSpec.rpm or redline * 0.92, function(value)
					gearSpec.rpm = floor(value / 25 + 0.5) * 25; recompute(); refreshInfo()
				end)
			else
				slider(scrollPanel, "Revs at top speed (rpm)", lowestRpm, floor(redline * 0.985), 0, spec.topRpm or redline * 0.85, function(value)
					spec.topRpm = floor(value / 25 + 0.5) * 25; recompute(); refreshInfo()
				end)
			end
			if i > 1 then
				local previousUpMph = (spec[i - 1] and spec[i - 1].mph) or topMph()
				slider(scrollPanel, "Changes down under (mph, 0 = default)", 0, max(5, floor(previousUpMph)), 1, gearSpec.down or 0, function(value)
					gearSpec.down = value > 0 and value or nil; recompute(); refreshInfo()
				end)
			end
			local infoLabel = paragraph(scrollPanel, "", COLORS.muted)
			infoLabels[i] = infoLabel
		end
		heading(scrollPanel, "Notes")
		paragraph(scrollPanel, "The upshift rpm is where it changes up with W held and the car pulling hard; pulling gently it changes up a little earlier (" ..
			floor(Drivetrain.SHIFT.lazyUpRpm / Drivetrain.SHIFT.upRpm * 100 + 0.5) .. "% of it). Kickdown and the cornering rules stay as they are. " ..
			"Each gear is kept at least " .. floor((AudioEngine.GEAR_MIN_STEP - 1) * 100 + 0.5) .. "% taller than the one below, so every upshift drops the revs " ..
			"far enough to hear; aim for 15-35%. The top gear follows the car's top speed. Gearing only changes the sound: the car's speed comes from its script.")
		refreshInfo()
	end

	local function loadFromCar()
		if not prepare() then return end
		local current = IsValid(targetCar) and AudioEngine.GetEngineConfig(targetCar)
		spec = EngineDebug.GearingFromConfig(current or baseConfig)
	end

	buttons:Add("Apply live", function()
		if not IsValid(targetCar) then return end
		net.Start("audio_dbg_gear")
		net.WriteEntity(targetCar)
		net.WriteString(EngineDebug.EncodeGearing(spec))
		net.SendToServer()
		timer.Simple(0.3, refreshInfo)
	end, true)
	buttons:Add("Load from car", function() loadFromCar(); rebuild() end)
	buttons:Add("Auto-space", function() if prepare() then spec = autoSpace(#spec); rebuild() end end)
	buttons:Add("Back to the car's own", function()
		if not IsValid(targetCar) then return end
		net.Start("audio_dbg_gear")
		net.WriteEntity(targetCar)
		net.WriteString("")
		net.SendToServer()
		timer.Simple(0.3, function() loadFromCar(); rebuild() end)
	end)
	buttons:Add("Copy for sh_carlist (E.CAR_GEARING)", function()
		local carConfig = IsValid(targetCar) and AudioEngine.GetCarConfig(targetCar)
		if not carConfig then return end
		local line = EngineDebug.GearingLua(carConfig.name, EngineDebug.SanitizeGearing(spec))
		if not carConfig.perp then line = "gearing = " .. line:match("= (.*),$") .. ",   -- in its RegisterCar entry (sh_config.lua)" end
		SetClipboardText(line)
		report(true, "Copied: " .. line)
	end)

	if prepare() then loadFromCar() end
	if spec then rebuild() else paragraph(scrollPanel, "Sit in or look at a car first.", COLORS.red) end
end

---------------------------------------------------------------------------
-- page: rev response
---------------------------------------------------------------------------
-- a blip at a standstill: W from idle to 90% of redline, let go until back near idle, twice
local simCache = {}
local function simulateRevs(config, rise, fall)
	local key = string.format("%d_%d_%d_%d", config.idle, config.redline, rise, fall)
	local cached = simCache[key]
	if cached then return cached[1], cached[2], cached[3], cached[4] end
	local revConfig = { redline = config.redline, idle = config.idle, revRise = rise, revFall = fall }
	local deltaTime = 1 / 120
	local rpm, throttle = config.idle, 0
	local points = {}
	local riseTime, fallTime, phaseStart = nil, nil, 0
	local wantedThrottle, cycles, time = 1, 0, 0
	while time < 12 and cycles < 2 do
		throttle = throttle + Drivetrain.clamp(wantedThrottle - throttle, -deltaTime * 7, deltaTime * 5)
		local idleThrottle = Drivetrain.clamp((config.idle - rpm) / 400, 0, 0.3)
		rpm = Drivetrain.clamp(rpm + Drivetrain.FreeSpinRate(revConfig, rpm, max(throttle, idleThrottle)) * deltaTime, 0, config.redline)
		time = time + deltaTime
		points[#points + 1] = { time, rpm }
		if wantedThrottle == 1 and rpm >= config.redline * 0.9 then
			riseTime = riseTime or (time - phaseStart)
			wantedThrottle, phaseStart = 0, time
		elseif wantedThrottle == 0 and rpm <= config.idle + (config.redline - config.idle) * 0.08 then
			fallTime = fallTime or (time - phaseStart)
			wantedThrottle, phaseStart, cycles = 1, time, cycles + 1
		end
	end
	if table.Count(simCache) > 64 then simCache = {} end
	simCache[key] = { points, riseTime, fallTime, time }
	return points, riseTime, fallTime, time
end

local function buildRevPage(pagePanel)
	local scrollPanel = scroll(pagePanel)
	local scope = "car"
	local rise, fall = Drivetrain.REV.rise, Drivetrain.REV.fall
	local config
	local chart, riseSlider, fallSlider, infoLabel

	local function loadValues()
		config = IsValid(targetCar) and AudioEngine.GetEngineConfig(targetCar)
		if scope == "car" and config then
			rise, fall = config.revRise or Drivetrain.REV.rise, config.revFall or Drivetrain.REV.fall
		else
			rise, fall = Drivetrain.REV.rise, Drivetrain.REV.fall
		end
		if IsValid(riseSlider) then riseSlider:Set(rise); fallSlider:Set(fall) end
	end

	local function refresh()
		if not (config and IsValid(infoLabel)) then return end
		local _, riseTime, fallTime = simulateRevs(config, rise, fall)
		local _, _, defaultFallTime = simulateRevs(config, EngineDebug.REV_DEFAULT.rise, EngineDebug.REV_DEFAULT.fall)
		if not riseTime then
			infoLabel:SetText("The revs never reach 90% of redline: the fall is too strong for the rise.")
			infoLabel:SetTextColor(COLORS.red)
			return
		end
		infoLabel:SetTextColor(COLORS.text)
		infoLabel:SetText(string.format("Idle to 90%% of redline: %.2f s  ·  back down to near idle: %.2f s  (default %d / %d drops in %.2f s)",
			riseTime, fallTime or 0, EngineDebug.REV_DEFAULT.rise, EngineDebug.REV_DEFAULT.fall, defaultFallTime or 0))
	end

	heading(scrollPanel, "Applies to")
	local scopeBox = vgui.Create("DComboBox", scrollPanel)
	scopeBox:Dock(TOP)
	scopeBox:SetTall(22)
	scopeBox:AddChoice("This car", "car", true)
	scopeBox:AddChoice("Every car (DT.REV)", "all")
	scopeBox.OnSelect = function(_, _, _, value) scope = value; loadValues(); refresh() end

	heading(scrollPanel, "Response")
	riseSlider = slider(scrollPanel, "Rise (how fast the revs climb on W)", EngineDebug.REV_RANGE[1], EngineDebug.REV_RANGE[2], 0, rise, function(value) rise = floor(value + 0.5); refresh() end)
	fallSlider = slider(scrollPanel, "Fall (how fast they drop when you let go)", EngineDebug.REV_RANGE[1], EngineDebug.REV_RANGE[2], 0, fall, function(value) fall = floor(value + 0.5); refresh() end)
	infoLabel = paragraph(scrollPanel, "", COLORS.text)
	chart = vgui.Create("DPanel", scrollPanel)
	chart:Dock(TOP)
	chart:SetTall(160)
	chart:DockMargin(0, 4, 0, 6)
	chart.Paint = function(self, width, height)
		draw.RoundedBox(4, 0, 0, width, height, COLORS.panel)
		if not config then return end
		local leftMargin, rightMargin, topMargin, bottomMargin = 44, 10, 8, 18
		local function plot(points, color, maxTime)
			surface.SetDrawColor(color)
			local lastX, lastY
			for _, point in ipairs(points) do
				local pointX = floor(leftMargin + (width - leftMargin - rightMargin) * point[1] / maxTime)
				local pointY = floor(height - bottomMargin - (height - topMargin - bottomMargin) * point[2] / (config.redline * 1.05))
				if lastX then surface.DrawLine(lastX, lastY, pointX, pointY) end
				lastX, lastY = pointX, pointY
			end
		end
		local points, _, _, endTime = simulateRevs(config, rise, fall)
		local defaultPoints, _, _, defaultEndTime = simulateRevs(config, EngineDebug.REV_DEFAULT.rise, EngineDebug.REV_DEFAULT.fall)
		local maxTime = max(endTime, defaultEndTime, 1)
		for second = 1, maxTime do
			local secondX = floor(leftMargin + (width - leftMargin - rightMargin) * second / maxTime)
			draw.SimpleText(second .. " s", "DermaDefault", secondX, height - bottomMargin + 2, COLORS.muted, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
		end
		local redlineY = floor(height - bottomMargin - (height - topMargin - bottomMargin) / 1.05)
		surface.SetDrawColor(COLORS.red)
		surface.DrawLine(leftMargin, redlineY, width - rightMargin, redlineY)
		draw.SimpleText(formatThousands(config.redline), "DermaDefault", leftMargin - 4, redlineY, COLORS.muted, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		plot(defaultPoints, COLORS.line, maxTime)
		plot(points, COLORS.amber, maxTime)
		draw.SimpleText("two blips to 90% and back (amber), the default (grey)", "DermaDefault", width - rightMargin, topMargin, COLORS.muted, TEXT_ALIGN_RIGHT)
	end

	local buttons = buttonRow(scrollPanel)
	buttons:Add("Apply live", function()
		net.Start("audio_dbg_rev")
		net.WriteBool(scope == "all")
		if scope ~= "all" then net.WriteEntity(targetCar) end
		net.WriteString(EngineDebug.EncodeRev(rise, fall))
		net.SendToServer()
	end, true)
	buttons:Add("Back to default", function()
		net.Start("audio_dbg_rev")
		net.WriteBool(scope == "all")
		if scope ~= "all" then net.WriteEntity(targetCar) end
		net.WriteString("")
		net.SendToServer()
		timer.Simple(0.3, function() loadValues(); refresh() end)
	end)
	buttons:Add("Copy", function()
		local carConfig = IsValid(targetCar) and AudioEngine.GetCarConfig(targetCar)
		local line
		if scope == "all" then
			line = string.format("DT.REV = { rise = %d, fall = %d }   -- sh_drivetrain.lua", rise, fall)
		elseif carConfig and carConfig.perp then
			line = string.format('["%s"] = { rise = %d, fall = %d },   -- sh_carlist.lua E.CAR_REV', carConfig.name, rise, fall)
		else
			line = string.format("rev = { rise = %d, fall = %d },   -- its RegisterCar entry", rise, fall)
		end
		SetClipboardText(line)
		report(true, "Copied: " .. line)
	end)
	paragraph(scrollPanel, "To test: stand still, hold Space (handbrake: neutral) and tap W. Rise and fall are torques in the units of " ..
		"DT.TMAX (320, the Rev Bench value the baked sounds use; the game now defaults to 500 / 500). A higher fall lets the revs " ..
		"drop back quicker between blips. Only the free-revving engine changes: driving, the gears set the revs.")
	loadValues()
	refresh()
end

---------------------------------------------------------------------------
-- page: handling
---------------------------------------------------------------------------
local function isServerCvarOn(name) return (tonumber(serverState.cvars[name]) or 1) ~= 0 end

local function buildHandlingPage(pagePanel)
	local scrollPanel = scroll(pagePanel)
	heading(scrollPanel, "Handling changes")
	local allOffBox = check(scrollPanel, "PERP's own handling: switch all of the addon's handling changes off", false, function(checked)
		local changes = {}
		for _, cvarName in ipairs(EngineDebug.HANDLING_CVARS) do changes[#changes + 1] = { cvarName, checked and 0 or 1 } end
		sendCvars(changes)
	end)
	paragraph(scrollPanel, "Off = the cars drive on their vehicle script alone, as on PERP without this addon: no anti-spin setup, traction control " ..
		"or stability control. PERP's physics still go onto cars that fell back to the test script, so they match the server.")
	local boxes = {}
	for _, cvarName in ipairs({ "audio_engine_handling", "audio_engine_traction", "audio_engine_stability", "audio_engine_cruise" }) do
		local cvarEntry = EngineDebug.SERVER_CVAR_SET[cvarName]
		boxes[cvarName] = check(scrollPanel, cvarEntry[3] .. "   (" .. cvarName .. ")", true, function(checked) sendCvars({ { cvarName, checked and 1 or 0 } }) end)
	end
	paragraph(scrollPanel, "Power cut after a turn: when you let go of A/D with W held, the stability control's straight-line hold takes over " ..
		"and counts the car's leftover rotation from the turn as sliding; traction control then takes the power down to the slide " ..
		"floor. Switch traction or stability off above, or lower Straight-line hold / raise the slide floor below, to compare.", COLORS.amber)

	heading(scrollPanel, "Values (live, until a map change)")
	local sliders = {}
	for i, tunable in ipairs(EngineDebug.TUNABLES) do
		sliders[i] = slider(scrollPanel, tunable[6], tunable[3], tunable[4], tunable[5], serverState.tunables[i] or tunable[3], function(value)
			debounce("tune" .. i, function()
				net.Start("audio_dbg_tune")
				net.WriteUInt(i, 8)
				net.WriteFloat(value)
				net.SendToServer()
			end)
		end)
		sliders[i]:SetTooltip("E." .. tunable[1] .. "." .. tunable[2])
	end
	local buttons = buttonRow(scrollPanel)
	buttons:Add("Copy values as Lua", function()
		local lines = {}
		for i, tunable in ipairs(EngineDebug.TUNABLES) do
			local sourceFile = tunable[1] == "STABILITY_DEFAULTS" and "sv_stability.lua" or "sv_handling.lua"
			lines[#lines + 1] = string.format("E.%s.%s = %s   -- %s", tunable[1], tunable[2], KeyValues.Num(serverState.tunables[i] or 0), sourceFile)
		end
		SetClipboardText(table.concat(lines, "\n"))
		report(true, "Copied " .. #lines .. " values to the clipboard.")
	end)
	heading(scrollPanel, "Logs (server console)")
	local logButtons = buttonRow(scrollPanel)
	logButtons:Add("Acceleration log (30 s)", function() RunConsoleCommand("audio_engine_accel_log", "30") report(true, "Logging to the console: hold W from a standstill.") end)
	logButtons:Add("Handling info", function() RunConsoleCommand("audio_engine_handling_info") report(true, "Printed to the console.") end)

	stateListeners.handling = function()
		local allOff = true
		for _, cvarName in ipairs(EngineDebug.HANDLING_CVARS) do if isServerCvarOn(cvarName) then allOff = false end end
		if IsValid(allOffBox) then allOffBox:Set(allOff) end
		for cvarName, box in pairs(boxes) do if IsValid(box) then box:Set(isServerCvarOn(cvarName)) end end
		for i, sliderPanel in ipairs(sliders) do if IsValid(sliderPanel) and serverState.tunables[i] and not sliderPanel:IsEditing() then sliderPanel:Set(serverState.tunables[i]) end end
	end
	stateListeners.handling()
end

---------------------------------------------------------------------------
-- page: settings
---------------------------------------------------------------------------
local function buildSettingsPage(pagePanel)
	local scrollPanel = scroll(pagePanel)
	heading(scrollPanel, "This client")
	local function conVarSlider(name, text, low, high, decimals)
		local sliderPanel = vgui.Create("DNumSlider", scrollPanel)
		sliderPanel:Dock(TOP)
		sliderPanel:SetTall(26)
		sliderPanel:SetText(text)
		sliderPanel:SetMinMax(low, high)
		sliderPanel:SetDecimals(decimals)
		sliderPanel:SetConVar(name)
		sliderPanel.Label:SetTextColor(COLORS.text)
		sliderPanel.Label:SetWide(260)
		sliderPanel.TextArea:SetTextColor(COLORS.amber)
		sliderPanel:SetTooltip(name)
	end
	local function conVarCheck(name, text)
		local checkBox = vgui.Create("DCheckBoxLabel", scrollPanel)
		checkBox:Dock(TOP)
		checkBox:DockMargin(0, 3, 0, 3)
		checkBox:SetText(text .. "   (" .. name .. ")")
		checkBox:SetTextColor(COLORS.text)
		checkBox:SetConVar(name)
	end
	local function conVarCombo(name, text, choices)
		local comboRow = vgui.Create("DPanel", scrollPanel)
		comboRow:Dock(TOP)
		comboRow:SetTall(24)
		comboRow.Paint = nil
		local labelPanel = label(comboRow, text, COLORS.text)
		labelPanel:Dock(LEFT)
		labelPanel:SetWide(260)
		local comboBox = vgui.Create("DComboBox", comboRow)
		comboBox:Dock(LEFT)
		comboBox:SetWide(220)
		local current = GetConVar(name) and GetConVar(name):GetString() or ""
		for _, choice in ipairs(choices) do comboBox:AddChoice(choice[2], choice[1], tostring(choice[1]) == current) end
		comboBox.OnSelect = function(_, _, _, value) RunConsoleCommand(name, tostring(value)) end
		comboBox:SetTooltip(name)
	end
	conVarSlider("audio_engine_volume", "Engine volume", 0, 2, 2)
	conVarSlider("audio_engine_roadnoise", "Tyre roar", 0, 2, 2)
	conVarSlider("audio_engine_windnoise", "Wind noise", 0, 2, 2)
	conVarSlider("audio_engine_doppler", "Doppler (1 = real)", 0, 4, 2)
	conVarSlider("audio_engine_passby", "Pass-by swell", 0, 2, 2)
	conVarCombo("audio_engine_tunnel", "Tunnel effect", { { 0, "Off" }, { 1, "The map's own (default)" }, { 6, "Medium tunnel" }, { 7, "Large tunnel" } })
	conVarCheck("audio_engine_hud", "Speed / rpm HUD")
	conVarCombo("audio_engine_units", "HUD units", { { "mph", "mph" }, { "kmh", "km/h" } })
	conVarSlider("audio_engine_hud_scale", "HUD size", 0.5, 2, 2)
	conVarCombo("audio_engine_samplerate", "Generated sound quality", { { 44100, "44.1 kHz" }, { 22050, "22.05 kHz (faster)" } })
	conVarSlider("audio_engine_genbudget", "Generation budget (ms per frame)", 1, 50, 0)
	conVarSlider("audio_engine_maxsounds", "Generated sounds kept", 2, 40, 0)
	conVarCheck("audio_engine_baked", "Play the pre-generated (baked) stock sounds")
	local keyRow = vgui.Create("DPanel", scrollPanel)
	keyRow:Dock(TOP)
	keyRow:SetTall(24)
	keyRow.Paint = nil
	local keyLabel = label(keyRow, "Start key (a key name, none = off)", COLORS.text)
	keyLabel:Dock(LEFT)
	keyLabel:SetWide(260)
	local keyEntry = vgui.Create("DTextEntry", keyRow)
	keyEntry:Dock(LEFT)
	keyEntry:SetWide(80)
	keyEntry:SetConVar("audio_engine_startkey")
	local clientButtons = buttonRow(scrollPanel)
	clientButtons:Add("Regenerate engine sounds", function() RunConsoleCommand("audio_engine_rebuild") end)

	heading(scrollPanel, "Server")
	local boxes, others = {}, {}
	for _, cvarEntry in ipairs(EngineDebug.SERVER_CVARS) do
		local cvarName = cvarEntry[1]
		if cvarEntry[2] == "bool" and not table.HasValue(EngineDebug.HANDLING_CVARS, cvarName) and cvarName ~= "audio_engine_cruise" then
			boxes[cvarName] = check(scrollPanel, cvarEntry[3] .. "   (" .. cvarName .. ")", false, function(checked) sendCvars({ { cvarName, checked and 1 or 0 } }) end)
		elseif cvarEntry[2] ~= "bool" then
			others[cvarName] = slider(scrollPanel, cvarEntry[3], cvarEntry[4], cvarEntry[5], cvarEntry[2] == "int" and 0 or 1, tonumber(serverState.cvars[cvarName]) or cvarEntry[4], function(value)
				debounce(cvarName, function() sendCvars({ { cvarName, value } }) end)
			end)
		end
	end
	local serverButtons = buttonRow(scrollPanel)
	serverButtons:Add("Open the Rev Bench editor", function() RunConsoleCommand("audio_engine_menu") end)
	serverButtons:Add("Show the brake flap (10 s)", function() RunConsoleCommand("audio_engine_wingflap") end)
	serverButtons:Add("Dump bone manipulations", function() RunConsoleCommand("audio_engine_bonedump") end)

	stateListeners.settings = function()
		for cvarName, box in pairs(boxes) do if IsValid(box) then box:Set(isServerCvarOn(cvarName)) end end
		for cvarName, sliderPanel in pairs(others) do
			if IsValid(sliderPanel) and serverState.cvars[cvarName] and not sliderPanel:IsEditing() then
				sliderPanel:Set(tonumber(serverState.cvars[cvarName]) or 0)
			end
		end
	end
	stateListeners.settings()
end

---------------------------------------------------------------------------
-- the menu
---------------------------------------------------------------------------
local function pickTarget()
	local player = LocalPlayer()
	local vehicle = player:GetVehicle()
	if IsValid(vehicle) and AudioEngine.GetCarConfig(vehicle) then return vehicle end
	local trace = player:GetEyeTrace()
	if IsValid(trace.Entity) and AudioEngine.GetCarConfig(trace.Entity) and trace.HitPos:DistToSqr(player:GetShootPos()) < 400 * 400 then return trace.Entity end
	return nil
end

function EngineDebug.OpenMenu(vehicle)
	local player = LocalPlayer()
	if not EngineDebug.Allowed(player) then
		chat.AddText(COLORS.amber, "[Audio Engine debug] ", COLORS.text, EngineDebug.Enabled() and "Superadmins only." or "The debug tools are off on this server (audio_engine_debug 0).")
		return
	end
	targetCar = IsValid(vehicle) and AudioEngine.GetCarConfig(vehicle) and vehicle or pickTarget()
	if not targetCar then
		chat.AddText(COLORS.amber, "[Audio Engine debug] ", COLORS.text, "Sit in or look at a car with the procedural engine.")
		return
	end
	if IsValid(frame) then frame:Remove() end
	stateListeners, scriptListener = {}, nil
	if scriptData and scriptData.vehicle ~= targetCar then scriptData = nil end

	frame = vgui.Create("DFrame")
	frame:SetSize(min(1000, ScrW() - 40), min(820, ScrH() - 40))
	frame:Center()
	frame:SetTitle("")
	frame:SetSizable(true)
	frame:SetMinWidth(700)
	frame:SetMinHeight(500)
	frame:MakePopup()
	frame:DockPadding(10, 30, 10, 8)
	frame.Paint = function(self, width, height)
		draw.RoundedBox(8, 0, 0, width, height, COLORS.background)
		local carConfig = IsValid(targetCar) and AudioEngine.GetCarConfig(targetCar)
		draw.SimpleText("AUDIO ENGINE · DEBUG", "DermaDefaultBold", 12, 8, COLORS.amber)
		draw.SimpleText(carConfig and carConfig.name or "(no car)", "DermaDefaultBold", 170, 8, COLORS.text)
	end
	local retargetButton = button(frame, "Use the car I'm in / looking at", function()
		local pickedCar = pickTarget()
		if pickedCar then EngineDebug.OpenMenu(pickedCar) else report(false, "No car in reach.") end
	end)
	retargetButton:SetPos(frame:GetWide() - retargetButton:GetWide() - 40, 4)
	retargetButton:SetTall(20)
	local oldLayout = frame.PerformLayout
	frame.PerformLayout = function(self, width, height)
		if oldLayout then oldLayout(self, width, height) end
		retargetButton:SetPos(width - retargetButton:GetWide() - 40, 4)
	end

	status = label(frame, "Changes made here are live tests: copy what works back into the files.", COLORS.muted)
	status:Dock(BOTTOM)
	status:DockMargin(4, 6, 0, 0)

	local sheet = vgui.Create("DPropertySheet", frame)
	sheet:Dock(FILL)
	sheet.Paint = function(self, width, height) draw.RoundedBox(4, 0, 20, width, height - 20, COLORS.panel) end
	local function addPage(name, icon, build)
		local pagePanel = vgui.Create("DPanel", sheet)
		pagePanel.Paint = nil
		build(pagePanel)
		sheet:AddSheet(name, pagePanel, icon)
	end
	addPage("Handling script", "icon16/page_edit.png", buildScriptPage)
	addPage("Gearing", "icon16/cog.png", buildGearPage)
	addPage("Rev response", "icon16/chart_curve.png", buildRevPage)
	addPage("Handling", "icon16/car.png", buildHandlingPage)
	addPage("Settings", "icon16/wrench.png", buildSettingsPage)
	requestState()
end

-- (a Lua refresh of the core replaces AudioEngine.GetEngineConfig: wrap it again)
timer.Create("audio_engine_debug_install", 5, 0, EngineDebug.Install)

concommand.Add("audio_engine_debug_menu", function() EngineDebug.OpenMenu() end, nil, "Audio Engine debug tools (superadmins)")

if properties and properties.Add then
	properties.Add("audio_engine_debug", {
		MenuLabel = "Engine debug tools",
		Order = 2001,
		MenuIcon = "icon16/bug.png",
		Filter = function(self, entity, player) return EngineDebug.Allowed(player) and IsValid(entity) and AudioEngine.GetCarConfig(entity) ~= nil end,
		Action = function(self, entity) EngineDebug.OpenMenu(entity) end,
	})
end
