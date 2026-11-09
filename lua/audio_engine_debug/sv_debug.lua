--[[
	Audio Engine debug module (server): the debug menu's requests, superadmins only, while
	audio_engine_debug is 1. Not part of the final addon (see sh_debug.lua).
]]

local E = AUDIO_ENGINE
local DBG = E.Debug
local KV = E.KV

for _, n in ipairs({ "audio_dbg_state_req", "audio_dbg_state", "audio_dbg_cvar", "audio_dbg_tune",
	"audio_dbg_script_req", "audio_dbg_script", "audio_dbg_script_apply", "audio_dbg_gear", "audio_dbg_rev",
	"audio_dbg_result" }) do
	util.AddNetworkString(n)
end

local function result(ply, ok, msg)
	net.Start("audio_dbg_result")
	net.WriteBool(ok)
	net.WriteString(msg)
	net.Send(ply)
end

-- the car a request is about: one of ours, the player allowed
local function carOf(ply, veh)
	if not DBG.Allowed(ply) then return nil end
	if not (IsValid(veh) and E.TrackedVehicles and E.TrackedVehicles[veh] and E.GetCarConfig(veh)) then
		result(ply, false, "Not a car with the procedural engine.")
		return nil
	end
	return veh
end

---------------------------------------------------------------------------
-- state: server convars and tuned tables
---------------------------------------------------------------------------
local function sendState(ply)
	net.Start("audio_dbg_state")
	net.WriteUInt(#DBG.SERVER_CVARS, 8)
	for _, c in ipairs(DBG.SERVER_CVARS) do
		local cv = GetConVar(c[1])
		net.WriteString(c[1])
		net.WriteString(cv and cv:GetString() or "")
	end
	net.WriteUInt(#DBG.TUNABLES, 8)
	for _, t in ipairs(DBG.TUNABLES) do
		local tbl = E[t[1]]
		net.WriteFloat(tbl and tonumber(tbl[t[2]]) or 0)
	end
	net.Send(ply)
end

-- the tables' values as the files have them, for "what changed"
DBG.TUNABLE_FILE = DBG.TUNABLE_FILE or {}
for _, t in ipairs(DBG.TUNABLES) do
	local key = t[1] .. "." .. t[2]
	if DBG.TUNABLE_FILE[key] == nil and E[t[1]] then DBG.TUNABLE_FILE[key] = E[t[1]][t[2]] end
end

net.Receive("audio_dbg_state_req", function(_, ply)
	if DBG.Allowed(ply) then sendState(ply) end
end)

net.Receive("audio_dbg_cvar", function(_, ply)
	if not DBG.Allowed(ply) then return end
	local n = net.ReadUInt(4)
	for _ = 1, n do
		local name, value = net.ReadString(), net.ReadString()
		local c = DBG.SERVER_CVAR_SET[name]
		if c then
			local v = tonumber(value) or 0
			if c[2] == "bool" then v = v ~= 0 and 1 or 0 end
			if c[4] then v = math.Clamp(v, c[4], c[5]) end
			RunConsoleCommand(name, tostring(v))
		end
	end
	-- (RunConsoleCommand takes effect on the next frame)
	timer.Simple(0.1, function() if IsValid(ply) then sendState(ply) end end)
end)

net.Receive("audio_dbg_tune", function(_, ply)
	if not DBG.Allowed(ply) then return end
	local i, v = net.ReadUInt(8), net.ReadFloat()
	local t = DBG.TUNABLES[i]
	local tbl = t and E[t[1]]
	if not (tbl and v == v) then return end
	tbl[t[2]] = math.Clamp(v, t[3], t[4])
	-- the anti-spin setup is built into each car's params: rebuild them
	if t[1] == "ANTI_SPIN" and E.RebaseHandling then
		for veh in pairs(E.TrackedVehicles or {}) do
			if IsValid(veh) then E.RebaseHandling(veh) end
		end
	end
	sendState(ply)
end)

---------------------------------------------------------------------------
-- the car's vehicle script
---------------------------------------------------------------------------
-- the script the car is on, or (fell back to the test script) the PERP script it stands in for
local function scriptOf(veh)
	local car = E.GetCarConfig(veh)
	local actual = veh.audioScript or E.VehicleScriptOf(veh)
	if actual and actual ~= E.TEST_SCRIPT then return actual, false end
	local want = istable(veh.VehicleTable) and veh.VehicleTable.AudioPerpScript or car.script
	return want or actual, true
end

-- off the PERP server: test_car.txt with the PERP script's physics values (sv_perp_physics.lua) in it
local function synthesize(perpScript)
	local text = file.Read(E.TEST_SCRIPT, "GAME")
	if not text then return nil end
	local ph = E.PERP_PHYSICS and E.PERP_PHYSICS[perpScript]
	if not ph then return text end
	local values = {}
	for _, e in ipairs(KV.Parse(text)) do
		local v
		if e.path == "engine" and e.lkey == "gear" then
			v = ph.engine and ph.engine.gears and ph.engine.gears[e.occ]
		elseif e.path == "body" and e.lkey == "masscenteroverride" then
			local m = ph.body and ph.body.masscenter
			v = m and string.format("%s %s %s", KV.Num(m[1]), KV.Num(m[2]), KV.Num(m[3]))
		elseif e.axle and e.path:sub(1, 4) == "axle" then
			v = ph.axles and ph.axles[e.axle] and ph.axles[e.axle][e.lkey]
		else
			local sec = ph[e.path]
			v = istable(sec) and sec[e.lkey]
		end
		if isnumber(v) then v = KV.Num(v) end
		if isstring(v) then values[e.idx] = v end
	end
	return KV.Rebuild(text, KV.Parse(text), values)
end

-- the car's script as loaded (kept on the car: later edits are measured against it)
local function baseline(veh)
	if veh.audioDbg then return veh.audioDbg end
	if not veh.audioScriptParams then return nil, "This car's handling wasn't captured (spawned before the addon loaded?)." end
	local path, fallback = scriptOf(veh)
	if not path then return nil, "No vehicle script found for this car." end
	local text
	if fallback then text = synthesize(path) else text = file.Read(path, "GAME") end
	if not text then return nil, "Can't read " .. path .. "." end
	local phys = veh:GetPhysicsObject()
	veh.audioDbg = {
		path = path, fallback = fallback, text = text, current = text,
		params = table.Copy(veh.audioScriptParams), mass = IsValid(phys) and phys:GetMass() or nil,
	}
	return veh.audioDbg
end

local function sendScript(ply, veh, b)
	local entries = KV.Parse(b.current)
	-- which entries reach the car live (a field of its params)
	local live = {}
	for _, e in ipairs(entries) do
		if KV.Target(b.params, e) then live[#live + 1] = e.idx end
	end
	local data = util.Compress(b.current .. "\0" .. b.text) or ""
	net.Start("audio_dbg_script")
	net.WriteEntity(veh)
	net.WriteString(b.path)
	net.WriteBool(b.fallback)
	net.WriteUInt(#data, 16)
	net.WriteData(data, #data)
	net.WriteUInt(#live, 12)
	for _, i in ipairs(live) do net.WriteUInt(i, 12) end
	net.Send(ply)
end

net.Receive("audio_dbg_script_req", function(_, ply)
	local veh = carOf(ply, net.ReadEntity())
	if not veh then return end
	local b, err = baseline(veh)
	if not b then result(ply, false, err) return end
	sendScript(ply, veh, b)
end)

-- the edited text onto the car: every changed value scaled from the file's into its params
net.Receive("audio_dbg_script_apply", function(_, ply)
	local veh = carOf(ply, net.ReadEntity())
	local len = net.ReadUInt(16)
	local data = len > 0 and net.ReadData(len) or ""
	if not veh then return end
	local b, err = baseline(veh)
	if not b then result(ply, false, err) return end
	local text = data ~= "" and util.Decompress(data) or b.text   -- "" = back to the file
	if not text then result(ply, false, "Couldn't read the edited script.") return end
	local orig, new = KV.Parse(b.text), KV.Parse(text)
	if not KV.SameShape(orig, new) then result(ply, false, "The edited script's keys don't match the file's.") return end
	local p = table.Copy(b.params)
	local applied, skipped, mass = 0, {}, nil
	for i, e in ipairs(new) do
		local o = orig[i]
		if e.value ~= o.value then
			if not KV.ValidValue(e.value) then result(ply, false, "Bad value for " .. e.key .. ".") return end
			if KV.ApplyValue(p, e, o.value, e.value) then
				applied = applied + 1
				if e.path == "body" and e.lkey == "massoverride" then mass = tonumber(e.value) end
			else
				skipped[#skipped + 1] = e.label .. "." .. e.key
			end
		end
	end
	E.RebaseHandling(veh, p)
	local phys = veh:GetPhysicsObject()
	local m = mass or b.mass
	if IsValid(phys) and m and m > 0 then phys:SetMass(m) end
	b.current = text
	local msg = string.format("Applied %d change%s live to %s.", applied, applied == 1 and "" or "s", E.GetCarConfig(veh).name)
	if data == "" then msg = "Back to the file's values on " .. E.GetCarConfig(veh).name .. "." end
	if #skipped > 0 then msg = msg .. " Needs a respawn (not live): " .. table.concat(skipped, ", ", 1, math.min(#skipped, 6)) .. (#skipped > 6 and " ..." or "") end
	result(ply, true, msg)
	sendScript(ply, veh, b)
end)

---------------------------------------------------------------------------
-- gearing and rev response: networked to every client (sh_debug.lua reads them)
---------------------------------------------------------------------------
net.Receive("audio_dbg_gear", function(_, ply)
	local veh = carOf(ply, net.ReadEntity())
	local s = net.ReadString()
	if not veh then return end
	local enc = s ~= "" and DBG.EncodeGearing(DBG.DecodeGearing(s)) or ""
	veh:SetNW2String("audio_dbg_gear", enc)
	result(ply, true, enc == "" and "Gearing back to the car's own." or "Gearing applied live (everyone hears it).")
end)

net.Receive("audio_dbg_rev", function(_, ply)
	local global = net.ReadBool()
	local veh = not global and net.ReadEntity() or nil
	local s = net.ReadString()
	if not DBG.Allowed(ply) then return end
	local r, f = DBG.DecodeRev(s)
	local enc = r and DBG.EncodeRev(r, f) or ""
	if global then
		SetGlobal2String("audio_dbg_rev", enc)
		result(ply, true, enc == "" and "Rev response for all cars back to DT.REV." or "Rev response set for all cars.")
		return
	end
	veh = carOf(ply, veh)
	if not veh then return end
	veh:SetNW2String("audio_dbg_rev", enc)
	result(ply, true, enc == "" and "This car's rev response back to its own." or "Rev response set for this car.")
end)

---------------------------------------------------------------------------
-- switching the module off undoes what it changed live
---------------------------------------------------------------------------
cvars.AddChangeCallback("audio_engine_debug", function(_, _, new)
	if tonumber(new) ~= 0 then return end
	for _, t in ipairs(DBG.TUNABLES) do
		local v = DBG.TUNABLE_FILE[t[1] .. "." .. t[2]]
		if v ~= nil and E[t[1]] then E[t[1]][t[2]] = v end
	end
	SetGlobal2String("audio_dbg_rev", "")
	for veh in pairs(E.TrackedVehicles or {}) do
		if IsValid(veh) then
			veh:SetNW2String("audio_dbg_gear", "")
			veh:SetNW2String("audio_dbg_rev", "")
			local b = veh.audioDbg
			-- (also puts the file's anti-spin values back on every car)
			E.RebaseHandling(veh, b and b.params or nil)
			if b then
				local phys = veh:GetPhysicsObject()
				if IsValid(phys) and b.mass then phys:SetMass(b.mass) end
				veh.audioDbg = nil
			end
		end
	end
end, "audio_engine_debug")

-- (a Lua refresh of the core replaces E.GetEngineConfig: wrap it again)
timer.Create("audio_engine_debug_install", 5, 0, DBG.Install)

hook.Add("PlayerSay", "audio_engine_debug", function(ply, text)
	local t = string.lower(string.Trim(text))
	if (t == "!enginedebug" or t == "/enginedebug") and DBG.Allowed(ply) then
		ply:ConCommand("audio_engine_debug_menu")
		return ""
	end
end)
