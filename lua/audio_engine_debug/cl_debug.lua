--[[
	Audio Engine debug module - the debug menu (client). Not part of the final addon (see sh_debug.lua).

	audio_engine_debug_menu (or !enginedebug, or right-click a car in the context menu), on the car
	you sit in or look at. Superadmins, while audio_engine_debug is 1 (the default). Pages:

	  Handling script  the car's vehicle script: edit its values, apply them to the car live, copy
	                   the txt (or save it to data/audio_engine_debug/scripts/) for PERP's script pack.
	                   Blocks fold (Vehicle_Sounds and what doesn't change the handling start folded);
	                   every Apply / Save adds a numbered version to the history on the right (hover:
	                   what it changed, click: load it); handling can be copied from another car's
	                   script; pinned values (the dot) show on the C overlay (cl_handling_overlay.lua)
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

---------------------------------------------------------------------------
-- the cars' vehicle scripts (from the server), kept per car: the menu works on one car, the C
-- overlay (cl_handling_overlay.lua) on the one you drive
---------------------------------------------------------------------------
local scriptDataByCar = setmetatable({}, { __mode = "k" })
local scriptListeners = {}   -- name -> function(vehicle), told when a car's script arrives or changes
local scriptRequestedAt = setmetatable({}, { __mode = "k" })

function EngineDebug.ScriptData(vehicle) return IsValid(vehicle) and scriptDataByCar[vehicle] or nil end
function EngineDebug.OnScript(name, listener) scriptListeners[name] = listener end

local function notifyScript(vehicle)
	for _, listener in pairs(scriptListeners) do listener(vehicle) end
end

local function requestScript(vehicle)
	vehicle = vehicle or targetCar
	if not IsValid(vehicle) then return end
	scriptRequestedAt[vehicle] = RealTime()
	net.Start("audio_dbg_script_req")
	net.WriteEntity(vehicle)
	net.SendToServer()
end
EngineDebug.RequestScript = requestScript
-- when the last request for this car went out (the overlay asks once on getting in)
function EngineDebug.ScriptRequestedAt(vehicle) return scriptRequestedAt[vehicle] end

local function scriptText(data)
	return KeyValues.Rebuild(data.fileText, data.fileEntries, data.values)
end
EngineDebug.ScriptText = scriptText

-- the edited values onto the car (quiet: no chat line for a plain success, for the overlay's steady edits)
local quietResultsUntil = 0
function EngineDebug.ApplyScript(vehicle, quiet)
	local data = EngineDebug.ScriptData(vehicle)
	if not data then return end
	data.sentValues = table.Copy(data.values)
	if quiet then quietResultsUntil = RealTime() + 3 end
	local compressed = util.Compress(scriptText(data)) or ""
	net.Start("audio_dbg_script_apply")
	net.WriteEntity(vehicle)
	net.WriteUInt(#compressed, 16)
	net.WriteData(compressed, #compressed)
	net.SendToServer()
end

net.Receive("audio_dbg_result", function()
	local succeeded, message = net.ReadBool(), net.ReadString()
	if succeeded and RealTime() < quietResultsUntil and not message:find("respawn", 1, true) then
		if IsValid(status) then status:SetText(message) status:SetTextColor(COLORS.green) end
		return
	end
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
	if not (current and IsValid(vehicle)) then return end
	local entries = KeyValues.Parse(current)
	local values, ids, indexById = {}, {}, {}
	for _, entry in ipairs(entries) do
		values[entry.index] = entry.value
		ids[entry.index] = KeyValues.EntryId(entry)
		indexById[ids[entry.index]] = entry.index
	end
	local data = {
		vehicle = vehicle, path = path, fallback = fallback, fileText = fileText, fileEntries = KeyValues.Parse(fileText),
		applied = values, values = table.Copy(values), entries = entries, live = live, ids = ids, indexById = indexById,
	}
	-- the answer to an apply: edits made since it was sent are still waiting, keep them
	local previous = scriptDataByCar[vehicle]
	if previous and previous.sentValues and previous.path == path and #previous.entries == #entries then
		for index, value in pairs(previous.values) do
			if value ~= previous.sentValues[index] then data.values[index] = value end
		end
	end
	scriptDataByCar[vehicle] = data
	notifyScript(vehicle)
end)

-- the file's value of entry index
local function fileValue(data, index)
	local fileEntry = data.fileEntries[index]
	return fileEntry and fileEntry.value
end
EngineDebug.FileValue = fileValue

---------------------------------------------------------------------------
-- settings kept in data/ on this client: pinned parameters (the C overlay) and save history
---------------------------------------------------------------------------
local DATA_FOLDER = "audio_engine_debug/"
local OVERLAY_FILE = DATA_FOLDER .. "overlay.json"

local function readJson(path)
	local text = file.Read(path, "DATA")
	return text and util.JSONToTable(text) or nil
end
local function writeJson(path, value)
	file.CreateDir(string.GetPathFromFilename(path))
	file.Write(path, util.TableToJSON(value, true))
end

--[[
	The overlay's picks: pinned = { [entry id] = true } (any car whose script has it), dismissed =
	{ [script path] = { [entry id] = value } }: a changed value taken off the overlay, until it
	changes again
]]
local overlayPicks = readJson(OVERLAY_FILE) or {}
overlayPicks.pinned = overlayPicks.pinned or {}
overlayPicks.dismissed = overlayPicks.dismissed or {}
local function saveOverlayPicks() writeJson(OVERLAY_FILE, overlayPicks) end

function EngineDebug.IsPinned(id) return overlayPicks.pinned[id] == true end
function EngineDebug.SetPinned(id, pinned)
	overlayPicks.pinned[id] = pinned and true or nil
	saveOverlayPicks()
	for vehicle in pairs(scriptDataByCar) do if IsValid(vehicle) then notifyScript(vehicle) end end
end

-- changed from the file (what the car is on or what's waiting to go on)
local function isChanged(data, index)
	return data.values[index] ~= fileValue(data, index) or data.applied[index] ~= fileValue(data, index)
end
EngineDebug.IsChanged = isChanged

-- a row the overlay has shown stays on it while you sit in that car (stepping a changed value back to the
-- file's doesn't take it away), until it's taken off: { [vehicle] = { [entry index] = true } }
local overlayKept = setmetatable({}, { __mode = "k" })
function EngineDebug.ClearOverlayKept(vehicle) if vehicle then overlayKept[vehicle] = nil end end

-- pinned, or changed and not taken off
local function wantsOverlay(data, index)
	local id = data.ids[index]
	if overlayPicks.pinned[id] then return true end
	if not isChanged(data, index) then return false end
	local dismissed = overlayPicks.dismissed[data.path]
	return not (dismissed and dismissed[id] == data.values[index])
end

-- the overlay's rows for a car, in the script's order
function EngineDebug.OverlayIndices(data)
	local kept = overlayKept[data.vehicle]
	if not kept or kept.path ~= data.path then
		kept = { path = data.path, indices = {} }
		overlayKept[data.vehicle] = kept
	end
	local indices = {}
	for _, entry in ipairs(data.entries) do
		if wantsOverlay(data, entry.index) then kept.indices[entry.index] = true end
		if kept.indices[entry.index] then indices[#indices + 1] = entry.index end
	end
	return indices
end

function EngineDebug.IsOnOverlay(data, index)
	local kept = overlayKept[data.vehicle]
	return wantsOverlay(data, index) or (kept ~= nil and kept.path == data.path and kept.indices[index] == true)
end

-- take a row off the overlay: unpin it, and a changed value stays off until it changes again
function EngineDebug.RemoveFromOverlay(data, index)
	local id = data.ids[index]
	overlayPicks.pinned[id] = nil
	if isChanged(data, index) then
		overlayPicks.dismissed[data.path] = overlayPicks.dismissed[data.path] or {}
		overlayPicks.dismissed[data.path][id] = data.values[index]
	end
	local kept = overlayKept[data.vehicle]
	if kept then kept.indices[index] = nil end
	saveOverlayPicks()
	notifyScript(data.vehicle)
end

-- the menu's dot: on the overlay -> off it (pinned or changed alike), else pin it
function EngineDebug.ToggleOverlay(data, index)
	if EngineDebug.IsOnOverlay(data, index) then
		EngineDebug.RemoveFromOverlay(data, index)
	else
		EngineDebug.SetPinned(data.ids[index], true)
	end
end

--[[
	Save history: every Apply live and Save to data/ (and the overlay's Save version) adds a
	version per vehicle script, numbered in order, with the time and the values that differ from
	the file: data/audio_engine_debug/history/<script>.json
]]
local function historyPath(scriptPath)
	return DATA_FOLDER .. "history/" .. scriptPath:gsub("^scripts/vehicles/", ""):gsub("%.txt$", ""):gsub("[^%w_%-]", "_") .. ".json"
end

local historyCache = {}
function EngineDebug.History(scriptPath)
	if not historyCache[scriptPath] then
		local stored = readJson(historyPath(scriptPath))
		historyCache[scriptPath] = istable(stored) and istable(stored.versions) and stored or { versions = {} }
	end
	return historyCache[scriptPath]
end

-- the values of a version that differ from the file, by entry id
local function changedValues(data)
	local changed = {}
	for _, entry in ipairs(data.entries) do
		local value = data.values[entry.index]
		if value ~= fileValue(data, entry.index) then changed[data.ids[entry.index]] = value end
	end
	return changed
end

local function sameValues(first, second)
	for id, value in pairs(first) do if second[id] ~= value then return false end end
	for id in pairs(second) do if first[id] == nil then return false end end
	return true
end

-- add a version (kind: "applied", "saved", "overlay"); nothing new if it's the latest one again
function EngineDebug.AddVersion(data, kind)
	local history = EngineDebug.History(data.path)
	local values = changedValues(data)
	local latest = history.versions[#history.versions]
	if latest and sameValues(latest.values or {}, values) then return latest, false end
	local version = { number = (latest and latest.number or 0) + 1, time = os.time(), kind = kind, values = values }
	history.versions[#history.versions + 1] = version
	writeJson(historyPath(data.path), history)
	return version, true
end

-- a readable name for an entry id ("engine.horsepower", "axle 2 > suspension.springconstant")
local function entryName(data, id)
	local index = data.indexById[id]
	local entry = index and data.entries[index]
	if not entry then return id end
	return (entry.label ~= "" and entry.label .. "." or "") .. entry.key .. (entry.occurrence > 1 and (" #" .. entry.occurrence) or "")
end

-- what a version changed from the one before it (or from the file, for the first)
function EngineDebug.VersionChanges(data, versionPosition)
	local versions = EngineDebug.History(data.path).versions
	local version, before = versions[versionPosition], versions[versionPosition - 1]
	local beforeValues = before and before.values or {}
	local lines, ids = {}, {}
	for id in pairs(version.values or {}) do ids[id] = true end
	for id in pairs(beforeValues) do ids[id] = true end
	local ordered = {}
	for id in pairs(ids) do
		local oldValue = beforeValues[id]
		local newValue = version.values[id]
		local index = data.indexById[id]
		local fileText = index and fileValue(data, index) or "?"
		if (oldValue or fileText) ~= (newValue or fileText) then
			ordered[#ordered + 1] = { index = index or math.huge, text = string.format("%s:  %s  ->  %s", entryName(data, id), oldValue or fileText, newValue or fileText) }
		end
	end
	table.sort(ordered, function(first, second) return first.index < second.index end)
	for _, line in ipairs(ordered) do lines[#lines + 1] = line.text end
	return lines, before and before.number or nil
end

-- the editor's values set to a version's (not applied: the menu's Apply live does that)
function EngineDebug.LoadVersion(data, version)
	for _, entry in ipairs(data.entries) do
		local value = version.values and version.values[data.ids[entry.index]]
		data.values[entry.index] = value or fileValue(data, entry.index)
	end
	notifyScript(data.vehicle)
end

---------------------------------------------------------------------------
-- copying handling from another car's script
---------------------------------------------------------------------------
-- which part of the handling an entry is ("body", "engine", "steering", "axles", "radius"), nil = never copied
local function copyGroup(entry)
	if not KeyValues.IsHandling(entry) or entry.path == "" then return nil end
	local block = entry.path:match("^[^/]+")
	if block == "axle" then return (entry.path == "axle/wheel" and entry.lowerKey == "radius") and "radius" or "axles" end
	if block == "body" or block == "engine" or block == "steering" then return block end
	return nil
end

local COPY_GROUPS = {
	{ "body", "Body (mass, centre of mass, gravity)", true },
	{ "engine", "Engine (power, top speed, gears, boost)", true },
	{ "steering", "Steering", true },
	{ "axles", "Axles (wheels, tyre materials, suspension, torque and brake split)", true },
	{ "radius", "Wheel radius (belongs to the model: usually leave it)", false },
}
local copyChoice = {}
for _, group in ipairs(COPY_GROUPS) do copyChoice[group[1]] = group[3] end
local pendingCopy   -- { vehicle, name } of the request on its way

net.Receive("audio_dbg_copy", function()
	local vehicle = net.ReadEntity()
	local sourcePath, fallback = net.ReadString(), net.ReadBool()
	local dataLength = net.ReadUInt(16)
	local sourceText = util.Decompress(net.ReadData(dataLength)) or ""
	local data = EngineDebug.ScriptData(vehicle)
	if not data then return end
	local sourceValues = {}
	for _, entry in ipairs(KeyValues.Parse(sourceText)) do sourceValues[KeyValues.EntryId(entry)] = entry.value end
	local copied, changed, missing, notInSource = 0, 0, 0, {}
	for _, entry in ipairs(data.entries) do
		local group = copyGroup(entry)
		if group and copyChoice[group] then
			local value = sourceValues[data.ids[entry.index]]
			if value and KeyValues.ValidValue(value) then
				copied = copied + 1
				if data.values[entry.index] ~= value then changed = changed + 1 end
				data.values[entry.index] = value
			else
				missing = missing + 1
				if #notInSource < 4 then notInSource[#notInSource + 1] = entryName(data, data.ids[entry.index]) end
			end
		end
	end
	-- keys the source has that this script doesn't (a 6th gear): can't be added
	local extra = 0
	for id in pairs(sourceValues) do
		local root, path, key = id:match("^([^/]*)/([^|]*)|([^|]*)|")
		local fakeEntry = { root = root, path = path, lowerKey = key }
		local group = copyGroup(fakeEntry)
		if group and copyChoice[group] and not data.indexById[id] then extra = extra + 1 end
	end
	local sourceName = pendingCopy and pendingCopy.name or sourcePath
	pendingCopy = nil
	local message = string.format("Copied %d value%s from %s (%d different): not applied yet, press Apply live.", copied, copied == 1 and "" or "s", sourceName, changed)
	if fallback then message = message .. " (Its script isn't mounted here: PERP's physics values on the test script.)" end
	if missing > 0 then message = message .. string.format(" %d not in its script, kept (%s%s).", missing, table.concat(notInSource, ", "), missing > #notInSource and ", ..." or "") end
	if extra > 0 then message = message .. string.format(" It has %d key%s this script doesn't (e.g. more gears): not copied.", extra, extra == 1 and "" or "s") end
	report(true, message)
	notifyScript(vehicle)
end)

-- every car the copy dialog offers: cars in the world, then PERP's cars and job vehicles
local function copySources()
	local sources = {}
	for _, vehicle in ipairs(ents.FindByClass("prop_vehicle_jeep")) do
		local carConfig = AudioEngine.GetCarConfig(vehicle)
		if carConfig and vehicle ~= targetCar then
			local distance = math.floor(vehicle:GetPos():Distance(LocalPlayer():GetPos()) * 0.01905)
			sources[#sources + 1] = { name = string.format("%s (in the world, %d m)", carConfig.name or "?", distance), vehicle = vehicle, script = "", world = true, sort = distance }
		end
	end
	table.sort(sources, function(first, second) return first.sort < second.sort end)
	local fromList = {}
	for name, carModel in pairs(AudioEngine.CAR_MODELS or {}) do
		if istable(carModel) and isstring(carModel[2]) then fromList[#fromList + 1] = { name = name, script = carModel[2] } end
	end
	for _, jobVehicle in ipairs(AudioEngine.JOB_VEHICLES or {}) do
		if istable(jobVehicle) and isstring(jobVehicle[3]) then fromList[#fromList + 1] = { name = jobVehicle[1], script = jobVehicle[3] } end
	end
	table.sort(fromList, function(first, second) return first.name < second.name end)
	for _, source in ipairs(fromList) do sources[#sources + 1] = source end
	return sources
end

local COPY_TIERS = { { "", "base script" }, { "used/", "used" }, { "upgrade_1/", "upgrade 1" }, { "upgrade_2/", "upgrade 2" }, { "spiked/", "spiked" } }

local function openCopyDialog()
	local data = EngineDebug.ScriptData(targetCar)
	if not data then report(false, "The car's script hasn't loaded yet.") return end
	local dialog = vgui.Create("DFrame")
	dialog:SetSize(620, 560)
	dialog:Center()
	dialog:SetTitle("")
	dialog:MakePopup()
	dialog:DockPadding(10, 30, 10, 10)
	dialog.Paint = function(self, width, height)
		draw.RoundedBox(8, 0, 0, width, height, COLORS.background)
		draw.SimpleText("COPY HANDLING FROM ANOTHER CAR", "DermaDefaultBold", 12, 8, COLORS.amber)
	end
	paragraph(dialog, "The chosen parts of its script go into this car's editor as unapplied changes (orange): look them over, then Apply live. "
		.. "Only keys both scripts have are copied; a gear the other car has and this one doesn't can't be added.", COLORS.muted)

	local filterRow = vgui.Create("DPanel", dialog)
	filterRow:Dock(TOP)
	filterRow:SetTall(22)
	filterRow.Paint = nil
	local filterLabel = label(filterRow, "Find:", COLORS.muted)
	filterLabel:Dock(LEFT)
	filterLabel:DockMargin(0, 0, 6, 0)
	local filter = vgui.Create("DTextEntry", filterRow)
	filter:Dock(LEFT)
	filter:SetWide(220)
	local tierLabel = label(filterRow, "Script tier:", COLORS.muted)
	tierLabel:Dock(LEFT)
	tierLabel:DockMargin(16, 0, 6, 0)
	local tierChoice = vgui.Create("DComboBox", filterRow)
	tierChoice:Dock(LEFT)
	tierChoice:SetWide(120)
	for i, tier in ipairs(COPY_TIERS) do tierChoice:AddChoice(tier[2], tier[1], i == 1) end

	local groupsPanel = vgui.Create("DPanel", dialog)
	groupsPanel:Dock(BOTTOM)
	groupsPanel:SetTall(#COPY_GROUPS * 22 + 40)
	groupsPanel.Paint = nil
	for _, group in ipairs(COPY_GROUPS) do
		check(groupsPanel, group[2], copyChoice[group[1]], function(checked) copyChoice[group[1]] = checked end)
	end
	local buttons = buttonRow(groupsPanel)

	local list = vgui.Create("DListView", dialog)
	list:Dock(FILL)
	list:DockMargin(0, 6, 0, 6)
	list:SetMultiSelect(false)
	list:AddColumn("Car")
	list:AddColumn("Script"):SetWidth(260)
	local sources = copySources()
	local function fill()
		list:Clear()
		local filterText = filter:GetValue():lower()
		for _, source in ipairs(sources) do
			if filterText == "" or source.name:lower():find(filterText, 1, true) or source.script:lower():find(filterText, 1, true) then
				local line = list:AddLine(source.name, source.world and "(the script it's on)" or source.script)
				line.source = source
			end
		end
	end
	filter.OnChange = fill
	fill()

	local function copySelected()
		local _, line = list:GetSelectedLine()
		if not (line and line.source) then report(false, "Pick a car in the list first.") return end
		if not IsValid(targetCar) then return end
		local source = line.source
		local _, tier = tierChoice:GetSelected()
		tier = tier or ""
		local sourcePath = source.script
		if not source.world and tier and tier ~= "" then
			sourcePath = sourcePath:gsub("^(scripts/vehicles/[^/]+/)", "%1" .. tier)
		end
		local tierName = tier:gsub("/$", "")
		pendingCopy = { name = source.world and source.name or (source.name .. (tier ~= "" and (" (" .. tierName .. ")") or "")) }
		net.Start("audio_dbg_copy_req")
		net.WriteEntity(targetCar)
		net.WriteString(sourcePath or "")
		net.WriteEntity(source.world and source.vehicle or NULL)
		net.SendToServer()
		dialog:Close()
	end
	list.DoDoubleClick = copySelected
	buttons:Add("Copy into the editor", copySelected, true)
	buttons:Add("Cancel", function() dialog:Close() end)
end

---------------------------------------------------------------------------
-- page: handling script
---------------------------------------------------------------------------
-- collapsible sections: { [section key] = expanded }, kept while the game runs
local sectionExpanded = {}
local SECTION_HEADER_HEIGHT, ROW_HEIGHT, SECTION_INDENT = 20, 22, 14

local function triangle(x, y, size, open, color)
	surface.SetDrawColor(color)
	draw.NoTexture()
	if open then
		surface.DrawPoly({ { x = x, y = y }, { x = x + size, y = y }, { x = x + size / 2, y = y + size * 0.8 } })
	else
		surface.DrawPoly({ { x = x, y = y }, { x = x + size * 0.8, y = y + size / 2 }, { x = x, y = y + size } })
	end
end

-- a section that folds: a header line and its items (rows or sections), laid out by hand
local function createSection(parent, title, expanded, onToggle, dim)
	local section = vgui.Create("DPanel", parent)
	section.Paint = nil
	section.items = {}
	section.expanded = expanded
	section.count = 0
	local header = vgui.Create("DButton", section)
	header:SetText("")
	header.Paint = function(self, width, height)
		if self:IsHovered() then draw.RoundedBox(3, 0, 0, width, height, COLORS.face) end
		triangle(4, height / 2 - 4, 8, section.expanded, COLORS.muted)
		draw.SimpleText(title, "DermaDefaultBold", 18, height / 2, dim and COLORS.muted or COLORS.amber, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		if not section.expanded then
			surface.SetFont("DermaDefaultBold")
			local titleWidth = surface.GetTextSize(title)
			draw.SimpleText(section.count .. " value" .. (section.count == 1 and "" or "s"), "DermaDefault", 30 + titleWidth, height / 2, COLORS.muted, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		end
	end
	header.DoClick = function()
		section.expanded = not section.expanded
		onToggle(section.expanded)
	end
	section.header = header
	function section:AddItem(panel)
		panel:SetParent(self)
		self.items[#self.items + 1] = panel
		return panel
	end
	function section:UpdateHeight()
		local height = SECTION_HEADER_HEIGHT
		for _, item in ipairs(self.items) do
			if item.UpdateHeight then item:UpdateHeight() end
			item:SetVisible(self.expanded)
			if self.expanded then height = height + item:GetTall() + 1 end
		end
		if self.expanded and #self.items > 0 then height = height + 4 end
		self:SetTall(height)
		self:InvalidateLayout()
	end
	function section:PerformLayout(width)
		self.header:SetPos(0, 0)
		self.header:SetSize(width, SECTION_HEADER_HEIGHT)
		local y = SECTION_HEADER_HEIGHT
		for _, item in ipairs(self.items) do
			if self.expanded then
				item:SetPos(SECTION_INDENT, y)
				item:SetWide(width - SECTION_INDENT)
				y = y + item:GetTall() + 1
			end
		end
	end
	return section
end

-- the sections an entry sits in, outermost first: { key, title, starts open, dim }
local function sectionChain(entry)
	local rootTitle = entry.root == "" and "vehicle" or entry.root
	rootTitle = rootTitle:sub(1, 1):upper() .. rootTitle:sub(2)
	local isSound = entry.root ~= "vehicle"
	local chain = { { key = entry.root, title = rootTitle, open = not isSound, dim = isSound } }
	if entry.label ~= "" and entry.label ~= entry.root then
		local key = entry.root
		for part in (entry.label .. " > "):gmatch("(.-) > ") do
			key = key .. ">" .. part
			chain[#chain + 1] = { key = key, title = part:sub(1, 1):upper() .. part:sub(2), open = not isSound, dim = isSound }
		end
	end
	-- in the vehicle block, what doesn't change the handling (the dust cloud) folds away on its own
	if not isSound and not KeyValues.IsHandling(entry) then
		local last = chain[#chain]
		chain[#chain + 1] = { key = last.key .. ">effects", title = "Effects (no handling change)", open = false, dim = true }
	end
	return chain
end

local function formatVersionTime(time)
	return os.date("%d %b %H:%M:%S", time)
end

local function buildScriptPage(pagePanel)
	local function data() return EngineDebug.ScriptData(targetCar) end

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
	filter:SetWide(180)
	local overlayCheck = vgui.Create("DCheckBoxLabel", filterRow)
	overlayCheck:Dock(LEFT)
	overlayCheck:DockMargin(12, 3, 0, 0)
	overlayCheck:SetText("C overlay in the car")
	overlayCheck:SetTextColor(COLORS.text)
	overlayCheck:SetWide(140)
	overlayCheck:SetConVar("audio_engine_debug_overlay")
	overlayCheck:SetTooltip("The pinned (star) and changed values on screen while you drive; hold C to edit them live")
	local countLabel = label(filterRow, "", COLORS.muted)
	countLabel:Dock(FILL)
	countLabel:DockMargin(12, 0, 0, 0)
	header:SetTall(150)

	-- the save history, on the right
	local historyPanel = vgui.Create("DPanel", pagePanel)
	historyPanel:Dock(RIGHT)
	historyPanel:SetWide(230)
	historyPanel:DockMargin(6, 4, 4, 8)
	historyPanel.Paint = function(self, width, height) draw.RoundedBox(4, 0, 0, width, height, COLORS.background) end
	historyPanel:DockPadding(6, 4, 6, 6)
	local historyTitle = label(historyPanel, "SAVE HISTORY", COLORS.amber, "DermaDefaultBold")
	historyTitle:Dock(TOP)
	local historyHint = paragraph(historyPanel, "Each Apply live / Save adds a version. Hover: what it changed. Click: load it into the editor.", COLORS.muted)
	historyHint:DockMargin(0, 2, 0, 4)
	local historyList = vgui.Create("DScrollPanel", historyPanel)
	historyList:Dock(FILL)

	local scrollPanel = scroll(pagePanel)

	local function refreshCount()
		local current = data()
		if not current then countLabel:SetText("") return end
		local fromFile, pending = 0, 0
		for _, entry in ipairs(current.fileEntries) do
			if current.values[entry.index] ~= entry.value then fromFile = fromFile + 1 end
			if current.values[entry.index] ~= current.applied[entry.index] then pending = pending + 1 end
		end
		countLabel:SetText(string.format("%d value%s changed from the file · %d not applied yet", fromFile, fromFile == 1 and "" or "s", pending))
		countLabel:SetTextColor(pending > 0 and COLORS.amber or COLORS.muted)
	end

	local function rebuildHistory()
		historyList:Clear()
		local current = data()
		if not current then return end
		local versions = EngineDebug.History(current.path).versions
		if #versions == 0 then
			local none = label(historyList, "No versions yet.", COLORS.muted)
			none:Dock(TOP)
			return
		end
		for position = #versions, 1, -1 do
			local version = versions[position]
			local versionButton = vgui.Create("DButton", historyList)
			versionButton:Dock(TOP)
			versionButton:DockMargin(0, 0, 0, 2)
			versionButton:SetTall(32)
			versionButton:SetText("")
			local changeCount = table.Count(version.values or {})
			versionButton.Paint = function(self, width, height)
				draw.RoundedBox(3, 0, 0, width, height, self:IsHovered() and COLORS.line or COLORS.face)
				draw.SimpleText("v" .. version.number, "DermaDefaultBold", 6, 3, COLORS.amber)
				draw.SimpleText(formatVersionTime(version.time or 0), "DermaDefault", 40, 3, COLORS.text)
				draw.SimpleText(string.format("%s · %d from the file", version.kind or "saved", changeCount), "DermaDefault", 6, 17, COLORS.muted)
			end
			local changes, beforeNumber = EngineDebug.VersionChanges(current, position)
			local tooltipLines = { beforeNumber and ("Changes from v" .. beforeNumber .. ":") or "Changes from the file:" }
			for i = 1, math.min(#changes, 30) do tooltipLines[#tooltipLines + 1] = changes[i] end
			if #changes == 0 then tooltipLines[#tooltipLines + 1] = "(none)" end
			if #changes > 30 then tooltipLines[#tooltipLines + 1] = string.format("... and %d more", #changes - 30) end
			versionButton:SetTooltip(table.concat(tooltipLines, "\n"))
			versionButton.DoClick = function()
				local latest = data()
				if not latest then return end
				EngineDebug.LoadVersion(latest, version)
				report(true, "Loaded v" .. version.number .. " into the editor: press Apply live to put it on the car.")
			end
		end
	end

	local sections = {}
	local topSections = {}
	local function relayout()
		for _, section in ipairs(topSections) do section:UpdateHeight() end
		scrollPanel:InvalidateLayout()
		scrollPanel:GetCanvas():InvalidateLayout()
	end

	local function makeRow(parentSection, current, entry)
		local row = parentSection:AddItem(vgui.Create("DPanel"))
		row:SetTall(ROW_HEIGHT)
		row.Paint = nil
		local id = current.ids[entry.index]
		local pinButton = vgui.Create("DButton", row)
		pinButton:Dock(LEFT)
		pinButton:SetWide(18)
		pinButton:DockMargin(0, 2, 4, 2)
		pinButton:SetText("")
		pinButton:SetTooltip("On the C overlay (the value on screen while driving, editable with C held): click to add or take off.\nChanged values go on by themselves.")
		pinButton.Paint = function(self, width, height)
			local latest = data()
			local shown = latest and EngineDebug.IsOnOverlay(latest, entry.index)
			local color = shown and (EngineDebug.IsPinned(id) and COLORS.amber or COLORS.amberDim) or (self:IsHovered() and COLORS.muted or COLORS.line)
			draw.RoundedBox(height / 2, 2, 1, width - 4, height - 2, color)
			if not shown then draw.RoundedBox(height / 2 - 2, 4, 3, width - 8, height - 6, COLORS.panel) end
		end
		pinButton.DoClick = function()
			local latest = data()
			if latest then EngineDebug.ToggleOverlay(latest, entry.index) end
		end
		local keyLabel = label(row, entry.key .. (entry.occurrence > 1 and ("  #" .. entry.occurrence) or ""), COLORS.text)
		keyLabel:Dock(LEFT)
		keyLabel:SetWide(210)
		local valueEntry = vgui.Create("DTextEntry", row)
		valueEntry:Dock(LEFT)
		valueEntry:SetWide(150)
		valueEntry:SetValue(current.values[entry.index])
		local originalValue = fileValue(current, entry.index)
		valueEntry:SetTooltip("File: " .. tostring(originalValue))
		valueEntry.Paint = function(self, width, height)
			local value = self:GetValue()
			local background = not KeyValues.ValidValue(value) and Color(90, 30, 30) or value ~= originalValue and Color(70, 52, 25) or COLORS.face
			draw.RoundedBox(3, 0, 0, width, height, background)
			self:DrawTextEntryText(COLORS.text, COLORS.amber, COLORS.text)
		end
		valueEntry.OnChange = function(self)
			local latest = data()
			local value = self:GetValue()
			if latest and KeyValues.ValidValue(value) then latest.values[entry.index] = value end
			refreshCount()
		end
		local isLive = current.live[entry.index]
		local liveLabel = label(row, isLive and "live" or (KeyValues.IsHandling(entry) and "respawn" or ""), isLive and COLORS.green or COLORS.muted)
		liveLabel:Dock(LEFT)
		liveLabel:SetWide(56)
		liveLabel:DockMargin(8, 0, 0, 0)
		if entry.comment then
			local commentLabel = label(row, "// " .. entry.comment, COLORS.muted)
			commentLabel:Dock(FILL)
		end
	end

	local function rebuild()
		scrollPanel:Clear()
		sections, topSections = {}, {}
		local current = data()
		if not current then return end
		local filterText = filter:GetValue():lower()
		local filtering = filterText ~= ""
		local sectionTotals = {}
		for _, entry in ipairs(current.entries) do
			local matches = not filtering or entry.lowerKey:find(filterText, 1, true) or entry.label:lower():find(filterText, 1, true)
			if matches then
				local parentSection
				for depth, link in ipairs(sectionChain(entry)) do
					local section = sections[link.key]
					if not section then
						if sectionExpanded[link.key] == nil then sectionExpanded[link.key] = link.open end
						local key = link.key
						section = createSection(nil, link.title, filtering or sectionExpanded[key], function(expanded)
							if not filtering then sectionExpanded[key] = expanded end
							relayout()
						end, link.dim)
						if depth == 1 then
							scrollPanel:AddItem(section)
							section:Dock(TOP)
							section:DockMargin(0, 4, 0, 2)
							topSections[#topSections + 1] = section
						else
							parentSection:AddItem(section)
						end
						sections[link.key] = section
					end
					section.count = section.count + 1
					parentSection = section
				end
				makeRow(parentSection, current, entry)
			end
		end
		relayout()
		refreshCount()
	end
	filter.OnChange = function() rebuild() end

	local function setAll(expanded)
		for key in pairs(sections) do sectionExpanded[key] = expanded end
		for _, section in pairs(sections) do section.expanded = expanded end
		relayout()
	end

	EngineDebug.OnScript("menu", function(vehicle)
		if vehicle ~= targetCar or not IsValid(infoLabel) then return end
		local current = data()
		if not current then return end
		local carConfig = IsValid(current.vehicle) and AudioEngine.GetCarConfig(current.vehicle)
		infoLabel:SetText(string.format("%s  ·  %s", carConfig and carConfig.name or "?", current.path))
		warningLabel:SetText(current.fallback and ("PERP's vehicle scripts aren't mounted here: this is test_car.txt carrying PERP's physics values for "
			.. current.path .. " (what the car drives on). Its sounds, materials and other fields are test_car's, not PERP's file.") or "")
		rebuild()
		rebuildHistory()
	end)

	buttons:Add("Apply live", function()
		local current = data()
		if not (current and IsValid(current.vehicle)) then return end
		local version, added = EngineDebug.AddVersion(current, "applied")
		EngineDebug.ApplyScript(current.vehicle)
		if not added then report(true, "Applying (same values as v" .. version.number .. ": no new version).") end
	end, true)
	buttons:Add("Copy txt", function()
		local current = data()
		if not current then return end
		SetClipboardText(scriptText(current))
		report(true, "Copied " .. current.path .. " to the clipboard.")
	end)
	buttons:Add("Save to data/", function()
		local current = data()
		if not current then return end
		local relativePath = "audio_engine_debug/scripts/" .. current.path:gsub("^scripts/vehicles/", "")
		file.CreateDir(string.GetPathFromFilename(relativePath))
		file.Write(relativePath, scriptText(current))
		local version, added = EngineDebug.AddVersion(current, "saved")
		rebuildHistory()
		report(true, "Saved to garrysmod/data/" .. relativePath .. (added and (" as v" .. version.number) or (" (same values as v" .. version.number .. ")")))
	end)
	buttons:Add("Copy handling from...", openCopyDialog)
	buttons:Add("Undo unapplied", function()
		local current = data()
		if not current then return end
		current.values = table.Copy(current.applied)
		notifyScript(current.vehicle)
	end)
	buttons:Add("Reset car to file", function()
		local current = data()
		if not (current and IsValid(current.vehicle)) then return end
		current.sentValues = nil
		net.Start("audio_dbg_script_apply")
		net.WriteEntity(current.vehicle)
		net.WriteUInt(0, 16)
		net.SendToServer()
	end)
	buttons:Add("Reload", function()
		local current = data()
		if current then current.sentValues = nil end
		requestScript()
	end)
	for _, choice in ipairs({ { "Expand all", true }, { "Collapse all", false } }) do
		local foldButton = button(filterRow, choice[1], function() setAll(choice[2]) end)
		foldButton:Dock(LEFT)
		foldButton:DockMargin(8, 0, 0, 0)
	end
	countLabel:MoveToFront()

	if data() then scriptListeners.menu(targetCar) else requestScript() end
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
			local gearEnds = AudioEngine.FitGearEnds(baseConfig.gearTopSpeed or baseConfig.topSpeed, gearCount, redline, baseConfig.powerKg, gearCount)
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
	paragraph(scrollPanel, "Off = the cars drive on their vehicle script alone, as on PERP without this addon: Source's own tyres, " ..
		"no handling model. PERP's physics still go onto cars that fell back to the test script, so they match the server.")
	local boxes = {}
	for _, cvarName in ipairs({ "audio_engine_drivemodel", "audio_engine_cruise" }) do
		local cvarEntry = EngineDebug.SERVER_CVAR_SET[cvarName]
		boxes[cvarName] = check(scrollPanel, cvarEntry[3] .. "   (" .. cvarName .. ")", true, function(checked) sendCvars({ { cvarName, checked and 1 or 0 } }) end)
	end
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
			local sourceFile = "sh_handling.lua"
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
	stateListeners = {}

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
