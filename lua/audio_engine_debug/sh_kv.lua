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

local AudioEngine = AUDIO_ENGINE
local KeyValues = {}
AudioEngine.KV = KeyValues

-- what a value may be edited to (numbers, words, vectors "0 0 -5"): never quotes or braces
function KeyValues.ValidValue(value)
	return type(value) == "string" and #value <= 64 and value:find("^[%w%s%.%-%+_]*$") ~= nil
end

function KeyValues.Parse(text)
	local entries = {}
	local textLength = #text
	local position = 1
	-- the stack of open blocks: { name, children = { name -> count }, keys = { lkey -> count }, axle }
	local stack = { { name = "", children = {}, keys = {} } }
	local pendingKey   -- a key waiting for its value or block

	local function lineEndComment(from)
		local lineEnd = text:find("\n", from, true) or (textLength + 1)
		local rest = text:sub(from, lineEnd - 1)
		local comment = rest:match("^[ \t]*//[ \t]*(.-)%s*$")
		return comment
	end

	while position <= textLength do
		local character = text:sub(position, position)
		if character:find("%s") then
			position = position + 1
		elseif text:sub(position, position + 1) == "//" then
			position = (text:find("\n", position, true) or textLength) + 1
		elseif character == "{" then
			local currentBlock = stack[#stack]
			local name = pendingKey and pendingKey.text:lower() or ""
			currentBlock.children[name] = (currentBlock.children[name] or 0) + 1
			local block = { name = name, occurrence = currentBlock.children[name], children = {}, keys = {}, axle = currentBlock.axle }
			if name == "axle" and #stack == 2 then block.axle = block.occurrence end
			stack[#stack + 1] = block
			pendingKey = nil
			position = position + 1
		elseif character == "}" then
			if #stack > 1 then stack[#stack] = nil end
			pendingKey = nil
			position = position + 1
		else
			-- a string: quoted, or up to whitespace / brace / quote
			local valueStart, valueEnd, inner, quoted
			if character == '"' then
				local closingQuote = text:find('"', position + 1, true) or (textLength + 1)
				valueStart, valueEnd, inner, quoted = position + 1, closingQuote - 1, text:sub(position + 1, closingQuote - 1), true
				position = closingQuote + 1
			else
				local tokenEnd = text:find('[%s{}"]', position) or (textLength + 1)
				valueStart, valueEnd, inner, quoted = position, tokenEnd - 1, text:sub(position, tokenEnd - 1), false
				position = tokenEnd
			end
			if inner:sub(1, 1) == "[" and not quoted then
				-- a platform conditional ([$WIN32]) after a value: not a key or a value
			elseif not pendingKey then
				pendingKey = { text = inner }
			else
				local currentBlock = stack[#stack]
				local lowerKey = pendingKey.text:lower()
				currentBlock.keys[lowerKey] = (currentBlock.keys[lowerKey] or 0) + 1
				-- the block path without the root ("vehicle")
				local parts, labels = {}, {}
				for depth = 3, #stack do
					parts[#parts + 1] = stack[depth].name
					local blockFrame = stack[depth]
					local count = stack[depth - 1].children[blockFrame.name] or 1
					labels[#labels + 1] = (blockFrame.name == "axle" or count > 1) and (blockFrame.name .. " " .. blockFrame.occurrence) or blockFrame.name
				end
				entries[#entries + 1] = {
					index = #entries + 1,
					path = table.concat(parts, "/"),
					label = #labels > 0 and table.concat(labels, " > ") or (stack[2] and stack[2].name or ""),
					key = pendingKey.text, lowerKey = lowerKey, occurrence = currentBlock.keys[lowerKey], axle = currentBlock.axle,
					value = inner, valueStart = valueStart, valueEnd = valueEnd, quoted = quoted,
					comment = lineEndComment(position),
				}
				pendingKey = nil
			end
		end
	end
	return entries
end

-- the text with new values put in: values[idx] = new value (unchanged entries left out)
function KeyValues.Rebuild(text, entries, values)
	local changed = {}
	for _, entry in ipairs(entries) do
		if values[entry.index] ~= nil and values[entry.index] ~= entry.value then changed[#changed + 1] = entry end
	end
	table.sort(changed, function(first, second) return first.valueStart > second.valueStart end)
	for _, entry in ipairs(changed) do
		text = text:sub(1, entry.valueStart - 1) .. values[entry.index] .. text:sub(entry.valueEnd + 1)
	end
	return text
end

-- do two parses describe the same file shape (same keys in the same blocks)?
function KeyValues.SameShape(first, second)
	if #first ~= #second then return false end
	for i = 1, #first do
		if first[i].path ~= second[i].path or first[i].lowerKey ~= second[i].lowerKey or first[i].occurrence ~= second[i].occurrence then return false end
	end
	return true
end

--[[
	Which GetVehicleParams field a script key sets: { field, kind }. kind: nil = a number, "speed"
	(mph in the file, inches/s in the params), "bool", "vec" (x y z), "list" (the n-th gear).
	Keys left out (wheel radius, materials, offsets, sounds) only take effect on a fresh spawn.
]]
KeyValues.PARAMS = {
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
function KeyValues.Target(params, entry)
	local mapping = KeyValues.PARAMS[entry.path] and KeyValues.PARAMS[entry.path][entry.lowerKey]
	if not mapping or not params then return nil end
	local section
	if entry.path == "body" then section = params.body
	elseif entry.path == "engine" or entry.path == "engine/boost" then section = params.engine
	elseif entry.path == "steering" then section = params.steering
	elseif entry.axle then section = params.axles and params.axles[entry.axle] end
	if type(section) ~= "table" then return nil end
	if mapping[2] == "list" then
		if type(section[mapping[1]]) ~= "table" or section[mapping[1]][entry.occurrence] == nil then return nil end
	elseif section[mapping[1]] == nil then
		return nil
	end
	return section, mapping[1], mapping[2]
end

local function parseVector(text)
	local x, y, z = tostring(text or ""):match("^%s*(%S+)%s+(%S+)%s+(%S+)")
	x, y, z = tonumber(x), tonumber(y), tonumber(z)
	if x and y and z then return x, y, z end
end

local function truthy(text)
	local lower = tostring(text):lower()
	if lower == "true" then return true end
	return (tonumber(text) or 0) ~= 0
end

--[[
	Put an edited value into params (as GetVehicleParams gives them, the car's own at the file's
	original value `orig`): scaled by new / orig, so whatever unit Source keeps the field in, the
	result is right. An original of 0 can't be scaled: the new value is taken as it is (mph turned
	into inches/s for speeds). Returns true if it was set.
]]
function KeyValues.ApplyValue(params, entry, original, newValue)
	local section, field, kind = KeyValues.Target(params, entry)
	if not section then return false end
	if kind == "bool" then
		section[field] = truthy(newValue)
		return true
	elseif kind == "vec" then
		local originalX, originalY, originalZ = parseVector(original)
		local newX, newY, newZ = parseVector(newValue)
		local current = section[field]
		if not (newX and current and current.x) then return false end
		-- the unit, from any component that isn't 0
		local unitScale = 1
		if originalX and originalX ~= 0 then
			unitScale = current.x / originalX
		elseif originalY and originalY ~= 0 then
			unitScale = current.y / originalY
		elseif originalZ and originalZ ~= 0 then
			unitScale = current.z / originalZ
		end
		section[field] = Vector(newX * unitScale, newY * unitScale, newZ * unitScale)
		return true
	end
	local originalNumber, newNumber = tonumber(original), tonumber(newValue)
	if not newNumber then return false end
	local function scaled(paramValue)
		if type(paramValue) ~= "number" then return newNumber end
		if originalNumber and originalNumber ~= 0 then return paramValue * newNumber / originalNumber end
		return newNumber * (kind == "speed" and (AudioEngine.HU_PER_MPH or 17.6) or 1)
	end
	if kind == "list" then
		section[field][entry.occurrence] = scaled(section[field][entry.occurrence])
	else
		section[field] = scaled(section[field])
	end
	return true
end

-- how a number reads back in a file ("%g", no exponent for ordinary values)
function KeyValues.Num(value)
	if math.abs(value) >= 1e6 or (value ~= 0 and math.abs(value) < 1e-4) then return string.format("%g", value) end
	local text = string.format("%.4f", value):gsub("0+$", ""):gsub("%.$", "")
	return text
end

return KeyValues
