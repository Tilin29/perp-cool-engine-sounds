--[[
	Audio Engine debug module - vehicle script (Valve KeyValues) reader / editor (shared)

	Reads a vehicle script into a flat list of its key/value pairs, each with where its value sits
	in the text, so an edited copy keeps the file exactly as it was (layout, comments, order) with
	only the changed values swapped in. Blocks that repeat (axle) and keys that repeat (gear) are
	numbered by occurrence.

	Entry fields:
	  path    the block it's in, lower case, without the root: "engine", "engine/boost", "axle/wheel"
	  label   the same for people: "axle 2 > wheel"
	  key     the key as spelled in the file; lkey lower case
	  occ     which occurrence of this key in its block (the 3rd "gear" is 3)
	  axle    which axle block it's in (1 front, 2 rear), or nil
	  value   the value text; vs, ve: where it sits (inner text, without the quotes)
	  comment the // comment after it on the same line, if any
]]

local E = AUDIO_ENGINE
local KV = {}
E.KV = KV

-- what a value may be edited to (numbers, words, vectors "0 0 -5"): never quotes or braces
function KV.ValidValue(v)
	return type(v) == "string" and #v <= 64 and v:find("^[%w%s%.%-%+_]*$") ~= nil
end

function KV.Parse(text)
	local entries = {}
	local n = #text
	local i = 1
	-- the stack of open blocks: { name, children = { name -> count }, keys = { lkey -> count }, axle }
	local stack = { { name = "", children = {}, keys = {} } }
	local pending   -- a key waiting for its value or block

	local function lineEndComment(from)
		local nl = text:find("\n", from, true) or (n + 1)
		local rest = text:sub(from, nl - 1)
		local c = rest:match("^[ \t]*//[ \t]*(.-)%s*$")
		return c
	end

	while i <= n do
		local c = text:sub(i, i)
		if c:find("%s") then
			i = i + 1
		elseif text:sub(i, i + 1) == "//" then
			i = (text:find("\n", i, true) or n) + 1
		elseif c == "{" then
			local top = stack[#stack]
			local name = pending and pending.v:lower() or ""
			top.children[name] = (top.children[name] or 0) + 1
			local frame = { name = name, occ = top.children[name], children = {}, keys = {}, axle = top.axle }
			if name == "axle" and #stack == 2 then frame.axle = frame.occ end
			stack[#stack + 1] = frame
			pending = nil
			i = i + 1
		elseif c == "}" then
			if #stack > 1 then stack[#stack] = nil end
			pending = nil
			i = i + 1
		else
			-- a string: quoted, or up to whitespace / brace / quote
			local s, e, inner, quoted
			if c == '"' then
				local close = text:find('"', i + 1, true) or (n + 1)
				s, e, inner, quoted = i + 1, close - 1, text:sub(i + 1, close - 1), true
				i = close + 1
			else
				local stop = text:find('[%s{}"]', i) or (n + 1)
				s, e, inner, quoted = i, stop - 1, text:sub(i, stop - 1), false
				i = stop
			end
			if inner:sub(1, 1) == "[" and not quoted then
				-- a platform conditional ([$WIN32]) after a value: not a key or a value
			elseif not pending then
				pending = { v = inner }
			else
				local top = stack[#stack]
				local lkey = pending.v:lower()
				top.keys[lkey] = (top.keys[lkey] or 0) + 1
				-- the block path without the root ("vehicle")
				local parts, labels = {}, {}
				for d = 3, #stack do
					parts[#parts + 1] = stack[d].name
					local f = stack[d]
					local count = stack[d - 1].children[f.name] or 1
					labels[#labels + 1] = (f.name == "axle" or count > 1) and (f.name .. " " .. f.occ) or f.name
				end
				entries[#entries + 1] = {
					idx = #entries + 1,
					path = table.concat(parts, "/"),
					label = #labels > 0 and table.concat(labels, " > ") or (stack[2] and stack[2].name or ""),
					key = pending.v, lkey = lkey, occ = top.keys[lkey], axle = top.axle,
					value = inner, vs = s, ve = e, quoted = quoted,
					comment = lineEndComment(i),
				}
				pending = nil
			end
		end
	end
	return entries
end

-- the text with new values put in: values[idx] = new value (unchanged entries left out)
function KV.Rebuild(text, entries, values)
	local order = {}
	for _, e in ipairs(entries) do
		if values[e.idx] ~= nil and values[e.idx] ~= e.value then order[#order + 1] = e end
	end
	table.sort(order, function(a, b) return a.vs > b.vs end)
	for _, e in ipairs(order) do
		text = text:sub(1, e.vs - 1) .. values[e.idx] .. text:sub(e.ve + 1)
	end
	return text
end

-- do two parses describe the same file shape (same keys in the same blocks)?
function KV.SameShape(a, b)
	if #a ~= #b then return false end
	for i = 1, #a do
		if a[i].path ~= b[i].path or a[i].lkey ~= b[i].lkey or a[i].occ ~= b[i].occ then return false end
	end
	return true
end

--[[
	Which GetVehicleParams field a script key sets: { field, kind }. kind: nil = a number, "speed"
	(mph in the file, inches/s in the params), "bool", "vec" (x y z), "list" (the n-th gear).
	Keys left out (wheel radius, materials, offsets, sounds) only take effect on a fresh spawn.
]]
KV.PARAMS = {
	body = {
		massoverride = { "massOverride" }, addgravity = { "addGravity" }, maxangularvelocity = { "maxAngularVelocity" },
		countertorquefactor = { "counterTorqueFactor" }, masscenteroverride = { "massCenterOverride", "vec" },
		tiltforce = { "tiltForce" }, tiltforceheight = { "tiltForceHeight" }, keepuprighttorque = { "keepUprightTorque" },
	},
	engine = {
		horsepower = { "horsepower" }, maxrpm = { "maxRPM" }, maxspeed = { "maxSpeed", "speed" },
		maxreversespeed = { "maxRevSpeed", "speed" }, autotransmission = { "isAutoTransmission", "bool" },
		axleratio = { "axleRatio" }, gear = { "gearRatio", "list" }, shiftuprpm = { "shiftUpRPM" },
		shiftdownrpm = { "shiftDownRPM" }, throttletime = { "throttleTime" },
		autobrakespeedgain = { "autobrakeSpeedGain" }, autobrakespeedfactor = { "autobrakeSpeedFactor" },
	},
	["engine/boost"] = {
		force = { "boostForce" }, duration = { "boostDuration" }, delay = { "boostDelay" },
		maxspeed = { "boostMaxSpeed", "speed" }, torqueboost = { "torqueBoost", "bool" },
	},
	steering = {
		degreesslow = { "degreesSlow" }, degreesfast = { "degreesFast" }, degreesboost = { "degreesBoost" },
		steeringexponent = { "steeringExponent" }, slowcarspeed = { "speedSlow", "speed" }, fastcarspeed = { "speedFast", "speed" },
		slowsteeringrate = { "steeringRateSlow" }, faststeeringrate = { "steeringRateFast" },
		steeringrestrateslow = { "steeringRestRateSlow" }, steeringrestratefast = { "steeringRestRateFast" },
		turnthrottlereduceslow = { "turnThrottleReduceSlow" }, turnthrottlereducefast = { "turnThrottleReduceFast" },
		brakesteeringratefactor = { "brakeSteeringRateFactor" }, throttlesteeringrestratefactor = { "throttleSteeringRestRateFactor" },
		booststeeringrestratefactor = { "boostSteeringRestRateFactor" }, booststeeringratefactor = { "boostSteeringRateFactor" },
		powerslideaccel = { "powerSlideAccel" }, skidallowed = { "isSkidAllowed", "bool" }, dustcloud = { "dustCloud", "bool" },
	},
	axle = { torquefactor = { "torqueFactor" }, brakefactor = { "brakeFactor" } },
	["axle/wheel"] = {
		mass = { "wheels_mass" }, inertia = { "wheels_inertia" }, damping = { "wheels_damping" }, rotdamping = { "wheels_rotdamping" },
	},
	["axle/suspension"] = {
		springconstant = { "suspension_springConstant" }, springdamping = { "suspension_springDamping" },
		stabilizerconstant = { "suspension_stabilizerConstant" }, springdampingcompression = { "suspension_springDampingCompression" },
		maxbodyforce = { "suspension_maxBodyForce" },
	},
}

-- the params table an entry's field lives in, and its mapping (or nil: not settable live)
function KV.Target(params, e)
	local m = KV.PARAMS[e.path] and KV.PARAMS[e.path][e.lkey]
	if not m or not params then return nil end
	local t
	if e.path == "body" then t = params.body
	elseif e.path == "engine" or e.path == "engine/boost" then t = params.engine
	elseif e.path == "steering" then t = params.steering
	elseif e.axle then t = params.axles and params.axles[e.axle] end
	if type(t) ~= "table" then return nil end
	if m[2] == "list" then
		if type(t[m[1]]) ~= "table" or t[m[1]][e.occ] == nil then return nil end
	elseif t[m[1]] == nil then
		return nil
	end
	return t, m[1], m[2]
end

local function vec3(s)
	local x, y, z = tostring(s or ""):match("^%s*(%S+)%s+(%S+)%s+(%S+)")
	x, y, z = tonumber(x), tonumber(y), tonumber(z)
	if x and y and z then return x, y, z end
end

local function truthy(s)
	local l = tostring(s):lower()
	if l == "true" then return true end
	return (tonumber(s) or 0) ~= 0
end

--[[
	Put an edited value into params (as GetVehicleParams gives them, the car's own at the file's
	original value `orig`): scaled by new / orig, so whatever unit Source keeps the field in, the
	result is right. An original of 0 can't be scaled: the new value is taken as it is (mph turned
	into inches/s for speeds). Returns true if it was set.
]]
function KV.ApplyValue(params, e, orig, new)
	local t, field, kind = KV.Target(params, e)
	if not t then return false end
	if kind == "bool" then
		t[field] = truthy(new)
		return true
	elseif kind == "vec" then
		local ox, oy, oz = vec3(orig)
		local nx, ny, nz = vec3(new)
		local cur = t[field]
		if not (nx and cur and cur.x) then return false end
		-- the unit, from any component that isn't 0
		local k = 1
		if ox and ox ~= 0 then k = cur.x / ox elseif oy and oy ~= 0 then k = cur.y / oy elseif oz and oz ~= 0 then k = cur.z / oz end
		t[field] = Vector(nx * k, ny * k, nz * k)
		return true
	end
	local o, nv = tonumber(orig), tonumber(new)
	if not nv then return false end
	local function scaled(p)
		if type(p) ~= "number" then return nv end
		if o and o ~= 0 then return p * nv / o end
		return nv * (kind == "speed" and (E.HU_PER_MPH or 17.6) or 1)
	end
	if kind == "list" then
		t[field][e.occ] = scaled(t[field][e.occ])
	else
		t[field] = scaled(t[field])
	end
	return true
end

-- how a number reads back in a file ("%g", no exponent for ordinary values)
function KV.Num(x)
	if math.abs(x) >= 1e6 or (x ~= 0 and math.abs(x) < 1e-4) then return string.format("%g", x) end
	local s = string.format("%.4f", x):gsub("0+$", ""):gsub("%.$", "")
	return s
end

return KV
