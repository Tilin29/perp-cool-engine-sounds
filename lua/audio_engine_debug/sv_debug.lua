--[[
	Audio Engine debug module (server): the debug menu's requests, superadmins only, while
	audio_engine_debug is 1. Not part of the final addon (see sh_debug.lua).
]]

local AudioEngine = AUDIO_ENGINE
local EngineDebug = AudioEngine.Debug
local KeyValues = AudioEngine.KV

for _, networkName in ipairs({ "audio_dbg_state_req", "audio_dbg_state", "audio_dbg_cvar", "audio_dbg_tune",
	"audio_dbg_script_req", "audio_dbg_script", "audio_dbg_script_apply", "audio_dbg_gear", "audio_dbg_rev",
	"audio_dbg_result" }) do
	util.AddNetworkString(networkName)
end

local function sendResult(requester, succeeded, message)
	net.Start("audio_dbg_result")
	net.WriteBool(succeeded)
	net.WriteString(message)
	net.Send(requester)
end

-- the car a request is about: one of ours, the player allowed
local function requestedCar(requester, vehicle)
	if not EngineDebug.Allowed(requester) then return nil end
	if not (IsValid(vehicle) and AudioEngine.TrackedVehicles and AudioEngine.TrackedVehicles[vehicle] and AudioEngine.GetCarConfig(vehicle)) then
		sendResult(requester, false, "Not a car with the procedural engine.")
		return nil
	end
	return vehicle
end

