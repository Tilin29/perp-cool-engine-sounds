--[[
	Police lightbars (sh_police.lua, sv_police.lua): the flashing. The bar's LEDs are plain
	textures, so a lit module gets a glowing lens quad and a glow sprite that fades as it turns
	away from the viewer; the nearest cars also light their surroundings (one dynamic light per
	side). The light key (audio_engine_lightkey, default left shift) steps the driver's lights
	off -> CODE 2 -> CODE 3 -> off.

	Patterns (each car offset in time, so a row of cars doesn't flash in step):
	  CODE 2: slow wig-wag, the driver's outer modules and corners with the passenger's inner ones,
	          then the other way round
	  CODE 3: the same split as quad flashes, twice as fast, plus white double flashes in the middle
]]
local E = AUDIO_ENGINE

local cvLightKey = CreateClientConVar("audio_engine_lightkey", "lshift", true, false,
	"Key that switches the police lights of the car you drive (a key name such as lshift, l or f2; none = off)")

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
local SIDE_COLOR = {
	[-1] = Color(255, 25, 15),
	[0] = Color(255, 255, 255),
	[1] = Color(25, 70, 255),
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

-- police cars near enough to matter, refreshed now and then rather than searched every frame
local police = {}
local nextRefresh = 0

local function refreshList()
	police = {}
	for _, veh in ipairs(ents.FindByClass("prop_vehicle_jeep")) do
		local bar = veh:GetNW2Entity("audio_lightbar")
		if IsValid(bar) then table.insert(police, { veh = veh, bar = bar }) end
	end
end

local function lightsOf(entry)
	local veh, bar = entry.veh, entry.bar
	if not IsValid(veh) or not IsValid(bar) or bar:IsDormant() then return 0 end

	return veh:GetNW2Int("audio_lights", 0)
end

local function drawModule(m, bar, ang, eye)
	local wp = bar:LocalToWorld(m.pos)
	local wn = ang:Forward() * m.n.x - ang:Right() * m.n.y + ang:Up() * m.n.z
	local col = SIDE_COLOR[m.side]
	render.SetMaterial(LENS)
	render.DrawQuadEasy(wp, wn, m.w, LENS_HEIGHT, col, 0)
	local toEye = eye - wp
	local dist = toEye:Length()
	local facing = wn:Dot(toEye) / math.max(dist, 1)
	if facing <= 0 then return end
	local size = math.min(GLOW_SIZE + dist * GLOW_PER_UNIT, GLOW_MAX) * (0.35 + 0.65 * facing)
	glowColor.r, glowColor.g, glowColor.b, glowColor.a = col.r, col.g, col.b, 255 * facing
	render.SetMaterial(GLOW)
	render.DrawSprite(wp + wn * GLOW_OUT, size, size, glowColor)
end

hook.Add("PostDrawTranslucentRenderables", "audio_engine_police", function(depth, skybox)
	if depth or skybox then return end
	local eye = EyePos()
	local t0 = CurTime()
	for _, entry in ipairs(police) do
		local mode = lightsOf(entry)
		local bar = entry.bar
		if mode > 0 and bar:GetPos():DistToSqr(eye) < DRAW_DIST * DRAW_DIST then
			local t = t0 + entry.veh:EntIndex() * PHASE_PER_INDEX
			local ang = bar:GetAngles()
			for _, m in ipairs(E.LIGHTBAR_MODULES) do
				if isLit(m, mode, t) then drawModule(m, bar, ang, eye) end
			end
		end
	end
end)

local function sideLit(side, mode, t)
	for _, m in ipairs(E.LIGHTBAR_MODULES) do
		if m.side == side and m.group == "o" and isLit(m, mode, t) then return true end
	end

	return false
end

local function lightUp(entry, mode, t)
	local veh, bar = entry.veh, entry.bar
	for side, pos in pairs(SIDE_LIGHT_POS) do
		if sideLit(side, mode, t) then
			local col = SIDE_COLOR[side]
			local dl = DynamicLight(DLIGHT_BASE + veh:EntIndex() * 2 + (side + 1) / 2)
			if dl then
				dl.pos = bar:LocalToWorld(pos)
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
