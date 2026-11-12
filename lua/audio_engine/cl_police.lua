--[[
	Emergency lights (sh_police.lua, sv_police.lua): the flashing. The bar's LEDs and the built-in
	lamps' lenses are plain textures, so a lit module gets a glowing lens quad and a glow sprite that
	fades as it turns away from the viewer; the nearest cars also light their surroundings (one
	dynamic light per side). The light key (audio_engine_lightkey, default left shift) steps the
	driver's lights off -> CODE 2 -> CODE 3 -> off.

	Patterns (each car offset in time, so a row of cars doesn't flash in step):
	  CODE 2: slow wig-wag, the driver's outer modules and corners with the passenger's inner ones,
	          then the other way round
	  CODE 3: the same split as quad flashes, twice as fast, plus double flashes in the middle

	Colours by the car's scheme (NW2 audio_lightscheme): on the bar per side, built-in lamps keep
	their lens's own colour. A car whose audio_lightbar is itself has built-in lamps
	(E.BUILTIN_LIGHTS), placed by its body bone.
]]
local E = AUDIO_ENGINE

local cvLightKey = CreateClientConVar("audio_engine_lightkey", "lshift", true, false,
	"Key that switches the emergency lights of the car you drive (a key name such as lshift, l or f2; none = off)")

local CODE2 = { period = 1.2, on = 0.4 }
local CODE3 = { period = 0.5, flash = 0.0625, flashOn = 0.04, white = 0.035 }
local LIST_REFRESH = 0.5
local DRAW_DIST = 6000
local DLIGHT_DIST = 2500
local MAX_DLIGHT_CARS = 4
local DLIGHT_BASE = 0x40000
local LENS_HEIGHT = 1.7
local GLOW_SIZE = 18
local GLOW_PER_UNIT = 0.012
local GLOW_MAX = 90
local GLOW_OUT = 2
local PHASE_PER_INDEX = 0.37
local DLIGHT = { brightness = 2, decay = 4000, size = 300, life = 0.05 }
local SIDE_LIGHT_POS = { [-1] = Vector(0, -20, 14), [1] = Vector(0, 20, 14) }

local GLOW = Material("sprites/light_glow02_add")
local LENS = CreateMaterial("audio_engine_lightbar_lens", "UnlitGeneric", {
	["$basetexture"] = "color/white",
	["$additive"] = "1",
	["$vertexcolor"] = "1",
	["$vertexalpha"] = "1",
})
local COLORS = {
	red = Color(255, 25, 15),
	white = Color(255, 255, 255),
	blue = Color(25, 70, 255),
	yellow = Color(255, 170, 10),
}
-- the bar's colour per side (-1 driver's, 0 centre, 1 passenger's) by scheme
local SCHEME_SIDES = {
	police = { [-1] = COLORS.red, [0] = COLORS.white, [1] = COLORS.blue },
	fire = { [-1] = COLORS.red, [0] = COLORS.yellow, [1] = COLORS.yellow },
	medical = { [-1] = COLORS.red, [0] = COLORS.white, [1] = COLORS.white },
}
local glowColor = Color(255, 255, 255)

-- which half of the wig-wag a module flashes in: -1 or 1 (the centre modules have their own timing)
local function halfOf(m)
	if m.group == "i" then return -m.side end

	return m.side
end

local function isLit(m, mode, t)
	if mode == 1 then
		local p = t % CODE2.period
		local half = p < CODE2.period / 2 and -1 or 1
		if m.side == 0 or halfOf(m) ~= half then return false end

		return p % (CODE2.period / 2) < CODE2.on
	end
	local p = t % CODE3.period
	local inHalf = p % (CODE3.period / 2)
	if m.side == 0 then
		return inHalf < CODE3.white or (inHalf > 2 * CODE3.white and inHalf < 3 * CODE3.white)
	end
	local half = p < CODE3.period / 2 and -1 or 1
	if halfOf(m) ~= half then return false end

	return inHalf % CODE3.flash < CODE3.flashOn
end

-- cars with lights near enough to matter, refreshed now and then rather than searched every frame
local police = {}
local nextRefresh = 0

local function refreshList()
	police = {}
	for _, veh in ipairs(ents.FindByClass("prop_vehicle_jeep")) do
		local bar = veh:GetNW2Entity("audio_lightbar")
		if IsValid(bar) then
			local entry = { veh = veh, bar = bar, sides = SCHEME_SIDES[veh:GetNW2String("audio_lightscheme", "police")] or SCHEME_SIDES.police }
			if bar == veh then
				local set = E.BUILTIN_LIGHTS[string.lower(veh:GetModel() or "")]
				local bone = set and veh:LookupBone(set.bone)
				if bone then
					entry.lamps, entry.bone = set.lamps, bone
					table.insert(police, entry)
				end
			else
				table.insert(police, entry)
			end
		end
	end
end

local function lightsOf(entry)
	local veh, bar = entry.veh, entry.bar
	if not IsValid(veh) or not IsValid(bar) or bar:IsDormant() then return 0 end

	return veh:GetNW2Int("audio_lights", 0)
end

local function drawLens(wp, wn, w, h, col, eye)
	render.SetMaterial(LENS)
	render.DrawQuadEasy(wp, wn, w, h, col, 0)
	local toEye = eye - wp
	local dist = toEye:Length()
	local facing = wn:Dot(toEye) / math.max(dist, 1)
	if facing <= 0 then return end
	local size = math.min(GLOW_SIZE + dist * GLOW_PER_UNIT, GLOW_MAX) * (0.35 + 0.65 * facing)
	glowColor.r, glowColor.g, glowColor.b, glowColor.a = col.r, col.g, col.b, 255 * facing
	render.SetMaterial(GLOW)
	render.DrawSprite(wp + wn * GLOW_OUT, size, size, glowColor)
end

-- a direction in a frame given by its forward / right / up (right = -y, as Entity:GetRight)
local function turned(fwd, right, up, n)
	return fwd * n.x - right * n.y + up * n.z
end

local function drawBar(entry, mode, t, eye)
	local bar = entry.bar
	local ang = bar:GetAngles()
	local fwd, right, up = ang:Forward(), ang:Right(), ang:Up()
	for _, m in ipairs(E.LIGHTBAR_MODULES) do
		if isLit(m, mode, t) then
			drawLens(bar:LocalToWorld(m.pos), turned(fwd, right, up, m.n), m.w, LENS_HEIGHT, entry.sides[m.side], eye)
		end
	end
end

-- built-in lamps follow the body bone (nil while the car hasn't set up its bones: not drawn)
local function drawBuiltin(entry, mode, t, eye)
	local mat = entry.veh:GetBoneMatrix(entry.bone)
	if not mat then return end
	local fwd, right, up = mat:GetForward(), mat:GetRight(), mat:GetUp()
	for _, m in ipairs(entry.lamps) do
		if isLit(m, mode, t) then
			drawLens(mat * m.pos, turned(fwd, right, up, m.n), m.w, m.h, COLORS[m.color] or COLORS.white, eye)
		end
	end
end

hook.Add("PostDrawTranslucentRenderables", "audio_engine_police", function(depth, skybox)
	if depth or skybox then return end
	local eye = EyePos()
	local t0 = CurTime()
	for _, entry in ipairs(police) do
		local mode = lightsOf(entry)
		if mode > 0 and entry.bar:GetPos():DistToSqr(eye) < DRAW_DIST * DRAW_DIST then
			local t = t0 + entry.veh:EntIndex() * PHASE_PER_INDEX
			if entry.lamps then drawBuiltin(entry, mode, t, eye) else drawBar(entry, mode, t, eye) end
		end
	end
end)

-- the colour a side lights its surroundings with right now, or nil
local function sideLit(entry, side, mode, t)
	if entry.lamps then
		for _, m in ipairs(entry.lamps) do
			if m.side == side and m.group == "o" and isLit(m, mode, t) then return COLORS[m.color] or COLORS.white end
		end

		return nil
	end
	for _, m in ipairs(E.LIGHTBAR_MODULES) do
		if m.side == side and m.group == "o" and isLit(m, mode, t) then return entry.sides[side] end
	end

	return nil
end

-- where a side's light comes from: beside the bar, or the middle of that side's built-in lamps
local function sideLightPos(entry, side)
	if not entry.lamps then return entry.bar:LocalToWorld(SIDE_LIGHT_POS[side]) end
	entry.sidePos = entry.sidePos or {}
	local p = entry.sidePos[side]
	if not p then
		local n = 0
		p = Vector(0, 0, 0)
		for _, m in ipairs(entry.lamps) do
			if m.side == side then p, n = p + m.pos, n + 1 end
		end
		p = n > 0 and p / n or p
		entry.sidePos[side] = p
	end
	local mat = entry.veh:GetBoneMatrix(entry.bone)

	return mat and mat * p
end

local function lightUp(entry, mode, t)
	local veh = entry.veh
	for side in pairs(SIDE_LIGHT_POS) do
		local col = sideLit(entry, side, mode, t)
		local pos = col and sideLightPos(entry, side)
		if pos then
			local dl = DynamicLight(DLIGHT_BASE + veh:EntIndex() * 2 + (side + 1) / 2)
			if dl then
				dl.pos = pos
				dl.r, dl.g, dl.b = col.r, col.g, col.b
				dl.brightness = DLIGHT.brightness
				dl.decay = DLIGHT.decay
				dl.size = DLIGHT.size
				dl.dietime = CurTime() + DLIGHT.life
			end
		end
	end
end

local byDistance = {}
hook.Add("Think", "audio_engine_police", function()
	local now = CurTime()
	if now >= nextRefresh then
		nextRefresh = now + LIST_REFRESH
		refreshList()
	end
	if #police == 0 then return end
	local eye = EyePos()
	table.Empty(byDistance)
	for _, entry in ipairs(police) do
		if lightsOf(entry) > 0 then
			entry.dist = entry.bar:GetPos():DistToSqr(eye)
			if entry.dist < DLIGHT_DIST * DLIGHT_DIST then table.insert(byDistance, entry) end
		end
	end
	table.sort(byDistance, function(a, b) return a.dist < b.dist end)
	for i = 1, math.min(#byDistance, MAX_DLIGHT_CARS) do
		local entry = byDistance[i]
		lightUp(entry, lightsOf(entry), now + entry.veh:EntIndex() * PHASE_PER_INDEX)
	end
end)

-- the light key, sent as a console command like the start key (cl_engine.lua)
local keyHeld = false
hook.Add("Think", "audio_engine_lightkey", function()
	local key = _G["KEY_" .. string.upper(cvLightKey:GetString())]
	local down = key ~= nil and input.IsKeyDown(key)
	local pressed = down and not keyHeld
	keyHeld = down
	if not pressed then return end
	local ply = LocalPlayer()
	local veh = IsValid(ply) and ply:GetVehicle()
	if not IsValid(veh) or not IsValid(veh:GetNW2Entity("audio_lightbar")) or ply:IsTyping() then return end
	if gui.IsGameUIVisible() or IsValid(vgui.GetKeyboardFocus()) then return end
	RunConsoleCommand("audio_engine_lights")
end)