---------------------------------------------------------------------------
-- state: server convars and tuned tables
---------------------------------------------------------------------------
local function sendState(requester)
	net.Start("audio_dbg_state")
	net.WriteUInt(#EngineDebug.SERVER_CVARS, 8)
	for _, cvarEntry in ipairs(EngineDebug.SERVER_CVARS) do
		local conVar = GetConVar(cvarEntry[1])
		net.WriteString(cvarEntry[1])
		net.WriteString(conVar and conVar:GetString() or "")
	end
	net.WriteUInt(#EngineDebug.TUNABLES, 8)
	for _, tunable in ipairs(EngineDebug.TUNABLES) do
		local targetTable = AudioEngine[tunable[1]]
		net.WriteFloat(targetTable and tonumber(targetTable[tunable[2]]) or 0)
	end
	net.Send(requester)
end

-- the tables' values as the files have them, for "what changed"
EngineDebug.TUNABLE_FILE = EngineDebug.TUNABLE_FILE or {}
for _, tunable in ipairs(EngineDebug.TUNABLES) do
	local key = tunable[1] .. "." .. tunable[2]
	if EngineDebug.TUNABLE_FILE[key] == nil and AudioEngine[tunable[1]] then EngineDebug.TUNABLE_FILE[key] = AudioEngine[tunable[1]][tunable[2]] end
end

net.Receive("audio_dbg_state_req", function(_, requester)
	if EngineDebug.Allowed(requester) then sendState(requester) end
end)

net.Receive("audio_dbg_cvar", function(_, requester)
	if not EngineDebug.Allowed(requester) then return end
	local count = net.ReadUInt(4)
	for _ = 1, count do
		local name, value = net.ReadString(), net.ReadString()
		local cvarEntry = EngineDebug.SERVER_CVAR_SET[name]
		if cvarEntry then
			local newValue = tonumber(value) or 0
			if cvarEntry[2] == "bool" then newValue = newValue ~= 0 and 1 or 0 end
			if cvarEntry[4] then newValue = math.Clamp(newValue, cvarEntry[4], cvarEntry[5]) end
			RunConsoleCommand(name, tostring(newValue))
		end
	end
	-- (RunConsoleCommand takes effect on the next frame)
	timer.Simple(0.1, function() if IsValid(requester) then sendState(requester) end end)
end)

net.Receive("audio_dbg_tune", function(_, requester)
	if not EngineDebug.Allowed(requester) then return end
	local tunableIndex, newValue = net.ReadUInt(8), net.ReadFloat()
	local tunable = EngineDebug.TUNABLES[tunableIndex]
	local targetTable = tunable and AudioEngine[tunable[1]]
	if not (targetTable and newValue == newValue) then return end
	targetTable[tunable[2]] = math.Clamp(newValue, tunable[3], tunable[4])
	-- the anti-spin setup is built into each car's params: rebuild them
	if tunable[1] == "ANTI_SPIN" and AudioEngine.RebaseHandling then
		for vehicle in pairs(AudioEngine.TrackedVehicles or {}) do
			if IsValid(vehicle) then AudioEngine.RebaseHandling(vehicle) end
		end
	end
	sendState(requester)
end)

---------------------------------------------------------------------------
-- the car's vehicle script
---------------------------------------------------------------------------
-- the script the car is on, or (fell back to the test script) the PERP script it stands in for
local function scriptOf(vehicle)
	local carConfig = AudioEngine.GetCarConfig(vehicle)
	local actualScript = vehicle.audioScript or AudioEngine.VehicleScriptOf(vehicle)
	if actualScript and actualScript ~= AudioEngine.TEST_SCRIPT then return actualScript, false end
	local wantedScript = istable(vehicle.VehicleTable) and vehicle.VehicleTable.AudioPerpScript or carConfig.script
	return wantedScript or actualScript, true
end

-- off the PERP server: test_car.txt with the PERP script's physics values (sv_perp_physics.lua) in it
local function synthesize(perpScript)
	local text = file.Read(AudioEngine.TEST_SCRIPT, "GAME")
	if not text then return nil end
	local perpPhysics = AudioEngine.PERP_PHYSICS and AudioEngine.PERP_PHYSICS[perpScript]
	if not perpPhysics then return text end
	local values = {}
	for _, entry in ipairs(KeyValues.Parse(text)) do
		local value
		if entry.path == "engine" and entry.lowerKey == "gear" then
			value = perpPhysics.engine and perpPhysics.engine.gears and perpPhysics.engine.gears[entry.occurrence]
		elseif entry.path == "body" and entry.lowerKey == "masscenteroverride" then
			local massCenter = perpPhysics.body and perpPhysics.body.masscenter
			value = massCenter and string.format("%s %s %s", KeyValues.Num(massCenter[1]), KeyValues.Num(massCenter[2]), KeyValues.Num(massCenter[3]))
		elseif entry.axle and entry.path:sub(1, 4) == "axle" then
			value = perpPhysics.axles and perpPhysics.axles[entry.axle] and perpPhysics.axles[entry.axle][entry.lowerKey]
		else
			local section = perpPhysics[entry.path]
			value = istable(section) and section[entry.lowerKey]
		end
		if isnumber(value) then value = KeyValues.Num(value) end
		if isstring(value) then values[entry.index] = value end
	end
	return KeyValues.Rebuild(text, KeyValues.Parse(text), values)
end

-- the car's script as loaded (kept on the car: later edits are measured against it)
local function baseline(vehicle)
	if vehicle.audioDebugBaseline then return vehicle.audioDebugBaseline end
	if not vehicle.audioScriptParams then return nil, "This car's handling wasn't captured (spawned before the addon loaded?)." end
	local path, fallback = scriptOf(vehicle)
	if not path then return nil, "No vehicle script found for this car." end
	local text
	if fallback then text = synthesize(path) else text = file.Read(path, "GAME") end
	if not text then return nil, "Can't read " .. path .. "." end
	local physics = vehicle:GetPhysicsObject()
	vehicle.audioDebugBaseline = {
		path = path, fallback = fallback, text = text, current = text,
		params = table.Copy(vehicle.audioScriptParams), mass = IsValid(physics) and physics:GetMass() or nil,
	}
	return vehicle.audioDebugBaseline
end

local function sendScript(requester, vehicle, baselineData)
	local entries = KeyValues.Parse(baselineData.current)
	-- which entries reach the car live (a field of its params)
	local live = {}
	for _, entry in ipairs(entries) do
		if KeyValues.Target(baselineData.params, entry) then live[#live + 1] = entry.index end
	end
	local data = util.Compress(baselineData.current .. "\0" .. baselineData.text) or ""
	net.Start("audio_dbg_script")
	net.WriteEntity(vehicle)
	net.WriteString(baselineData.path)
	net.WriteBool(baselineData.fallback)
	net.WriteUInt(#data, 16)
	net.WriteData(data, #data)
	net.WriteUInt(#live, 12)
	for _, i in ipairs(live) do net.WriteUInt(i, 12) end
	net.Send(requester)
end

net.Receive("audio_dbg_script_req", function(_, requester)
	local vehicle = requestedCar(requester, net.ReadEntity())
	if not vehicle then return end
	local baselineData, errorMessage = baseline(vehicle)
	if not baselineData then sendResult(requester, false, errorMessage) return end
	sendScript(requester, vehicle, baselineData)
end)

-- the edited text onto the car: every changed value scaled from the file's into its params
net.Receive("audio_dbg_script_apply", function(_, requester)
	local vehicle = requestedCar(requester, net.ReadEntity())
	local dataLength = net.ReadUInt(16)
	local data = dataLength > 0 and net.ReadData(dataLength) or ""
	if not vehicle then return end
	local baselineData, errorMessage = baseline(vehicle)
	if not baselineData then sendResult(requester, false, errorMessage) return end
	local text = data ~= "" and util.Decompress(data) or baselineData.text   -- "" = back to the file
	if not text then sendResult(requester, false, "Couldn't read the edited script.") return end
	local fileEntries, editedEntries = KeyValues.Parse(baselineData.text), KeyValues.Parse(text)
	if not KeyValues.SameShape(fileEntries, editedEntries) then sendResult(requester, false, "The edited script's keys don't match the file's.") return end
	local params = table.Copy(baselineData.params)
	local applied, skipped, mass = 0, {}, nil
	for i, entry in ipairs(editedEntries) do
		local fileEntry = fileEntries[i]
		if entry.value ~= fileEntry.value then
			if not KeyValues.ValidValue(entry.value) then sendResult(requester, false, "Bad value for " .. entry.key .. ".") return end
			if KeyValues.ApplyValue(params, entry, fileEntry.value, entry.value) then
				applied = applied + 1
				if entry.path == "body" and entry.lowerKey == "massoverride" then mass = tonumber(entry.value) end
			else
				skipped[#skipped + 1] = entry.label .. "." .. entry.key
			end
		end
	end
	AudioEngine.RebaseHandling(vehicle, params)
	local physics = vehicle:GetPhysicsObject()
	local newMass = mass or baselineData.mass
	if IsValid(physics) and newMass and newMass > 0 then physics:SetMass(newMass) end
	baselineData.current = text
	local message = string.format("Applied %d change%s live to %s.", applied, applied == 1 and "" or "s", AudioEngine.GetCarConfig(vehicle).name)
	if data == "" then message = "Back to the file's values on " .. AudioEngine.GetCarConfig(vehicle).name .. "." end
	if #skipped > 0 then
		message = message .. " Needs a respawn (not live): " .. table.concat(skipped, ", ", 1, math.min(#skipped, 6)) .. (#skipped > 6 and " ..." or "")
	end
	sendResult(requester, true, message)
	sendScript(requester, vehicle, baselineData)
end)

---------------------------------------------------------------------------
-- gearing and rev response: networked to every client (sh_debug.lua reads them)
---------------------------------------------------------------------------
net.Receive("audio_dbg_gear", function(_, requester)
	local vehicle = requestedCar(requester, net.ReadEntity())
	local encodedText = net.ReadString()
	if not vehicle then return end
	local encoded = encodedText ~= "" and EngineDebug.EncodeGearing(EngineDebug.DecodeGearing(encodedText)) or ""
	vehicle:SetNW2String("audio_dbg_gear", encoded)
	sendResult(requester, true, encoded == "" and "Gearing back to the car's own." or "Gearing applied live (everyone hears it).")
end)

net.Receive("audio_dbg_rev", function(_, requester)
	local forAllCars = net.ReadBool()
	local vehicle = not forAllCars and net.ReadEntity() or nil
	local encodedText = net.ReadString()
	if not EngineDebug.Allowed(requester) then return end
	local rise, fall = EngineDebug.DecodeRev(encodedText)
	local encoded = rise and EngineDebug.EncodeRev(rise, fall) or ""
	if forAllCars then
		SetGlobal2String("audio_dbg_rev", encoded)
		sendResult(requester, true, encoded == "" and "Rev response for all cars back to DT.REV." or "Rev response set for all cars.")
		return
	end
	vehicle = requestedCar(requester, vehicle)
	if not vehicle then return end
	vehicle:SetNW2String("audio_dbg_rev", encoded)
	sendResult(requester, true, encoded == "" and "This car's rev response back to its own." or "Rev response set for this car.")
end)

---------------------------------------------------------------------------
-- switching the module off undoes what it changed live
---------------------------------------------------------------------------
cvars.AddChangeCallback("audio_engine_debug", function(_, _, newValue)
	if tonumber(newValue) ~= 0 then return end
	for _, tunable in ipairs(EngineDebug.TUNABLES) do
		local value = EngineDebug.TUNABLE_FILE[tunable[1] .. "." .. tunable[2]]
		if value ~= nil and AudioEngine[tunable[1]] then AudioEngine[tunable[1]][tunable[2]] = value end
	end
	SetGlobal2String("audio_dbg_rev", "")
	for vehicle in pairs(AudioEngine.TrackedVehicles or {}) do
		if IsValid(vehicle) then
			vehicle:SetNW2String("audio_dbg_gear", "")
			vehicle:SetNW2String("audio_dbg_rev", "")
			local baselineData = vehicle.audioDebugBaseline
			-- (also puts the file's anti-spin values back on every car)
			AudioEngine.RebaseHandling(vehicle, baselineData and baselineData.params or nil)
			if baselineData then
				local physics = vehicle:GetPhysicsObject()
				if IsValid(physics) and baselineData.mass then physics:SetMass(baselineData.mass) end
				vehicle.audioDebugBaseline = nil
			end
		end
	end
end, "audio_engine_debug")

-- (a Lua refresh of the core replaces AudioEngine.GetEngineConfig: wrap it again)
timer.Create("audio_engine_debug_install", 5, 0, EngineDebug.Install)

hook.Add("PlayerSay", "audio_engine_debug", function(requester, text)
	local message = string.lower(string.Trim(text))
	if (message == "!enginedebug" or message == "/enginedebug") and EngineDebug.Allowed(requester) then
		requester:ConCommand("audio_engine_debug_menu")
		return ""
	end
end)
