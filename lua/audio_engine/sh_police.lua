--[[
	Emergency lights. The marked police cars and the fire and medical job vehicles
	(E.JOB_VEHICLES entries named here) get PERP's lightbar
	(models/perpheads/props/police_lightbar.mdl) on the roof and spawn in their livery; the
	ambulances and the fire truck have lights of their own in the model (E.BUILTIN_LIGHTS), which
	light up instead. The LEDs and lenses are plain textures, so the flashing is drawn by
	cl_police.lua (glows on the lenses plus a dynamic light); sv_police.lua attaches the bar and
	switches the lights.

	scheme: the colours and the siren's tones: "police" (red / white / blue, the default),
	"fire" (red / yellow), "medical" (red / white). Networked as NW2 audio_lightscheme.

	Lightbar model space: long axis X (-29.7..29.7), front +Y, the message board at the rear,
	base at z 0, lenses z 3.3..5.0: the same way round as the TDM cars (nose +Y, -X the
	driver's side), so it mounts unturned.
]]
local E = AUDIO_ENGINE

E.LIGHTBAR_MODEL = "models/perpheads/props/police_lightbar.mdl"
E.LIGHTBAR_ANGLE = Angle(0, 0, 0)

-- spawn name (E.JOB_VEHICLES) -> where the bar sits, in the car's model space: centre line,
-- just behind the windscreen, on the roof (measured from the meshes: highest painted surface, which
-- sits ~10.5 lower than in game on the TDM models: the 340i was fixed in game from 57.5 to 68.5)
-- bodygroups: by name, set on spawn (the Crown Vic shares its model with the taxi: no roof sign, no meter)
-- builtin: the model's own lights (E.BUILTIN_LIGHTS), no bar
E.POLICE_VEHICLES = {
	["BMW 340i Police"] = { mount = Vector(0, -11, 68.5) },
	["BMW M5 E60 Police"] = { mount = Vector(0, -12, 72.5) },
	["Dodge Charger 2012 Police"] = { mount = Vector(0, -16, 73.5) },
	["Dodge Charger SRT-8 Police"] = { mount = Vector(0, -8, 68.5) },
	["Ford Crown Victoria Police"] = { mount = Vector(0, -12, 70.5), bodygroups = { sign = 1, stuff = 1 } },
	["Ford Transit 2016 (Police)"] = { mount = Vector(0, -8, 110) },
	["Land Rover Range Rover 2012 Police"] = { mount = Vector(0, -24, 91.5) },
	["Mercedes SL65 AMG Police"] = { mount = Vector(0, -16, 60.5) },
	["Porsche Cayenne Turbo S Police"] = { mount = Vector(0, -24, 83) },
	-- fire (the F350's own roof lights are amber clearance lights: it gets a bar behind them)
	["Dodge RAM SRT10 Fire Rescue"] = { mount = Vector(0, -12, 98), scheme = "fire" },
	["Ford F350 Fire Rescue"] = { mount = Vector(0, 8, 92.5), scheme = "fire" },
	["Land Rover Defender Fire"] = { mount = Vector(0, -2, 115), scheme = "fire" },
	["Fire Truck"] = { builtin = true, scheme = "fire" },
	-- medical
	["Audi RS4 Avant First Responder"] = { mount = Vector(0, -6, 80), scheme = "medical" },
	["Toyota Prius Medic"] = { mount = Vector(0, -12, 83.5), scheme = "medical" },
	["Ambulance"] = { builtin = true, scheme = "medical" },
	["Ford F450 Ambulance"] = { builtin = true, scheme = "medical" },
}

--[[
	Lights built into the model (lower-case model path), placed from the meshes: each lamp's lens
	(pos, n = outward normal, w x h) in the space of the model's body bone, so in game they follow
	the bone (cl_police.lua, GetBoneMatrix): the GTA IV ports have their body bone turned 90 deg,
	and TDM models move theirs in the idle pose. color: a lamp colour of cl_police.lua (the lens
	texture's own); side -1 = driver's side, 1 = passenger's, 0 = centre; group as the bar's
	modules (o / i: the two halves of the wig-wag, c: centre). Headlights, tail lights and
	indicators are left out. Made with an MDL/VVD reader from the lens material's vertices.
]]
E.BUILTIN_LIGHTS = {
	["models/sickness/meatwagon.mdl"] = { bone = "car.body", lamps = {
		{ pos = Vector(41.52, 78.31, -20.52), n = Vector(0.97, 0.24, -0), w = 6.5, h = 4.5, color = "red", side = -1, group = "o" },
		{ pos = Vector(32.02, 78.31, -20.52), n = Vector(-0.97, 0.24, -0), w = 6.5, h = 4.5, color = "red", side = -1, group = "o" },
		{ pos = Vector(45.02, 78.31, -13.62), n = Vector(0.97, 0.24, -0), w = 6.5, h = 4.5, color = "white", side = -1, group = "o" },
		{ pos = Vector(35.52, 78.31, -13.62), n = Vector(-0.97, 0.24, -0), w = 6.5, h = 4.5, color = "white", side = -1, group = "o" },
		{ pos = Vector(48.42, 78.31, -6.82), n = Vector(0.97, 0.24, -0), w = 6.5, h = 4.5, color = "red", side = -1, group = "i" },
		{ pos = Vector(38.92, 78.31, -6.82), n = Vector(-0.97, 0.24, -0), w = 6.5, h = 4.5, color = "red", side = -1, group = "i" },
		{ pos = Vector(51.82, 78.31, -0.02), n = Vector(0.97, 0.24, -0), w = 6.5, h = 4.5, color = "white", side = 0, group = "c" },
		{ pos = Vector(42.32, 78.31, -0.02), n = Vector(-0.97, 0.24, -0), w = 6.5, h = 4.5, color = "white", side = 0, group = "c" },
		{ pos = Vector(48.42, 78.31, 6.78), n = Vector(0.97, 0.24, -0), w = 6.5, h = 4.5, color = "red", side = 1, group = "i" },
		{ pos = Vector(38.92, 78.31, 6.78), n = Vector(-0.97, 0.24, -0), w = 6.5, h = 4.5, color = "red", side = 1, group = "i" },
		{ pos = Vector(45.02, 78.31, 13.58), n = Vector(0.97, 0.24, -0), w = 6.5, h = 4.5, color = "white", side = 1, group = "o" },
		{ pos = Vector(35.52, 78.31, 13.58), n = Vector(-0.97, 0.24, -0), w = 6.5, h = 4.5, color = "white", side = 1, group = "o" },
		{ pos = Vector(41.52, 78.31, 20.48), n = Vector(0.97, 0.24, -0), w = 6.5, h = 4.5, color = "red", side = 1, group = "o" },
		{ pos = Vector(32.02, 78.31, 20.48), n = Vector(-0.97, 0.24, -0), w = 6.5, h = 4.5, color = "red", side = 1, group = "o" },
		{ pos = Vector(-144.98, 86.21, -5.22), n = Vector(-1, 0.1, -0), w = 8, h = 4, color = "white", side = -1, group = "i" },
		{ pos = Vector(-144.98, 86.21, 5.58), n = Vector(-1, 0.1, -0), w = 8, h = 4, color = "white", side = 1, group = "i" },
		{ pos = Vector(-144.98, 86.21, -15.92), n = Vector(-1, 0.1, -0), w = 8, h = 4, color = "red", side = -1, group = "o" },
		{ pos = Vector(-144.98, 86.21, 16.28), n = Vector(-1, 0.1, -0), w = 8, h = 4, color = "red", side = 1, group = "o" },
		{ pos = Vector(-144.98, 86.21, -26.32), n = Vector(-1, 0.1, -0), w = 8, h = 4, color = "white", side = -1, group = "i" },
		{ pos = Vector(-144.98, 86.21, 26.68), n = Vector(-1, 0.1, -0), w = 8, h = 4, color = "white", side = 1, group = "i" },
		{ pos = Vector(-144.98, 86.21, -34.92), n = Vector(-1, 0.1, -0), w = 8, h = 4, color = "red", side = -1, group = "o" },
		{ pos = Vector(-144.98, 86.21, 35.28), n = Vector(-1, 0.1, -0), w = 8, h = 4, color = "red", side = 1, group = "o" },
		{ pos = Vector(-144.98, 86.21, -44.72), n = Vector(-1, 0.1, -0), w = 6, h = 4, color = "red", side = -1, group = "o" },
		{ pos = Vector(-144.98, 86.21, 45.08), n = Vector(-1, 0.1, -0), w = 6, h = 4, color = "red", side = 1, group = "o" },
		{ pos = Vector(-144.48, 80.21, -37.62), n = Vector(-1, 0, -0), w = 7, h = 5.5, color = "red", side = -1, group = "i" },
		{ pos = Vector(-144.48, 80.21, 37.98), n = Vector(-1, 0, -0), w = 7, h = 5.5, color = "red", side = 1, group = "i" },
		{ pos = Vector(1.82, 77.51, -49.22), n = Vector(0, 0, -1), w = 7, h = 5.5, color = "red", side = -1, group = "o" },
		{ pos = Vector(1.82, 77.51, 49.58), n = Vector(0, 0, 1), w = 7, h = 5.5, color = "red", side = 1, group = "o" },
		{ pos = Vector(-17.38, 77.51, -49.22), n = Vector(0, 0, -1), w = 7, h = 5.5, color = "white", side = -1, group = "i" },
		{ pos = Vector(-17.38, 77.51, 49.58), n = Vector(0, 0, 1), w = 7, h = 5.5, color = "white", side = 1, group = "i" },
		{ pos = Vector(-111.18, 77.51, -49.22), n = Vector(0, 0, -1), w = 7, h = 5.5, color = "white", side = -1, group = "i" },
		{ pos = Vector(-111.18, 77.51, 49.58), n = Vector(0, 0, 1), w = 7, h = 5.5, color = "white", side = 1, group = "i" },
		{ pos = Vector(-130.38, 77.51, -49.22), n = Vector(0, 0, -1), w = 7, h = 5.5, color = "red", side = -1, group = "o" },
		{ pos = Vector(-130.38, 77.51, 49.58), n = Vector(0, 0, 1), w = 7, h = 5.5, color = "red", side = 1, group = "o" },
		{ pos = Vector(117.92, 30.01, -17.32), n = Vector(1, 0, -0), w = 5, h = 3, color = "red", side = -1, group = "o" },
		{ pos = Vector(117.92, 30.01, 17.68), n = Vector(1, 0, -0), w = 5, h = 3, color = "red", side = 1, group = "o" },
		{ pos = Vector(117.92, 30.01, -10.62), n = Vector(1, 0, -0), w = 5, h = 3, color = "red", side = -1, group = "i" },
		{ pos = Vector(117.92, 30.01, 10.98), n = Vector(1, 0, -0), w = 5, h = 3, color = "red", side = 1, group = "i" },
	} },
	["models/sickness/truckfire.mdl"] = { bone = "car.body", lamps = {
		{ pos = Vector(175.3, 99.87, 0.06), n = Vector(0.98, 0.2, -0), w = 7, h = 4, color = "yellow", side = 0, group = "c" },
		{ pos = Vector(164.3, 99.87, 0.06), n = Vector(-0.98, 0.2, -0), w = 7, h = 4, color = "yellow", side = 0, group = "c" },
		{ pos = Vector(175.3, 99.87, -12.54), n = Vector(0.98, 0.2, -0), w = 7, h = 4, color = "yellow", side = -1, group = "i" },
		{ pos = Vector(164.3, 99.87, -12.54), n = Vector(-0.98, 0.2, -0), w = 7, h = 4, color = "yellow", side = -1, group = "i" },
		{ pos = Vector(175.3, 99.87, 13.06), n = Vector(0.98, 0.2, -0), w = 7, h = 4, color = "yellow", side = 1, group = "i" },
		{ pos = Vector(164.3, 99.87, 13.06), n = Vector(-0.98, 0.2, -0), w = 7, h = 4, color = "yellow", side = 1, group = "i" },
		{ pos = Vector(175.3, 99.87, -30.74), n = Vector(0.98, 0.2, -0), w = 7, h = 4, color = "red", side = -1, group = "o" },
		{ pos = Vector(147.8, 99.87, -39.24), n = Vector(-0.98, 0.2, -0), w = 7, h = 4, color = "red", side = -1, group = "o" },
		{ pos = Vector(175.3, 99.87, 31.26), n = Vector(0.98, 0.2, -0), w = 7, h = 4, color = "red", side = 1, group = "o" },
		{ pos = Vector(147.8, 99.87, 39.76), n = Vector(-0.98, 0.2, -0), w = 7, h = 4, color = "red", side = 1, group = "o" },
		{ pos = Vector(154.8, 99.87, -48.24), n = Vector(0, 0.2, -0.98), w = 7, h = 4, color = "red", side = -1, group = "o" },
		{ pos = Vector(154.8, 99.87, 48.76), n = Vector(0, 0.2, 0.98), w = 7, h = 4, color = "red", side = 1, group = "o" },
		{ pos = Vector(82.3, 99.87, -35.34), n = Vector(0.98, 0.2, -0), w = 8, h = 4, color = "red", side = -1, group = "o" },
		{ pos = Vector(54.3, 99.87, -35.34), n = Vector(-0.98, 0.2, -0), w = 8, h = 4, color = "red", side = -1, group = "o" },
		{ pos = Vector(68.3, 99.87, -41.74), n = Vector(0, 0.2, -0.98), w = 8, h = 4, color = "red", side = -1, group = "o" },
		{ pos = Vector(82.3, 99.87, 35.86), n = Vector(0.98, 0.2, -0), w = 8, h = 4, color = "red", side = 1, group = "o" },
		{ pos = Vector(54.3, 99.87, 35.86), n = Vector(-0.98, 0.2, -0), w = 8, h = 4, color = "red", side = 1, group = "o" },
		{ pos = Vector(68.3, 99.87, 42.26), n = Vector(0, 0.2, 0.98), w = 8, h = 4, color = "red", side = 1, group = "o" },
		{ pos = Vector(-167.7, 98.97, -26.14), n = Vector(-0.98, 0.2, -0), w = 8, h = 4.5, color = "yellow", side = -1, group = "i" },
		{ pos = Vector(-167.7, 98.97, 26.66), n = Vector(-0.98, 0.2, -0), w = 8, h = 4.5, color = "yellow", side = 1, group = "i" },
		{ pos = Vector(-167.7, 98.97, -44.54), n = Vector(-0.98, 0.2, -0), w = 8, h = 4.5, color = "yellow", side = -1, group = "o" },
		{ pos = Vector(-167.7, 98.97, 45.06), n = Vector(-0.98, 0.2, -0), w = 8, h = 4.5, color = "yellow", side = 1, group = "o" },
		{ pos = Vector(199.1, 44.27, -18.44), n = Vector(1, 0, -0), w = 4, h = 8, color = "red", side = -1, group = "i" },
		{ pos = Vector(199.1, 44.27, 18.96), n = Vector(1, 0, -0), w = 4, h = 8, color = "red", side = 1, group = "i" },
		{ pos = Vector(199.1, 44.27, -23.24), n = Vector(1, 0, -0), w = 4, h = 8, color = "yellow", side = -1, group = "o" },
		{ pos = Vector(199.1, 44.27, 23.76), n = Vector(1, 0, -0), w = 4, h = 8, color = "yellow", side = 1, group = "o" },
	} },
	["models/forest/f450_ambo.mdl"] = { bone = "Bone001", lamps = {
		{ pos = Vector(-35.5, 23.5, 95.6), n = Vector(0, 0.99, 0.15), w = 8, h = 4.5, color = "red", side = -1, group = "o" },
		{ pos = Vector(-26, 23.5, 95.6), n = Vector(0, 0.99, 0.15), w = 5, h = 4.5, color = "red", side = -1, group = "o" },
		{ pos = Vector(-21.6, 23.5, 95.6), n = Vector(0, 0.99, 0.15), w = 5, h = 4.5, color = "white", side = -1, group = "o" },
		{ pos = Vector(-17.2, 23.5, 95.6), n = Vector(0, 0.99, 0.15), w = 5, h = 4.5, color = "red", side = -1, group = "i" },
		{ pos = Vector(-6, 23.5, 95.6), n = Vector(0, 0.99, 0.15), w = 5, h = 4.5, color = "white", side = -1, group = "i" },
		{ pos = Vector(6, 23.5, 95.6), n = Vector(0, 0.99, 0.15), w = 5, h = 4.5, color = "white", side = 1, group = "i" },
		{ pos = Vector(18.6, 23.5, 95.6), n = Vector(0, 0.99, 0.15), w = 5, h = 4.5, color = "red", side = 1, group = "i" },
		{ pos = Vector(23, 23.5, 95.6), n = Vector(0, 0.99, 0.15), w = 5, h = 4.5, color = "white", side = 1, group = "o" },
		{ pos = Vector(27.3, 23.5, 95.6), n = Vector(0, 0.99, 0.15), w = 5, h = 4.5, color = "red", side = 1, group = "o" },
		{ pos = Vector(36, 23.5, 95.6), n = Vector(0, 0.99, 0.15), w = 8, h = 4.5, color = "red", side = 1, group = "o" },
		{ pos = Vector(-44.2, -148, 106.5), n = Vector(0, -1, 0.1), w = 8, h = 4, color = "red", side = -1, group = "o" },
		{ pos = Vector(-34.4, -148, 106.5), n = Vector(0, -1, 0.1), w = 8, h = 4, color = "white", side = -1, group = "o" },
		{ pos = Vector(-25.8, -148, 106.5), n = Vector(0, -1, 0.1), w = 8, h = 4, color = "red", side = -1, group = "o" },
		{ pos = Vector(-15.5, -148, 106.5), n = Vector(0, -1, 0.1), w = 8, h = 4, color = "white", side = -1, group = "i" },
		{ pos = Vector(-4.7, -148, 106.5), n = Vector(0, -1, 0.1), w = 8, h = 4, color = "red", side = -1, group = "i" },
		{ pos = Vector(6, -148, 106.5), n = Vector(0, -1, 0.1), w = 8, h = 4, color = "white", side = 1, group = "i" },
		{ pos = Vector(16.8, -148, 106.5), n = Vector(0, -1, 0.1), w = 8, h = 4, color = "red", side = 1, group = "i" },
		{ pos = Vector(27.2, -148, 106.5), n = Vector(0, -1, 0.1), w = 8, h = 4, color = "white", side = 1, group = "o" },
		{ pos = Vector(35.7, -148, 106.5), n = Vector(0, -1, 0.1), w = 8, h = 4, color = "red", side = 1, group = "o" },
		{ pos = Vector(45.6, -148, 106.5), n = Vector(0, -1, 0.1), w = 8, h = 4, color = "red", side = 1, group = "o" },
		{ pos = Vector(-48.6, -133.5, 98), n = Vector(-1, 0, 0), w = 7, h = 6, color = "red", side = -1, group = "o" },
		{ pos = Vector(-48.6, -114.3, 98), n = Vector(-1, 0, 0), w = 7, h = 6, color = "white", side = -1, group = "i" },
		{ pos = Vector(-48.6, -20.5, 98), n = Vector(-1, 0, 0), w = 7, h = 6, color = "white", side = -1, group = "i" },
		{ pos = Vector(-48.6, -1.3, 98), n = Vector(-1, 0, 0), w = 7, h = 6, color = "red", side = -1, group = "o" },
		{ pos = Vector(49.9, -133.5, 98), n = Vector(1, 0, 0), w = 7, h = 6, color = "red", side = 1, group = "o" },
		{ pos = Vector(49.9, -114.3, 98), n = Vector(1, 0, 0), w = 7, h = 6, color = "white", side = 1, group = "i" },
		{ pos = Vector(49.9, -1.3, 98), n = Vector(1, 0, 0), w = 7, h = 6, color = "red", side = 1, group = "o" },
	} },
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
	LED modules of the bar: pos = lens centre, n = outward normal, w = width.
	group: o outer, i inner, c centre, k corner; side -1 = driver's side (red), 1 = passenger's
	side (blue), 0 = centre (white)
	Written as read from the mesh, which is in the root bone's frame (turned -90 deg about Z:
	x = rear, y = passenger's side); module() turns them into model space (x, y) -> (y, -x)
]]
local Z = 4.15
local function module(x, y, nx, ny, w, group, side)
	return { pos = Vector(y, -x, Z), n = Vector(ny, -nx, 0), w = w, group = group, side = side }
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
