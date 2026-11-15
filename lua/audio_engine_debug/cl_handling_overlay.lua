--[[
	Audio Engine debug module - the handling overlay (client). Not part of the final addon (see sh_debug.lua).

	While you drive a car (superadmins, audio_engine_debug 1), the vehicle-script values you pinned
	(the dot in the menu's Handling script page) and every value changed from the file are listed on
	the right of the screen. Hold C (the context menu) to edit them: type a value, scroll over it,
	or step it with - / + (Shift: a tenth of the step). Each edit goes onto the car live a moment
	after you stop. x takes a row off (a changed value comes back once it changes again).

	audio_engine_debug_overlay (client, default 1): 0 hides it (the Hide button sets that; the
	menu's "C overlay in the car" box turns it back on). Shown only when there is something on it.
	The values come from the menu's shared script data (cl_debug.lua: EngineDebug.ScriptData and
	the functions next to it); pins and dismissed values in data/audio_engine_debug/overlay.json.
]]

local AudioEngine = AUDIO_ENGINE
local EngineDebug = AudioEngine.Debug
local KeyValues = AudioEngine.KV

local overlayConVar = CreateClientConVar("audio_engine_debug_overlay", "1", true, false,
	"1 = the pinned / changed vehicle-script values on screen while driving, editable with C held (debug tools); 0 = hidden")

local COLORS = {
	background = Color(18, 21, 26, 235), face = Color(34, 39, 47), line = Color(52, 58, 68),
	text = Color(232, 227, 214), muted = Color(150, 156, 165), amber = Color(255, 165, 61),
	changed = Color(70, 52, 25), bad = Color(90, 30, 30), green = Color(95, 211, 138),
}
local WIDTH, ROW_HEIGHT, HEADER_HEIGHT, FOOTER_HEIGHT = 340, 22, 24, 18
local APPLY_DELAY = 0.3   -- s after the last edit before it goes onto the car

local editPanel          -- the editable copy, a child of the context menu (shown while C is held)
local editPanelKey       -- which car / rows it was built for
-- rows shown once stay while you sit in that car (stepping a value back to the file's doesn't take it away), until x
local stickyRows = { vehicle = nil, indices = nil }

-- the car you drive, when the overlay may show for it
local function overlayCar()
	if not overlayConVar:GetBool() then return nil end
	local player = LocalPlayer()
	if not (IsValid(player) and EngineDebug.Allowed(player)) then return nil end
	local vehicle = player:GetVehicle()
	if not (IsValid(vehicle) and AudioEngine.GetCarConfig(vehicle)) then return nil end
	return vehicle
end

local function rowName(entry)
	local block = entry.label ~= "" and entry.label ~= entry.root and (entry.label .. " · ") or ""
	return block .. entry.key .. (entry.occurrence > 1 and (" #" .. entry.occurrence) or "")
end

local function position(rowCount)
	local height = HEADER_HEIGHT + rowCount * ROW_HEIGHT + FOOTER_HEIGHT + 6
	return ScrW() - WIDTH - 24, math.max(20, math.floor(ScrH() * 0.22)), WIDTH, height
end

-- a step for - / +: about 3% of the file's value, rounded to 1, 2 or 5 x a power of ten
local function stepFor(data, index)
	local reference = math.abs(tonumber(EngineDebug.FileValue(data, index)) or 0)
	if reference == 0 then reference = math.abs(tonumber(data.values[index]) or 0) end
	if reference == 0 then return 1 end
	local raw = reference * 0.03
	local power = 10 ^ math.floor(math.log10(raw))
	local mantissa = raw / power
	local nice = mantissa < 1.5 and 1 or mantissa < 3.5 and 2 or mantissa < 7.5 and 5 or 10
	return nice * power
end

local function scheduleApply(vehicle)
	timer.Create("audio_dbg_overlay_apply", APPLY_DELAY, 1, function()
		if IsValid(vehicle) then EngineDebug.ApplyScript(vehicle, true) end
	end)
end

---------------------------------------------------------------------------
-- the editable panel (inside the context menu)
---------------------------------------------------------------------------
local function smallButton(parent, text, onClick, tooltip)
	local buttonPanel = vgui.Create("DButton", parent)
	buttonPanel:SetText(text)
	buttonPanel:SetTextColor(COLORS.text)
	buttonPanel.Paint = function(self, width, height)
		draw.RoundedBox(3, 0, 0, width, height, self:IsHovered() and COLORS.line or COLORS.face)
	end
	buttonPanel.DoClick = onClick
	if tooltip then buttonPanel:SetTooltip(tooltip) end
	return buttonPanel
end

local function buildEditPanel(vehicle, data, indices)
	if IsValid(editPanel) then editPanel:Remove() end
	local x, y, width, height = position(#indices)
	editPanel = vgui.Create("DPanel", g_ContextMenu)
	editPanel:SetPos(x, y)
	editPanel:SetSize(width, height)
	editPanel:DockPadding(6, HEADER_HEIGHT, 6, FOOTER_HEIGHT)
	local carConfig = AudioEngine.GetCarConfig(vehicle)
	editPanel.Paint = function(self, panelWidth, panelHeight)
		draw.RoundedBox(6, 0, 0, panelWidth, panelHeight, COLORS.background)
		draw.SimpleText("HANDLING · " .. (carConfig and carConfig.name or "?"), "DermaDefaultBold", 8, 5, COLORS.amber)
		draw.SimpleText("scroll / - + to step (Shift: finer) · applied live", "DermaDefault", 8, panelHeight - 16, COLORS.muted)
	end
	local headerButtons = {
		{ "Hide", function() RunConsoleCommand("audio_engine_debug_overlay", "0") end, "Hide the overlay (the menu's \"C overlay in the car\" box brings it back)" },
		{ "Menu", function() EngineDebug.OpenMenu(vehicle) end, "Open the debug menu on this car" },
		{ "Save version", function()
			local current = EngineDebug.ScriptData(vehicle)
			if not current then return end
			local version, added = EngineDebug.AddVersion(current, "overlay")
			chat.AddText(COLORS.amber, "[Audio Engine debug] ", COLORS.text, added and ("Saved as v" .. version.number .. " in the history.") or ("Same values as v" .. version.number .. ": no new version."))
		end, "Add the current values to the save history (the menu's Handling script page)" },
	}
	local buttonX = width - 6
	for _, headerButton in ipairs(headerButtons) do
		local buttonPanel = smallButton(editPanel, headerButton[1], headerButton[2], headerButton[3])
		surface.SetFont("DermaDefault")
		local buttonWidth = surface.GetTextSize(headerButton[1]) + 12
		buttonX = buttonX - buttonWidth
		buttonPanel:SetPos(buttonX, 3)
		buttonPanel:SetSize(buttonWidth, 18)
		buttonX = buttonX - 4
	end

	editPanel.entries = {}
	for _, index in ipairs(indices) do
		local entry = data.entries[index]
		local row = vgui.Create("DPanel", editPanel)
		row:Dock(TOP)
		row:SetTall(ROW_HEIGHT)
		row.Paint = nil
		local nameLabel = vgui.Create("DLabel", row)
		nameLabel:SetText(rowName(entry))
		nameLabel:SetTextColor(EngineDebug.IsPinned(data.ids[index]) and COLORS.amber or COLORS.text)
		nameLabel:Dock(FILL)
		nameLabel:MoveToFront()   -- (docked FILL: laid out after the buttons on the right)
		nameLabel:SetTooltip(entry.label .. "." .. entry.key .. "  (file: " .. tostring(EngineDebug.FileValue(data, index)) .. ")"
			.. (data.live[index] and "" or "  · needs a respawn to take effect"))
		local removeButton = smallButton(row, "x", function()
			local current = EngineDebug.ScriptData(vehicle)
			if not current then return end
			if stickyRows.indices then stickyRows.indices[index] = nil end
			EngineDebug.RemoveFromOverlay(current, index)
		end, "Take it off the overlay (unpin; a changed value comes back once it changes again)")
		removeButton:Dock(RIGHT)
		removeButton:SetWide(18)
		removeButton:DockMargin(4, 2, 0, 2)

		local valueEntry = vgui.Create("DTextEntry")
		local isNumber = tonumber(data.values[index]) ~= nil
		local function setValue(value)
			local current = EngineDebug.ScriptData(vehicle)
			if not (current and KeyValues.ValidValue(value)) then return end
			current.values[index] = value
			scheduleApply(vehicle)
		end
		local function step(direction)
			local current = EngineDebug.ScriptData(vehicle)
			if not current then return end
			local number = tonumber(current.values[index])
			if not number then return end
			local stepSize = stepFor(current, index) * (input.IsShiftDown() and 0.1 or 1)
			local newValue = KeyValues.Num(math.Round((number + direction * stepSize) / stepSize) * stepSize)
			valueEntry:SetText(newValue)
			setValue(newValue)
		end
		if isNumber then
			local plusButton = smallButton(row, "+", function() step(1) end)
			plusButton:Dock(RIGHT)
			plusButton:SetWide(18)
			plusButton:DockMargin(2, 2, 0, 2)
		end
		valueEntry:SetParent(row)
		valueEntry:Dock(RIGHT)
		valueEntry:SetWide(92)
		valueEntry:DockMargin(2, 1, 0, 1)
		valueEntry:SetText(data.values[index])
		if isNumber then
			local minusButton = smallButton(row, "-", function() step(-1) end)
			minusButton:Dock(RIGHT)
			minusButton:SetWide(18)
			minusButton:DockMargin(4, 2, 0, 2)
		end
		valueEntry.Paint = function(self, entryWidth, entryHeight)
			local current = EngineDebug.ScriptData(vehicle)
			local value = self:GetValue()
			local background = not KeyValues.ValidValue(value) and COLORS.bad
				or (current and value ~= EngineDebug.FileValue(current, index)) and COLORS.changed or COLORS.face
			draw.RoundedBox(3, 0, 0, entryWidth, entryHeight, background)
			self:DrawTextEntryText(COLORS.text, COLORS.amber, COLORS.text)
		end
		valueEntry.OnChange = function(self) setValue(self:GetValue()) end
		valueEntry.OnEnter = function(self)
			setValue(self:GetValue())
			timer.Remove("audio_dbg_overlay_apply")
			EngineDebug.ApplyScript(vehicle, true)
		end
		valueEntry.OnMouseWheeled = function(self, delta)
			if not isNumber then return false end
			step(delta > 0 and 1 or -1)
			return true
		end
		editPanel.entries[index] = valueEntry
	end
end

-- the values shown in the edit panel follow the car's (after an apply), except the one being typed in
local function refreshEditValues(data)
	if not (IsValid(editPanel) and editPanel.entries) then return end
	for index, valueEntry in pairs(editPanel.entries) do
		if IsValid(valueEntry) and not valueEntry:IsEditing() and data.values[index] and valueEntry:GetValue() ~= data.values[index] then
			valueEntry:SetText(data.values[index])
		end
	end
end

---------------------------------------------------------------------------
-- keeping it in step
---------------------------------------------------------------------------
local shownCar, shownData, shownIndices = nil, nil, {}

local function update()
	local vehicle = overlayCar()
	local data = vehicle and EngineDebug.ScriptData(vehicle)
	if vehicle and not data then
		-- ask for the car's script once on getting in (again after 10 s if no answer)
		local requestedAt = EngineDebug.ScriptRequestedAt(vehicle)
		if not requestedAt or RealTime() - requestedAt > 10 then EngineDebug.RequestScript(vehicle) end
	end
	local indices = data and EngineDebug.OverlayIndices(data) or {}
	if stickyRows.vehicle ~= vehicle or stickyRows.data ~= nil and data and #data.entries ~= stickyRows.entryCount then
		stickyRows.vehicle, stickyRows.indices = vehicle, {}
	end
	stickyRows.data, stickyRows.entryCount = data, data and #data.entries or 0
	if data then
		for _, index in ipairs(indices) do stickyRows.indices[index] = true end
		indices = {}
		for index in pairs(stickyRows.indices) do indices[#indices + 1] = index end
		table.sort(indices)
	end
	shownCar, shownData, shownIndices = vehicle, data, indices
	local key = (#indices > 0 and IsValid(vehicle)) and (vehicle:EntIndex() .. ":" .. table.concat(indices, ",")) or nil
	if not key or not IsValid(g_ContextMenu) then
		if IsValid(editPanel) then editPanel:Remove() end
		editPanelKey = nil
		return
	end
	-- (not rebuilt while you type in it)
	local typing = IsValid(editPanel) and vgui.GetKeyboardFocus() and vgui.GetKeyboardFocus():HasParent(editPanel)
	if (key ~= editPanelKey or not IsValid(editPanel)) and not typing then
		buildEditPanel(vehicle, data, indices)
		editPanelKey = key
	else
		refreshEditValues(data)
	end
end

timer.Create("audio_engine_debug_overlay", 0.2, 0, update)
EngineDebug.OnScript("overlay", function(vehicle)
	if vehicle == shownCar or vehicle == (IsValid(LocalPlayer()) and LocalPlayer():GetVehicle()) then update() end
end)

---------------------------------------------------------------------------
-- the read-only copy on the HUD (the context menu closed)
---------------------------------------------------------------------------
hook.Add("HUDPaint", "audio_engine_debug_overlay", function()
	if not (IsValid(shownCar) and shownData and #shownIndices > 0) then return end
	if IsValid(g_ContextMenu) and g_ContextMenu:IsVisible() and IsValid(editPanel) then return end
	local x, y, width, height = position(#shownIndices)
	draw.RoundedBox(6, x, y, width, height, COLORS.background)
	local carConfig = AudioEngine.GetCarConfig(shownCar)
	draw.SimpleText("HANDLING · " .. (carConfig and carConfig.name or "?"), "DermaDefaultBold", x + 8, y + 5, COLORS.amber)
	for row, index in ipairs(shownIndices) do
		local entry = shownData.entries[index]
		if entry then
			local rowY = y + HEADER_HEIGHT + (row - 1) * ROW_HEIGHT + ROW_HEIGHT / 2
			local value = shownData.values[index] or ""
			local changed = value ~= EngineDebug.FileValue(shownData, index)
			local pending = value ~= shownData.applied[index]
			draw.SimpleText(rowName(entry), "DermaDefault", x + 8, rowY, EngineDebug.IsPinned(shownData.ids[index]) and COLORS.amber or COLORS.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			draw.SimpleText(value .. (pending and " *" or ""), "DermaDefaultBold", x + width - 8, rowY, changed and COLORS.amber or COLORS.text, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		end
	end
	local hint = IsValid(g_ContextMenu) and "hold C to edit" or "editing needs the context menu (C, sandbox)"
	draw.SimpleText(hint, "DermaDefault", x + 8, y + height - 16, COLORS.muted)
end)
