-- Honk Studio glue (runs next to lua/car_horn's config and synth in the page's Lua):
-- hands the page the file's settings as JSON and renders horns for it
STUDIO = {}

local function json(v)
	local t = type(v)
	if t == "string" then return "\"" .. v:gsub("[\\\"]", "\\%0"):gsub("\n", "\\n") .. "\"" end
	if t == "number" then return string.format("%.10g", v) end
	if t == "boolean" then return tostring(v) end
	if t ~= "table" then return "null" end
	local n = #v
	local isArray = n > 0 or next(v) == nil
	if isArray then
		for k in pairs(v) do
			if type(k) ~= "number" or k < 1 or k > n or k % 1 ~= 0 then isArray = false break end
		end
	end
	local parts = {}
	if isArray then
		for i = 1, n do parts[i] = json(v[i]) end
		return "[" .. table.concat(parts, ",") .. "]"
	end
	for k, x in pairs(v) do parts[#parts + 1] = json(tostring(k)) .. ":" .. json(x) end

	return "{" .. table.concat(parts, ",") .. "}"
end

function STUDIO.defaults()
	__result(json(CAR_HORN.CONFIG))
end

-- the samples go out through __push in blocks (a JS null or a huge table would not cross well)
local BLOCK = 512
function STUDIO.render(horn, cfg, inside)
	local samples, sr, n, loopStart = CAR_HORN.Synth.Render(horn, cfg, nil, inside)
	for i = 1, n, BLOCK do __push(table.unpack(samples, i, math.min(i + BLOCK - 1, n))) end
	__result(json({ sr = sr, loopStart = loopStart }))
end
