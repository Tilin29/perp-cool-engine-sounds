--[[
	Audio Engine spawn menu: every "(Audio Engine)" vehicle spawn entry (sh_perp.lua's PERP cars and job
	vehicles) grouped by brand, top speed or engine family. A tab in the sandbox spawn menu (Q) and a window,
	`audio_engine_spawnmenu`. Stand-alone: nothing else refers to this file, delete it to drop the menu.
	Top speeds are the base scripts' MaxSpeed, asked from the server (PERP's scripts may only be mounted there).
]]

AddCSLuaFile()

local TOP_SPEEDS_NET = "audio_engine/spawnmenu/top-speeds"
local ENTRY_CATEGORY_TAG = "(Audio Engine)"
local JOB_CATEGORY_TAG = "job vehicles"
local KMH_PER_MPH = 1.609344

local function isEngineEntry(entry)
	return isstring(entry.Category) and string.find(entry.Category, ENTRY_CATEGORY_TAG, 1, true) ~= nil
end

if SERVER then
	util.AddNetworkString(TOP_SPEEDS_NET)

	local REQUEST_COOLDOWN = 2
	local MAX_SPEED_PATTERN = "[%s\"{]maxspeed[\"%s]+\"?([%d%.]+)"
	local lastRequest = {}

	local function scriptTopSpeedMph(script)
		local engine = AUDIO_ENGINE
		if engine and engine.ScriptTopSpeed then
			local kmh = engine.ScriptTopSpeed(script)

			return kmh and kmh / KMH_PER_MPH or 0
		end
		local scriptText = file.Read(script, "GAME")
		if not scriptText then return 0 end
		scriptText = string.lower(scriptText):gsub("//[^\n]*", "")

		return tonumber(string.match(scriptText, MAX_SPEED_PATTERN)) or 0
	end

	net.Receive(TOP_SPEEDS_NET, function(_, requester)
		local now = RealTime()
		if (lastRequest[requester] or -math.huge) + REQUEST_COOLDOWN > now then return end
		lastRequest[requester] = now
		local scripts, seen = {}, {}
		for _, entry in pairs(list.Get("Vehicles")) do
			local script = entry.AudioPerpScript
			if isEngineEntry(entry) and isstring(script) and not seen[script] then
				seen[script] = true
				scripts[#scripts + 1] = script
			end
		end
		net.Start(TOP_SPEEDS_NET)
		net.WriteUInt(#scripts, 12)
		for _, script in ipairs(scripts) do
			net.WriteString(script)
			net.WriteFloat(scriptTopSpeedMph(script))
		end
		net.Send(requester)
	end)

	hook.Add("PlayerDisconnected", "audio_engine/spawnmenu/forget-requests", function(leaving)
		lastRequest[leaving] = nil
	end)

	return
end

local groupConvar = CreateClientConVar("audio_engine_spawnmenu_group", "brand", true, false,
	"Audio Engine spawn menu grouping: brand, speed or family")

local GROUPINGS = {
	{id = "brand", label = "Brand"},
	{id = "speed", label = "Top speed"},
	{id = "family", label = "Engine family"},
}
local SPEED_BANDS = {
	{from = 0, to = 30, label = "0-30 mph"},
	{from = 30, to = 60, label = "30-60 mph"},
	{from = 60, to = 80, label = "60-80 mph"},
	{from = 80, to = 100, label = "80-100 mph"},
	{from = 100, to = 110, label = "100-110 mph"},
	{from = 110, to = math.huge, label = "110+ mph"},
}
local TWO_WORD_BRANDS = {
	["Alfa Romeo"] = true,
	["Aston Martin"] = true,
	["Land Rover"] = true,
}
local SERVICE_BRAND = "Work & emergency"
local SERVICE_VEHICLES = {
	["Ambulance"] = true,
	["Courier Truck"] = true,
	["Fire Truck"] = true,
	["SWAT Stockade"] = true,
}
local UNKNOWN_SPEED_LABEL = "Top speed unknown"
local LAST_GROUP_ORDER = 1000
local TILE_SHARE = 0.085 -- of the screen height
local LABEL_HEIGHT_SHARE = 0.22 -- of a tile
local TILE_SPACING = 4
local WINDOW_SHARE = 0.8 -- of the screen

local topSpeeds = {}
local speedsRequested = false
local openBrowsers = {}
setmetatable(openBrowsers, {__mode = "k"})

local function brandOf(carName)
	if SERVICE_VEHICLES[carName] then return SERVICE_BRAND end
	local firstTwoWords = string.match(carName, "^(%S+ %S+)")
	if firstTwoWords and TWO_WORD_BRANDS[firstTwoWords] then return firstTwoWords end

	return string.match(carName, "^(%S+)") or carName
end

local function speedBandOf(mph)
	if not mph or mph <= 0 then return nil end
	for index, band in ipairs(SPEED_BANDS) do
		if mph >= band.from and mph < band.to then return index, band end
	end
end

local function familyOf(presetId)
	local engine = AUDIO_ENGINE
	local preset = engine.EnginePreset and engine.EnginePreset(presetId)

	return preset and preset.name or tostring(presetId)
end

local function collectCars()
	local engine = AUDIO_ENGINE
	if not (engine and engine.Cars) then return {} end
	local cars = {}
	for entryId, entry in pairs(list.Get("Vehicles")) do
		local carConfig = isEngineEntry(entry) and isstring(entry.Model) and engine.Cars[string.lower(entry.Model)]
		if carConfig then
			cars[#cars + 1] = {
				entryId = entryId,
				name = entry.Name or carConfig.name,
				model = entry.Model,
				skin = entry.AudioSkin or 0,
				carName = carConfig.name,
				presetId = carConfig.preset,
				script = entry.AudioPerpScript,
				job = string.find(entry.Category, JOB_CATEGORY_TAG, 1, true) ~= nil,
			}
		end
	end

	return cars
end

local function groupOf(car, grouping)
	if grouping == "speed" then
		local index, band = speedBandOf(topSpeeds[car.script])
		if not index then return UNKNOWN_SPEED_LABEL, LAST_GROUP_ORDER end

		return band.label, index
	end
	if grouping == "family" then return familyOf(car.presetId), 0 end
	local brand = brandOf(car.carName)

	return brand, brand == SERVICE_BRAND and LAST_GROUP_ORDER or 0
end

local function matchesSearch(car, search)
	if search == "" then return true end
	local haystack = string.lower(car.name .. " " .. car.carName .. " " .. familyOf(car.presetId))

	return string.find(haystack, search, 1, true) ~= nil
end

local function buildGroups(grouping, search)
	local groupsByLabel, groups = {}, {}
	for _, car in ipairs(collectCars()) do
		if matchesSearch(car, search) then
			local label, order = groupOf(car, grouping)
			local group = groupsByLabel[label]
			if not group then
				group = {label = label, order = order, cars = {}}
				groupsByLabel[label] = group
				groups[#groups + 1] = group
			end
			group.cars[#group.cars + 1] = car
		end
	end
	table.sort(groups, function(first, second)
		if first.order ~= second.order then return first.order < second.order end

		return first.label < second.label
	end)
	local function bySpeedThenName(first, second)
		local firstSpeed, secondSpeed = topSpeeds[first.script] or 0, topSpeeds[second.script] or 0
		if grouping == "speed" and firstSpeed ~= secondSpeed then return firstSpeed < secondSpeed end

		return first.name < second.name
	end
	for _, group in ipairs(groups) do table.sort(group.cars, bySpeedThenName) end

	return groups
end

local function tooltipOf(car)
	local lines = {car.name}
	if car.job then lines[#lines + 1] = "Job vehicle (" .. car.carName .. ")" end
	lines[#lines + 1] = "Engine: " .. familyOf(car.presetId)
	local mph = topSpeeds[car.script]
	if mph and mph > 0 then
		lines[#lines + 1] = string.format("Top speed: %d mph (%d km/h)", math.Round(mph), math.Round(mph * KMH_PER_MPH))
	end
	lines[#lines + 1] = tostring(car.script)

	return table.concat(lines, "\n")
end

local function spawnCar(car)
	RunConsoleCommand("gm_spawnvehicle", car.entryId)
	surface.PlaySound("ui/buttonclickrelease.wav")
end

local function addTile(layout, car)
	local tileSize = math.Round(ScrH() * TILE_SHARE)
	local labelHeight = math.Round(tileSize * LABEL_HEIGHT_SHARE)
	local tile = layout:Add("DPanel")
	tile:SetSize(tileSize, tileSize + labelHeight)
	tile:SetPaintBackground(false)
	local icon = tile:Add("SpawnIcon")
	icon:SetSize(tileSize, tileSize)
	icon:Dock(TOP)
	icon:SetModel(car.model, car.skin)
	icon:SetTooltip(tooltipOf(car))
	icon.DoClick = function() spawnCar(car) end
	icon.OpenMenu = function()
		local menu = DermaMenu()
		menu:AddOption("Spawn", function() spawnCar(car) end):SetIcon("icon16/car.png")
		menu:AddOption("Copy spawn command", function()
			SetClipboardText("gm_spawnvehicle " .. car.entryId)
		end):SetIcon("icon16/page_copy.png")
		menu:Open()
	end
	local label = tile:Add("DLabel")
	label:Dock(FILL)
	label:SetText(car.name)
	label:SetContentAlignment(8)
	label:SetDark(true)
	label:SetWrap(true)
end

local function fillBrowser(browser)
	local scroll = browser.scroll
	scroll:Clear()
	local groups = buildGroups(groupConvar:GetString(), string.lower(string.Trim(browser.search:GetValue())))
	for _, group in ipairs(groups) do
		local category = scroll:Add("DCollapsibleCategory")
		category:Dock(TOP)
		category:DockMargin(0, 0, 0, TILE_SPACING)
		category:SetLabel(string.format("%s (%d)", group.label, #group.cars))
		local layout = vgui.Create("DIconLayout")
		layout:SetSpaceX(TILE_SPACING)
		layout:SetSpaceY(TILE_SPACING)
		layout:DockPadding(TILE_SPACING, TILE_SPACING, TILE_SPACING, TILE_SPACING)
		category:SetContents(layout)
		for _, car in ipairs(group.cars) do addTile(layout, car) end
	end
	if #groups == 0 then
		local empty = scroll:Add("DLabel")
		empty:Dock(TOP)
		empty:SetDark(true)
		empty:SetText("No Audio Engine cars match.")
	end
end

local function refreshBrowsers()
	for browser in pairs(openBrowsers) do
		if IsValid(browser) then fillBrowser(browser) end
	end
end

local function requestTopSpeeds()
	if speedsRequested then return end
	speedsRequested = true
	net.Start(TOP_SPEEDS_NET)
	net.SendToServer()
end

net.Receive(TOP_SPEEDS_NET, function()
	local count = net.ReadUInt(12)
	for _ = 1, count do
		local script = net.ReadString()
		local mph = net.ReadFloat()
		topSpeeds[script] = mph > 0 and mph or nil
	end
	refreshBrowsers()
end)

local function createBrowser(parent)
	local browser = vgui.Create("DPanel", parent)
	browser:SetPaintBackground(false)
	local bar = browser:Add("DPanel")
	bar:Dock(TOP)
	bar:DockMargin(0, 0, 0, TILE_SPACING)
	bar:SetPaintBackground(false)
	local groupLabel = bar:Add("DLabel")
	groupLabel:Dock(LEFT)
	groupLabel:SetDark(true)
	groupLabel:SetText("Group by")
	groupLabel:SizeToContentsX(TILE_SPACING * 2)
	local groupChoice = bar:Add("DComboBox")
	groupChoice:Dock(LEFT)
	groupChoice:SetWide(math.Round(ScrH() * 0.15))
	groupChoice:SetSortItems(false)
	for _, grouping in ipairs(GROUPINGS) do
		groupChoice:AddChoice(grouping.label, grouping.id, grouping.id == groupConvar:GetString())
	end
	groupChoice.OnSelect = function(_, _, _, groupingId)
		RunConsoleCommand("audio_engine_spawnmenu_group", groupingId)
		timer.Simple(0, refreshBrowsers) -- the convar changes next frame
	end
	browser.search = bar:Add("DTextEntry")
	browser.search:Dock(FILL)
	browser.search:DockMargin(TILE_SPACING * 2, 0, 0, 0)
	browser.search:SetPlaceholderText("Search cars...")
	browser.search:SetUpdateOnType(true)
	browser.search.OnValueChange = function() fillBrowser(browser) end
	browser.scroll = browser:Add("DScrollPanel")
	browser.scroll:Dock(FILL)
	openBrowsers[browser] = true
	requestTopSpeeds()
	fillBrowser(browser)

	return browser
end

concommand.Add("audio_engine_spawnmenu", function()
	local frame = vgui.Create("DFrame")
	frame:SetSize(math.Round(ScrW() * WINDOW_SHARE), math.Round(ScrH() * WINDOW_SHARE))
	frame:SetTitle("Audio Engine cars")
	frame:SetSizable(true)
	frame:Center()
	frame:MakePopup()
	local background = frame:Add("DPanel")
	background:Dock(FILL)
	createBrowser(background):Dock(FILL)
end, nil, "Audio Engine cars grouped by brand, top speed or engine family")

if spawnmenu and spawnmenu.AddCreationTab then
	spawnmenu.AddCreationTab("Audio Engine cars", function()
		local background = vgui.Create("DPanel")
		createBrowser(background):Dock(FILL)

		return background
	end, "icon16/car.png", 60)
end

hook.Add("audio_engine/settings", "audio_engine/spawnmenu/list-settings", function(groups)
	groups[#groups + 1] = {title = "Spawn menu", player = {"audio_engine_spawnmenu_group"}}
end)
