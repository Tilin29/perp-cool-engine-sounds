--[[
	Audio Engine - in-game tuning menu (client)

	The Rev Bench controls for the car you're in (or looking at): engine presets, layout,
	pitch, exhaust tone, volume, realism, turbo, idle, redline, acceleration and top speed.
	Apply sends the profile to the server, which shares it with everyone; each client then
	generates the new engine sound in the background. (Gearing is set per car by shift speeds in
	the debug module's gearing editor: the old ratio editor here never reached the car.)

	Off unless the server turns it on: audio_engine_editor 1. Then open with: !engine in chat,
	`audio_engine_menu` in console, or right-click the car in the context menu (C) -> "Engine tuning".
]]

local AudioEngine = AUDIO_ENGINE

local COLORS = {
	background = Color(15, 18, 22, 250),
	panel = Color(23, 27, 33, 255),
	face = Color(18, 21, 26, 255),
	line = Color(42, 48, 57, 255),
	text = Color(232, 227, 214, 255),
	muted = Color(141, 147, 156, 255),
	amber = Color(255, 165, 61, 255),
	amberDim = Color(107, 71, 25, 255),
	red = Color(255, 75, 58, 255),
	green = Color(95, 211, 138, 255),
}

local frame
local floor = math.floor

local function makeFonts(scale)
	local function createFont(name, size, weight)
		surface.CreateFont(name, { font = "Roboto", size = math.max(9, floor(size * scale)), weight = weight, extended = true })
	end
	createFont("AudioMenu_Title", 30, 800)
	createFont("AudioMenu_H", 14, 700)
	createFont("AudioMenu_Body", 16, 500)
	createFont("AudioMenu_Small", 13, 500)
	createFont("AudioMenu_Num", 16, 700)
end

local function roundBox(radius, x, y, width, height, fill, border)
	draw.RoundedBox(radius, x, y, width, height, border or COLORS.line)
	draw.RoundedBox(radius, x + 1, y + 1, width - 2, height - 2, fill)
end

local function formatThousands(number)
	local digits = tostring(floor(number + 0.5))
	return (digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

---------------------------------------------------------------------------
-- styled controls
---------------------------------------------------------------------------
local function label(parent, text, font, color)
	local labelPanel = vgui.Create("DLabel", parent)
	labelPanel:SetFont(font or "AudioMenu_Body")
	labelPanel:SetTextColor(color or COLORS.text)
	labelPanel:SetText(text)
	labelPanel:SizeToContents()
	return labelPanel
end

local function styleCombo(comboBox)
	comboBox:SetFont("AudioMenu_Body")
	comboBox:SetTextColor(COLORS.text)
	comboBox.Paint = function(self, width, height) roundBox(6, 0, 0, width, height, COLORS.face) end
end

local function slider(parent, scale, text, minValue, maxValue, decimals, value, onChange, formatValue)
	local sliderRow = vgui.Create("DPanel", parent)
	sliderRow:SetTall(floor(44 * scale))
	sliderRow.Paint = nil
	local titleLabel = label(sliderRow, text)
	local valueLabel = label(sliderRow, "", "AudioMenu_Num", COLORS.amber)
	local sliderControl = vgui.Create("DSlider", sliderRow)
	sliderControl:SetLockY(0.5)
	sliderControl:SetTrapInside(true)
	sliderControl.Paint = function(self, width, height)
		draw.RoundedBox(3, 0, height / 2 - 3, width, 6, COLORS.line)
		draw.RoundedBox(3, 0, height / 2 - 3, width * self:GetSlideX(), 6, COLORS.amberDim)
	end
	sliderControl.Knob:SetSize(floor(14 * scale), floor(14 * scale))
	sliderControl.Knob.Paint = function(self, width, height) draw.RoundedBox(width / 2, 0, 0, width, height, COLORS.amber) end
	local function showValue(newValue)
		valueLabel:SetText(formatValue and formatValue(newValue) or string.format("%." .. decimals .. "f", newValue))
		valueLabel:SizeToContents()
		sliderRow:InvalidateLayout()
	end
	local currentValue = value
	sliderControl:SetSlideX((value - minValue) / (maxValue - minValue))
	showValue(value)
	sliderControl.TranslateValues = function(self, slideX, slideY)
		local newValue = minValue + (maxValue - minValue) * slideX
		local rounding = 10 ^ decimals
		newValue = floor(newValue * rounding + 0.5) / rounding
		if newValue ~= currentValue then
			currentValue = newValue
			showValue(newValue)
			onChange(newValue)
		end
		return (newValue - minValue) / (maxValue - minValue), slideY
	end
	sliderRow.PerformLayout = function(self, width, height)
		titleLabel:SetPos(0, 0)
		valueLabel:SetPos(width - valueLabel:GetWide(), 0)
		sliderControl:SetPos(0, titleLabel:GetTall() + 4)
		sliderControl:SetSize(width, height - titleLabel:GetTall() - 4)
	end
	return sliderRow
end

local function checkbox(parent, text, value, onChange)
	local checkBox = vgui.Create("DCheckBoxLabel", parent)
	checkBox:SetText(text)
	checkBox:SetFont("AudioMenu_Body")
	checkBox:SetTextColor(COLORS.text)
	checkBox:SetValue(value and 1 or 0)
	checkBox.OnChange = function(_, checked) onChange(checked) end
	return checkBox
end

local function button(parent, text, primary, onClick)
	local buttonPanel = vgui.Create("DButton", parent)
	buttonPanel:SetText(text)
	buttonPanel:SetFont("AudioMenu_H")
	buttonPanel:SetTextColor(primary and Color(27, 18, 6) or COLORS.text)
	buttonPanel.Paint = function(self, width, height)
		local fill = primary and COLORS.amber or COLORS.face
		if self:IsHovered() then fill = primary and Color(255, 185, 100) or COLORS.line end
		roundBox(8, 0, 0, width, height, fill, primary and COLORS.amber or COLORS.line)
	end
	buttonPanel.DoClick = onClick
	return buttonPanel
end

local function card(parent, title, scale)
	local cardPanel = vgui.Create("DPanel", parent)
	cardPanel.Paint = function(self, width, height)
		roundBox(12, 0, 0, width, height, COLORS.panel)
		draw.SimpleText(string.upper(title), "AudioMenu_H", 16 * scale, 14 * scale, COLORS.muted)
	end
	cardPanel:DockPadding(16 * scale, 38 * scale, 16 * scale, 14 * scale)
	return cardPanel
end

---------------------------------------------------------------------------
-- the menu
---------------------------------------------------------------------------
local function toneName(tone)
	return tone < 0.3 and "Stock" or tone < 0.7 and "Sport" or "Straight pipe"
end

function AudioEngine.OpenMenu(vehicle)
	local player = LocalPlayer()
	if not AudioEngine.EditorEnabled() then
		chat.AddText(COLORS.amber, "[Audio Engine] ", COLORS.text, "The engine editor is off on this server (audio_engine_editor 0).")
		return
	end
	if not IsValid(vehicle) then
		vehicle = player:GetVehicle()
		if not (IsValid(vehicle) and AudioEngine.GetCarConfig(vehicle)) then
			local trace = player:GetEyeTrace()
			vehicle = trace.Entity
			if not (IsValid(vehicle) and trace.HitPos:DistToSqr(player:GetShootPos()) < 300 * 300) then vehicle = nil end
		end
	end
	if not (IsValid(vehicle) and AudioEngine.GetCarConfig(vehicle)) then
		chat.AddText(COLORS.amber, "[Audio Engine] ", COLORS.text, "Sit in or look at a car with the procedural engine to tune its engine.")
		return
	end
	if IsValid(frame) then frame:Remove() end

	local carConfig = AudioEngine.GetCarConfig(vehicle)
	local currentProfile = AudioEngine.GetEngineConfig(vehicle).profile
	-- an editable copy
	local profile = {}
	for key, value in pairs(currentProfile) do profile[key] = value end
	profile.gears = {}
	for i, ratio in ipairs(currentProfile.gears) do profile.gears[i] = ratio end
	profile.fit = 1   -- (gearing comes from the car: fitted, or its own AudioEngine.CAR_GEARING)

	local scale = math.Clamp(ScrH() / 1080, 0.7, 1.6)
	if 870 * scale > ScrH() - 40 then scale = (ScrH() - 40) / 870 end   -- always fits on screen
	makeFonts(scale)
	local frameWidth, frameHeight = floor(720 * scale), floor(870 * scale)
	frame = vgui.Create("DFrame")
	frame:SetSize(frameWidth, frameHeight)
	frame:Center()
	frame:SetTitle("")
	frame:ShowCloseButton(false)
	frame:SetDraggable(true)
	frame:MakePopup()
	frame:DockPadding(20 * scale, 20 * scale, 20 * scale, 16 * scale)
	frame.Paint = function(self, width, height)
		roundBox(16, 0, 0, width, height, COLORS.background)
	end

	-- header
	local header = vgui.Create("DPanel", frame)
	header:Dock(TOP)
	header:SetTall(floor(54 * scale))
	header.Paint = function(self, width, height)
		surface.SetFont("AudioMenu_Title")
		local titleWidth = surface.GetTextSize("REV")
		draw.SimpleText("REV", "AudioMenu_Title", 0, 0, COLORS.text)
		draw.SimpleText("·", "AudioMenu_Title", titleWidth + 2 * scale, 0, COLORS.amber)
		local dotWidth = surface.GetTextSize("·")
		draw.SimpleText("BENCH", "AudioMenu_Title", titleWidth + dotWidth + 4 * scale, 0, COLORS.text)
		draw.SimpleText(carConfig.name .. " · engine generated live on every client", "AudioMenu_Small", 0, 34 * scale, COLORS.muted)
	end
	local closeButton = button(header, "✕", false, function() frame:Remove() end)
	closeButton:SetSize(floor(34 * scale), floor(34 * scale))
	header.PerformLayout = function(self, width) closeButton:SetPos(width - closeButton:GetWide(), 0) end

	-- preset row
	local presetRow = vgui.Create("DPanel", frame)
	presetRow:Dock(TOP)
	presetRow:SetTall(floor(38 * scale))
	presetRow:DockMargin(0, 6 * scale, 0, 14 * scale)
	presetRow.Paint = nil
	local presetBox = vgui.Create("DComboBox", presetRow)
	styleCombo(presetBox)
	presetBox:Dock(LEFT)
	presetBox:SetWide(floor(380 * scale))
	local applyBtn = button(presetRow, "Apply to car", true, nil)
	applyBtn:Dock(RIGHT)
	applyBtn:SetWide(floor(150 * scale))
	local stockBtn = button(presetRow, "Back to stock", false, nil)
	stockBtn:Dock(RIGHT)
	stockBtn:SetWide(floor(140 * scale))
	stockBtn:DockMargin(0, 0, 10 * scale, 0)

	local body = vgui.Create("DPanel", frame)
	body:Dock(FILL)
	body.Paint = nil

	local footer = label(frame, "", "AudioMenu_Small", COLORS.muted)
	footer:Dock(BOTTOM)
	footer:DockMargin(0, 10 * scale, 0, 0)
	footer:SetTall(floor(18 * scale))

	local stats = {}  -- labels refreshed on every change
	local rebuild

	-- the car with its real (stock) top speed filled in
	local effectiveCar = {}
	for key, value in pairs(carConfig) do effectiveCar[key] = value end
	effectiveCar.topSpeed = AudioEngine.CarTopSpeed(vehicle, carConfig)
	effectiveCar.powerKg = AudioEngine.CarPower(vehicle, carConfig)

	local function refreshStats()
		local config = AudioEngine.ResolveProfile(effectiveCar, AudioEngine.SanitizeProfile(profile))
		local cylinderCount = AudioEngine.LAYOUT_CYL[profile.layout] or 4
		local idleFiringHz = profile.idle / 60 * cylinderCount / 2 * profile.pitch
		local redlineFiringHz = profile.redline / 60 * cylinderCount / 2 * profile.pitch
		if stats.engine then
			local description
			if profile.layout == "electric" then
				description = string.format("Electric motor · up to %s rpm", formatThousands(profile.redline))
			elseif profile.layout == "rotary2" or profile.layout == "rotary3" then
				description = string.format("%d rotors · fires %d Hz at idle, %d Hz at redline", profile.layout == "rotary2" and 2 or 3, idleFiringHz, redlineFiringHz)
			else
				description = string.format("%d cylinders · fires %d Hz at idle, %d Hz at redline", cylinderCount, idleFiringHz, redlineFiringHz)
			end
			stats.engine:SetText(string.format("%s\n%d loops to generate (~%.1f s of CPU per player)",
				description, #config.bands * 2 + 6, 0.13 * #config.bands + 0.4))
		end
		local preset = AudioEngine.EnginePreset(profile.preset)
		presetBox:SetText(preset and preset.name or "Custom engine")
	end

	local function changed()
		profile.preset = "custom"
		refreshStats()
	end

	rebuild = function()
		body:Clear()
		stats = {}
		local columnWidth = floor((frameWidth - 40 * scale - 14 * scale) / 2)

		-------------------------------------------------- Sound
		local soundCard = card(body, "Sound", scale)
		soundCard:Dock(LEFT)
		soundCard:SetWide(columnWidth)
		local layoutLabel = label(soundCard, "Engine layout")
		layoutLabel:Dock(TOP)
		local layoutBox = vgui.Create("DComboBox", soundCard)
		styleCombo(layoutBox)
		layoutBox:Dock(TOP)
		layoutBox:SetTall(floor(30 * scale))
		layoutBox:DockMargin(0, 4 * scale, 0, 10 * scale)
		for _, option in ipairs(AudioEngine.LAYOUT_ORDER) do layoutBox:AddChoice(option[2], option[1], option[1] == profile.layout) end
		layoutBox.OnSelect = function(_, _, _, layoutKey) profile.layout = layoutKey; changed(); timer.Simple(0, rebuild) end
		local function addRow(panel) panel:Dock(TOP); panel:DockMargin(0, 0, 0, 6 * scale) end
		addRow(slider(soundCard, scale, "Pitch", 0.5, 2, 2, profile.pitch, function(value) profile.pitch = value; changed() end, function(value) return string.format("×%.2f", value) end))
		addRow(slider(soundCard, scale, "Exhaust tone", 0, 1, 2, profile.tone, function(value) profile.tone = value; changed() end, toneName))
		addRow(slider(soundCard, scale, "Volume", 0, 1.5, 2, profile.volume, function(value) profile.volume = value; changed() end, function(value) return floor(value * 100 + 0.5) .. "%" end))
		addRow(slider(soundCard, scale, "Realism", 0, 1, 1, profile.realism, function(value) profile.realism = value; changed() end,
			function(value) return value == 0 and "Rev Bench" or value < 1 and string.format("%d%%", value * 100) or "Full" end))
		addRow(slider(soundCard, scale, "Gurgle (off-throttle burble)", 0, 1, 2, profile.gurgle, function(value) profile.gurgle = value; changed() end,
			function(value) return value <= 0 and "Off" or value < 0.3 and "Light" or value < 0.65 and "Burbly" or "Heavy" end))
		addRow(slider(soundCard, scale, "Pops & bangs (how often)", 0, 1, 2, profile.pops, function(value) profile.pops = value; changed() end,
			function(value) return value <= 0 and "Off" or value < 0.25 and "Rare" or value < 0.5 and "Occasional" or value < 0.8 and "Frequent" or "Constant" end))
		addRow(slider(soundCard, scale, "Pops & bangs volume", 0, 2, 2, profile.popVol, function(value) profile.popVol = value; changed() end,
			function(value) return floor(value * 100 + 0.5) .. "%" end))
		addRow(slider(soundCard, scale, "Pops & bangs tone", 0, 1, 2, profile.popTone, function(value) profile.popTone = value; changed() end,
			function(value) return value < 0.25 and "Muffled" or value < 0.6 and "Sport" or value < 0.85 and "Loud pipe" or "Straight pipe" end))
		local turboBox = checkbox(soundCard, "Turbocharged (whistle)", profile.turbo, function(value) profile.turbo = value; changed(); timer.Simple(0, rebuild) end)
		turboBox:Dock(TOP)
		turboBox:DockMargin(0, 6 * scale, 0, 0)
		if profile.turbo then
			local percent = function(value) return floor(value * 100 + 0.5) .. "%" end
			local turboVolumeSlider = slider(soundCard, scale, "Turbo whistle volume", 0, 2, 2, profile.turboVol or 1, function(value) profile.turboVol = value; changed() end, percent)
			turboVolumeSlider:Dock(TOP)
			turboVolumeSlider:DockMargin(0, 6 * scale, 0, 0)
			local blowOffBox = checkbox(soundCard, "Blow-off valve (pssh when you lift)", profile.bov, function(value) profile.bov = value; changed(); timer.Simple(0, rebuild) end)
			blowOffBox:Dock(TOP)
			blowOffBox:DockMargin(0, 6 * scale, 0, 0)
			if profile.bov then
				local blowOffVolumeSlider = slider(soundCard, scale, "Blow-off valve volume", 0, 2, 2, profile.bovVol or 1, function(value) profile.bovVol = value; changed() end, percent)
				blowOffVolumeSlider:Dock(TOP)
				blowOffVolumeSlider:DockMargin(0, 6 * scale, 0, 0)
			end
		end

		-------------------------------------------------- RPM
		local rpmCard = card(body, "RPM & performance", scale)
		rpmCard:Dock(FILL)
		rpmCard:DockMargin(14 * scale, 0, 0, 0)
		local addRpmRow = function(panel) panel:Dock(TOP); panel:DockMargin(0, 0, 0, 6 * scale) end
		addRpmRow(slider(rpmCard, scale, "Idle", 500, 1500, 0, profile.idle, function(value) profile.idle = floor(value / 25 + 0.5) * 25; changed() end,
			function(value) return formatThousands(floor(value / 25 + 0.5) * 25) end))
		local maxRedline = profile.layout == "electric" and 16000 or 12000
		addRpmRow(slider(rpmCard, scale, "Redline", 3500, maxRedline, 0, profile.redline, function(value) profile.redline = floor(value / 100 + 0.5) * 100; changed() end,
			function(value) return formatThousands(floor(value / 100 + 0.5) * 100) end))
		-- real performance: changes how the car actually drives; the revs and gears follow
		addRpmRow(slider(rpmCard, scale, "Acceleration", 0.5, 2.5, 2, profile.accel, function(value) profile.accel = floor(value * 20 + 0.5) / 20; changed() end,
			function(value) return string.format("×%.2f", floor(value * 20 + 0.5) / 20) end))
		-- shown in mph (the profile keeps km/h): steps of 5 mph, snapping to the car's stock speed
		local KMH_PER_MPH = 1.609344
		local stockMph = floor(AudioEngine.CarTopSpeed(vehicle, carConfig) / KMH_PER_MPH + 0.5)
		local function snapMph(value)
			value = floor(value + 0.5)
			if math.abs(value - stockMph) < 3 then return stockMph, true end
			return floor(value / 5 + 0.5) * 5, false
		end
		addRpmRow(slider(rpmCard, scale, "Top speed", 25, 280, 0, profile.vmax > 0 and profile.vmax / KMH_PER_MPH or stockMph, function(value)
			local mph, isStock = snapMph(value)
			profile.vmax = isStock and 0 or floor(mph * KMH_PER_MPH + 0.5)
			changed()
		end, function(value)
			local mph, isStock = snapMph(value)
			return isStock and (mph .. " mph (stock)") or (mph .. " mph")
		end))
		stats.engine = label(rpmCard, "", "AudioMenu_Small", COLORS.muted)
		stats.engine:Dock(TOP)
		stats.engine:DockMargin(0, 8 * scale, 0, 0)
		stats.engine:SetWrap(true)
		stats.engine:SetAutoStretchVertical(true)
		local note = label(rpmCard, "Acceleration and top speed change the car's real physics; the revs, gears and sound follow.", "AudioMenu_Small", COLORS.muted)
		note:Dock(BOTTOM)
		note:SetWrap(true)
		note:SetAutoStretchVertical(true)

		-- generation quality: a setting of this client only (audio_engine_samplerate)
		local qualityLabel = label(rpmCard, "Sound quality (your PC only)")
		qualityLabel:Dock(TOP)
		qualityLabel:DockMargin(0, 14 * scale, 0, 0)
		local qualityBox = vgui.Create("DComboBox", rpmCard)
		styleCombo(qualityBox)
		qualityBox:Dock(TOP)
		qualityBox:SetTall(floor(30 * scale))
		qualityBox:DockMargin(0, 4 * scale, 0, 0)
		local rateConVar = GetConVar("audio_engine_samplerate")
		local currentRate = rateConVar and rateConVar:GetInt() or 44100
		qualityBox:AddChoice("44.1 kHz (best, ~2 s per engine)", 44100, currentRate ~= 22050)
		qualityBox:AddChoice("22.05 kHz (twice as fast, half the memory)", 22050, currentRate == 22050)
		qualityBox.OnSelect = function(_, _, _, value)
			-- changing it regenerates every engine sound at the new rate
			RunConsoleCommand("audio_engine_samplerate", tostring(value))
		end

		refreshStats()
	end

	for _, preset in ipairs(AudioEngine.ENGINE_PRESETS) do presetBox:AddChoice(preset.name, preset.id) end
	presetBox:AddChoice("Custom engine", "custom")
	presetBox.OnSelect = function(_, _, _, presetId)
		if presetId == "custom" then return end
		-- switching engines keeps the performance settings
		local keptAcceleration, keptTopSpeed = profile.accel, profile.vmax
		profile = AudioEngine.ProfileFromPreset(presetId)
		profile.accel, profile.vmax = keptAcceleration, keptTopSpeed
		rebuild()
	end

	local function sendProfile(profileString)
		if not IsValid(vehicle) then return end
		net.Start("audio_engine_set")
		net.WriteEntity(vehicle)
		net.WriteString(profileString)
		net.SendToServer()
	end
	applyBtn.DoClick = function()
		sendProfile(AudioEngine.EncodeProfile(profile))
		surface.PlaySound("buttons/button14.wav")
	end
	stockBtn.DoClick = function()
		sendProfile("")
		profile = AudioEngine.CarStockProfile(carConfig)
		rebuild()
	end

	local accessConVar = GetConVar("audio_engine_tuneaccess")
	local accessLevel = accessConVar and accessConVar:GetInt() or 1
	local allowed = accessLevel == 0 or (accessLevel == 1 and player:IsAdmin()) or (accessLevel >= 2 and player:IsSuperAdmin())
	footer:SetText(allowed
		and "Applies to this car for everyone. A new engine takes a few seconds to generate; the old sound keeps playing until it's ready."
		or "Only " .. (accessLevel >= 2 and "superadmins" or "admins") .. " can apply engine changes on this server. You can still try settings here.")
	footer:SetTextColor(allowed and COLORS.muted or COLORS.red)

	rebuild()
end

concommand.Add("audio_engine_menu", function() AudioEngine.OpenMenu() end, nil, "Open the engine tuning menu")

-- right-click the car in the context menu (sandbox-based gamemodes)
if properties and properties.Add then
	properties.Add("audio_engine_tune", {
		MenuLabel = "Engine tuning",
		Order = 2000,
		MenuIcon = "icon16/car.png",
		Filter = function(self, entity, player) return AudioEngine.EditorEnabled() and IsValid(entity) and AudioEngine.GetCarConfig(entity) ~= nil end,
		Action = function(self, entity) AudioEngine.OpenMenu(entity) end,
	})
end
