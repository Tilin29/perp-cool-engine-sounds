--[[
	Police lightbars. The marked police cars (E.JOB_VEHICLES entries named here) get PERP's
	lightbar (models/perpheads/props/police_lightbar.mdl) on the roof and spawn in their police
	livery. The model's LEDs are plain textures, so the flashing is drawn by cl_police.lua
	(glows on the lenses plus a dynamic light); sv_police.lua attaches the bar and switches it.

	Lightbar model space: long axis Y (-29.7..29.7), the message board side +X (the rear),
	base at z 0, lenses z 3.3..5.0. Mounted turned so its -X faces the car's nose (+Y on the
	TDM models); its -Y end is then on the driver's side.
]]
local E = AUDIO_ENGINE

E.LIGHTBAR_MODEL = "models/perpheads/props/police_lightbar.mdl"
E.LIGHTBAR_ANGLE = Angle(0, -90, 0)

-- police spawn name (E.JOB_VEHICLES) -> where the bar sits, in the car's model space: centre line,
-- just behind the windscreen, on the roof (measured from the meshes: highest painted surface)
-- bodygroups: by name, set on spawn (the Crown Vic shares its model with the taxi: no roof sign, no meter)
E.POLICE_VEHICLES = {
	["BMW 340i Police"] = { mount = Vector(0, -16, 57.5) },
	["BMW M5 E60 Police"] = { mount = Vector(0, -12, 72.5) },
	["Dodge Charger 2012 Police"] = { mount = Vector(0, -16, 73.5) },
	["Dodge Charger SRT-8 Police"] = { mount = Vector(0, -8, 68.5) },
	["Ford Crown Victoria Police"] = { mount = Vector(0, -12, 70.5), bodygroups = { sign = 1, stuff = 1 } },
	["Ford Transit 2016 (Police)"] = { mount = Vector(0, -8, 110) },
	["Land Rover Range Rover 2012 Police"] = { mount = Vector(0, -24, 91.5) },
	["Mercedes SL65 AMG Police"] = { mount = Vector(0, -16, 60.5) },
	["Porsche Cayenne Turbo S Police"] = { mount = Vector(0, -24, 83) },
}

-- the livery: the job vehicle's skin (11 on the TDM models; the Crown Vic's police one is 12, 11 is
-- its taxi; the Transit has only one)
E.POLICE_BY_SCRIPT = {}
for _, job in ipairs(E.JOB_VEHICLES) do
	local police = E.POLICE_VEHICLES[job[1]]
	if police then
		police.script = job[3]
		police.skin = job[4]
		E.POLICE_BY_SCRIPT[job[3]] = police
	end
end

E.LIGHT_MODES = { "CODE 2", "CODE 3" }

--[[
	LED modules of the bar, in its model space: pos = lens centre, n = outward normal, w = width.
	group: o outer, i inner, c centre, k corner; side -1 = driver's side (red), 1 = passenger's
	side (blue), 0 = centre (white)
]]
local Z = 4.15
local function module(x, y, nx, ny, w, group, side)
	return { pos = Vector(x, y, Z), n = Vector(nx, ny, 0), w = w, group = group, side = side }
end

E.LIGHTBAR_MODULES = {}
for _, face in ipairs({ -1, 1 }) do
	local x = 7.6 * face
	table.insert(E.LIGHTBAR_MODULES, module(x, 0, face, 0, 10, "c", 0))
	for _, side in ipairs({ -1, 1 }) do
		table.insert(E.LIGHTBAR_MODULES, module(x, 10 * side, face, 0, 9.5, "i", side))
		table.insert(E.LIGHTBAR_MODULES, module(x, 19.35 * side, face, 0, 9, "o", side))
	end
end
for _, side in ipairs({ -1, 1 }) do
	table.insert(E.LIGHTBAR_MODULES, module(-6.2, 26.6 * side, -0.88, 0.48 * side, 4.8, "k", side))
	table.insert(E.LIGHTBAR_MODULES, module(-1, 29.6 * side, 0.05, side, 5, "k", side))
	table.insert(E.LIGHTBAR_MODULES, module(5.2, 26.7 * side, 0.71, 0.7 * side, 4.9, "k", side))
end
